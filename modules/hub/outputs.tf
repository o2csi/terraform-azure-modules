output "resource_group_name" {
  description = "Name of the created resource group."
  value       = azurerm_resource_group.this.name
}

output "resource_group_id" {
  description = "ID of the created resource group."
  value       = azurerm_resource_group.this.id
}

output "vnet_id" {
  description = "ID of the hub virtual network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the hub virtual network."
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Subnet IDs keyed by subnet name."
  value       = { for key, subnet in azurerm_subnet.this : key => subnet.id }

  depends_on = [
    azurerm_subnet_network_security_group_association.this,
    azurerm_network_security_rule.this,
  ]
}

output "nsg_ids" {
  description = "NSG IDs keyed by subnet name."
  value       = { for key, nsg in azurerm_network_security_group.this : key => nsg.id }
}
