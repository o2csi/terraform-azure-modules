mock_provider "azurerm" {
  mock_resource "azurerm_lb" {
    defaults = { id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/loadBalancers/lb-egress" }
  }
  mock_resource "azurerm_lb_backend_address_pool" {
    defaults = { id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/loadBalancers/lb-egress/backendAddressPools/routers" }
  }
  mock_resource "azurerm_lb_probe" {
    defaults = { id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/loadBalancers/lb-egress/probes/egress-health" }
  }
}

variables {
  name                = "lb-egress"
  resource_group_name = "rg-hub"
  location            = "westeurope"
  subnet_id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/hub/subnets/app"
  frontend_ip         = "10.16.0.6"
}

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(azurerm_lb.egress) == 0 && length(azurerm_virtual_machine_extension.egress) == 0 && output.endpoint == null
    error_message = "The optional module must create nothing by default."
  }
}

run "explicit_sources_required" {
  command = plan
  variables { enabled = true }
  expect_failures = [azurerm_lb.egress]
}

run "subscription_wide_source_refused" {
  command = plan
  variables { allowed_source_cidrs = ["10.16.0.0/12"] }
  expect_failures = [var.allowed_source_cidrs]
}

run "one_router_rollout" {
  command = apply
  variables {
    subnet_network_security_group_name = "hub-app-nsg"
    enabled                            = true
    allowed_source_cidrs               = ["10.16.9.0/26"]
    routers = {
      "001" = {
        vm_id                       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Compute/virtualMachines/router-001"
        nic_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/networkInterfaces/router-001"
        nic_ip_configuration        = "primary"
        network_security_group_name = "router-001-nsg"
        private_ip                  = "10.16.0.4"
        active                      = true
      }
      "002" = {
        vm_id                       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Compute/virtualMachines/router-002"
        nic_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/networkInterfaces/router-002"
        nic_ip_configuration        = "primary"
        network_security_group_name = "router-002-nsg"
        private_ip                  = "10.16.0.5"
        active                      = false
      }
    }
  }
  assert {
    condition     = length(azurerm_virtual_machine_extension.egress) == 2 && length(azurerm_network_interface_backend_address_pool_association.router) == 1
    error_message = "Only the selected router may receive traffic; retain the other extension for explicit rollback."
  }
  assert {
    condition     = azurerm_lb_rule.egress[0].floating_ip_enabled && azurerm_lb_rule.egress[0].protocol == "All" && azurerm_lb_rule.egress[0].frontend_port == 0 && azurerm_lb_probe.egress[0].protocol == "Http" && output.endpoint.private_ip == "10.16.0.6"
    error_message = "The egress contract requires an internal HA-ports endpoint with readiness probes."
  }
  assert {
    condition     = length(azurerm_network_security_rule.transit) == 1 && azurerm_network_security_rule.transit["001"].destination_address_prefix == "Internet" && azurerm_network_security_rule.subnet_transit[0].destination_address_prefix == "Internet" && azurerm_network_security_rule.transit["001"].source_address_prefixes == toset(["10.16.9.0/26"]) && azurerm_network_security_rule.subnet_transit[0].source_address_prefixes == toset(["10.16.9.0/26"])
    error_message = "Both NSG layers must admit only the granted source towards Internet; the inactive router receives no new permission."
  }
  assert {
    condition     = local.configuration["002"].enabled == false && local.configuration["001"].sources == tolist(["10.16.9.0/26"])
    error_message = "Do not activate an unselected router or broaden the source grant."
  }
}

run "disabled_removes_transit_grants" {
  command = plan
  variables { subnet_network_security_group_name = "hub-app-nsg" }
  assert {
    condition     = length(azurerm_network_security_rule.transit) == 0 && length(azurerm_network_security_rule.subnet_transit) == 0
    error_message = "Disabled egress must not retain new transit permissions."
  }
}

run "shared_subnet_nic_nsg_refused" {
  command = plan
  variables {
    subnet_network_security_group_name = "ROUTER-001-NSG"
    routers = {
      "001" = {
        vm_id                       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Compute/virtualMachines/router-001"
        nic_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/networkInterfaces/router-001"
        nic_ip_configuration        = "primary"
        network_security_group_name = "router-001-nsg"
        private_ip                  = "10.16.0.4"
        active                      = true
      }
      "002" = {
        vm_id                       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Compute/virtualMachines/router-002"
        nic_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/networkInterfaces/router-002"
        nic_ip_configuration        = "primary"
        network_security_group_name = "router-002-nsg"
        private_ip                  = "10.16.0.5"
        active                      = false
      }
    }
  }
  expect_failures = [var.subnet_network_security_group_name]
}

run "shared_router_nsg_refused" {
  command = plan
  variables {
    routers = {
      "001" = {
        vm_id                       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Compute/virtualMachines/router-001"
        nic_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/networkInterfaces/router-001"
        nic_ip_configuration        = "primary"
        network_security_group_name = "router-001-nsg"
        private_ip                  = "10.16.0.4"
        active                      = true
      }
      "002" = {
        vm_id                       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Compute/virtualMachines/router-002"
        nic_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/networkInterfaces/router-002"
        nic_ip_configuration        = "primary"
        network_security_group_name = "ROUTER-001-NSG"
        private_ip                  = "10.16.0.5"
        active                      = false
      }
    }
  }
  expect_failures = [var.routers]
}
