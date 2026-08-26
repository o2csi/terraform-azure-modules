output "vnet_id" {
  description = "Hub VNet ID."
  value       = module.hub.vnet_id
}
output "vault_private_endpoint_id" {
  description = "Key Vault private endpoint ID."
  value       = module.vault_private_endpoint.id
}
output "router_private_ips" {
  description = "Router private IPs keyed by router."
  value       = { for name, router in module.ts_router : name => router.private_ip }
}
