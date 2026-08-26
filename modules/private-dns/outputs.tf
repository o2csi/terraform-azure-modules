output "zone_ids" {
  description = "Private DNS zone IDs keyed by real zone name."
  value       = { for name, zone in azurerm_private_dns_zone.this : name => zone.id }
}

output "zone_names" {
  description = "Private DNS zone names keyed by real zone name."
  value       = { for name, zone in azurerm_private_dns_zone.this : name => zone.name }
}
