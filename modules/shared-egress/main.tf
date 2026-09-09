locals {
  active_routers = { for key, router in var.routers : key => router if var.enabled && router.active }
  configuration = {
    for key, router in var.routers : key => {
      enabled     = var.enabled && router.active
      private_ip  = router.private_ip
      sources     = var.allowed_source_cidrs
      health_port = 8081
    }
  }
  # The script and configuration contain no credentials. The existing VM's
  # custom_data remains byte-identical, avoiding a destructive VM replacement.
  installer = {
    for key, router in var.routers : key => join("\n", [
      "#!/bin/sh",
      "set -eu",
      "python3 - '${base64encode(jsonencode(local.configuration[key]))}' <<'PY'",
      "import base64,sys",
      "source = base64.b64decode('${filebase64("${path.module}/files/egress.py")}')",
      "exec(compile(source, '<egress-installer>', 'exec'), {'__name__': '__main__', 'INSTALLER_SOURCE': source})",
      "PY",
    ])
  }
}

resource "azurerm_lb" "egress" {
  count               = var.enabled ? 1 : 0
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = var.tags
  frontend_ip_configuration {
    name                          = "egress"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.frontend_ip
    zones                         = ["1", "2", "3"]
  }
  lifecycle {
    precondition {
      condition     = length(var.allowed_source_cidrs) > 0 && length(local.active_routers) > 0
      error_message = "Enabling egress requires an explicit source subnet and at least one active router."
    }
  }
}

resource "azurerm_lb_backend_address_pool" "routers" {
  count           = var.enabled ? 1 : 0
  name            = "routers"
  loadbalancer_id = azurerm_lb.egress[0].id
}

resource "azurerm_network_interface_backend_address_pool_association" "router" {
  for_each                = local.active_routers
  network_interface_id    = each.value.nic_id
  ip_configuration_name   = each.value.nic_ip_configuration
  backend_address_pool_id = azurerm_lb_backend_address_pool.routers[0].id
  depends_on              = [azurerm_virtual_machine_extension.egress]
}

resource "azurerm_lb_probe" "egress" {
  count               = var.enabled ? 1 : 0
  name                = "egress-health"
  loadbalancer_id     = azurerm_lb.egress[0].id
  protocol            = "Http"
  port                = 8081
  request_path        = "/healthz"
  interval_in_seconds = 5
  number_of_probes    = 3
}

resource "azurerm_lb_rule" "egress" {
  count                          = var.enabled ? 1 : 0
  name                           = "egress-ha-ports"
  loadbalancer_id                = azurerm_lb.egress[0].id
  frontend_ip_configuration_name = "egress"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.routers[0].id]
  probe_id                       = azurerm_lb_probe.egress[0].id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  floating_ip_enabled            = false
  disable_outbound_snat          = true
}

resource "azurerm_network_security_rule" "probe" {
  for_each                    = local.active_routers
  name                        = "AllowEgressProbe"
  resource_group_name         = var.resource_group_name
  network_security_group_name = each.value.network_security_group_name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8081"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = each.value.private_ip
}

resource "azurerm_virtual_machine_extension" "egress" {
  for_each                   = var.routers
  name                       = "shared-egress"
  virtual_machine_id         = each.value.vm_id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true
  settings                   = jsonencode({ script = base64encode(local.installer[each.key]) })
  tags                       = var.tags
}
