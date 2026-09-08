locals {
  # The provider models source prefixes as a set, so a repeated entry names no
  # additional source. Each rule's list is made distinct here, which lets the
  # cardinality routing in azurerm_network_security_rule count distinct sources
  # and keeps a duplicate out of the plural argument. modules/ts-router
  # normalises its own list the same way.
  nsg_rules = merge([
    for subnet_key, subnet in var.subnets : {
      for rule in concat(subnet.nsg_rules, [{
        name                    = "DenyInternetInbound"
        priority                = 4000
        direction               = "Inbound"
        access                  = "Deny"
        protocol                = "*"
        source_address_prefixes = ["Internet"]
        destination_port_ranges = ["*"]
        }]) : "${subnet_key}/${rule.name}" => merge(rule, {
        subnet_key              = subnet_key
        source_address_prefixes = distinct(rule.source_address_prefixes)
      })
    }
  ]...)
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.address_space
  dns_servers         = var.dns_servers
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                              = each.key
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [each.value.address_prefix]
  service_endpoints                 = each.value.service_endpoints
  private_endpoint_network_policies = each.value.private_endpoint_network_policies
}

resource "azurerm_network_security_group" "this" {
  for_each = var.subnets

  name                = "${var.vnet_name}-${each.key}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "this" {
  for_each = local.nsg_rules

  name                        = each.value.name
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.this[each.value.subnet_key].name
  source_port_range           = "*"
  destination_address_prefix  = "*"

  # Azure keeps its wildcards and service tags in the singular member of each
  # argument pair and answers 400 when one reaches the plural member:
  # SecurityRuleParameterContainsInvalidPortRanges for a "*" in
  # destinationPortRanges, SecurityRuleParameterContainsUnsupportedValue for
  # Internet, VirtualNetwork, AzureLoadBalancer, "*" or any other system tag in
  # sourceAddressPrefixes. Each pair is mutually exclusive, so one member is
  # always null.
  #
  # sourceAddressPrefix accepts a CIDR, an address, a wildcard or a service tag,
  # while sourceAddressPrefixes accepts address prefixes only, so a rule naming
  # one distinct source takes the singular argument. Routing on cardinality
  # rather than on spelling is what keeps a dotted tag such as
  # AzureFrontDoor.Backend or Storage.WestEurope working; the list was made
  # distinct above so a repeated tag counts once. modules/ts-router writes both
  # forms this way already, including `source_address_prefix = "Internet"`.
  source_address_prefix   = length(each.value.source_address_prefixes) == 1 ? one(each.value.source_address_prefixes) : null
  source_address_prefixes = length(each.value.source_address_prefixes) == 1 ? null : each.value.source_address_prefixes
  destination_port_range  = contains(each.value.destination_port_ranges, "*") ? "*" : null
  destination_port_ranges = contains(each.value.destination_port_ranges, "*") ? null : each.value.destination_port_ranges
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = var.subnets

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id

  depends_on = [azurerm_network_security_rule.this]
}
