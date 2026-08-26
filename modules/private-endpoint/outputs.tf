output "id" {
  description = "Private endpoint ID."
  value       = azurerm_private_endpoint.this.id
}
output "private_ips" {
  description = "Private IP addresses allocated to the endpoint."
  value = sort(distinct(length(azurerm_private_endpoint.this.ip_configuration) > 0 ?
    [for configuration in azurerm_private_endpoint.this.ip_configuration : configuration.private_ip_address] :
    [for connection in azurerm_private_endpoint.this.private_service_connection : connection.private_ip_address]
  ))
}
output "custom_dns_configs" {
  description = "Private endpoint custom DNS configuration returned by Azure."
  value       = azurerm_private_endpoint.this.custom_dns_configs
}
