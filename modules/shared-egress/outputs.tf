output "endpoint" {
  description = "Explicit consumer contract; clients never read the platform state."
  value = var.enabled ? {
    id         = azurerm_lb.egress[0].id
    private_ip = var.frontend_ip
  } : null
}
