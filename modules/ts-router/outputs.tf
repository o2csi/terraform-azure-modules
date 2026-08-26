output "vm_id" {
  description = "Router VM ID."
  value       = azurerm_linux_virtual_machine.this.id
}
output "private_ip" {
  description = "Router NIC private IP."
  value       = azurerm_network_interface.this.ip_configuration[0].private_ip_address
}
output "public_ip" {
  description = "Router public IP, or null when disabled."
  value       = try(azurerm_public_ip.this[0].ip_address, null)
}
output "nic_id" {
  description = "Router NIC ID."
  value       = azurerm_network_interface.this.id
}
