locals {
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
      }]) : "${subnet_key}/${rule.name}" => merge(rule, { subnet_key = subnet_key })
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
  source_address_prefixes     = each.value.source_address_prefixes
  destination_port_ranges     = each.value.destination_port_ranges
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = var.subnets

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id

  depends_on = [azurerm_network_security_rule.this]
}
