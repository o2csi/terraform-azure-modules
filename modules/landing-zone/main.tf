data "azurerm_virtual_network" "hub" {
  name                = var.hub_vnet_name
  resource_group_name = var.hub_resource_group_name
}

resource "azurerm_resource_group" "platform" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "spoke" {
  name                = var.vnet_name
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  address_space       = [var.address_prefix]
  dns_servers         = var.dns_servers
  tags                = var.tags

  # D12: project infrastructure owns standalone subnets in this VNet. The
  # platform must not reconcile their collection when updating the VNet shell.
  lifecycle {
    ignore_changes = [subnet]
  }
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "to-${substr(var.vnet_name, 0, 40)}-${substr(sha256(lower(azurerm_virtual_network.spoke.id)), 0, 16)}"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = data.azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "to-${substr(var.hub_vnet_name, 0, 40)}-${substr(sha256(lower(data.azurerm_virtual_network.hub.id)), 0, 16)}"
  resource_group_name          = azurerm_resource_group.platform.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = data.azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
