output "resource_group_name" {
  value = azurerm_resource_group.platform.name
}

output "vnet_id" {
  value = azurerm_virtual_network.spoke.id
}

output "vnet_name" {
  value = azurerm_virtual_network.spoke.name
}

output "address_prefix" {
  value = var.address_prefix
}

output "dns_servers" {
  value = azurerm_virtual_network.spoke.dns_servers
}

output "peering_ids" {
  value = {
    hub_to_spoke = azurerm_virtual_network_peering.hub_to_spoke.id
    spoke_to_hub = azurerm_virtual_network_peering.spoke_to_hub.id
  }
}
