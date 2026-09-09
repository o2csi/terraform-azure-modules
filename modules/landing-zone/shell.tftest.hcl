mock_provider "azurerm" {
  mock_data "azurerm_virtual_network" {
    defaults = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub"
      address_space = ["10.16.0.0/24"]
    }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform/providers/Microsoft.Network/virtualNetworks/vnet-liceno-staging"
    }
  }
}

variables {
  resource_group_name     = "rg-platform"
  location                = "westeurope"
  vnet_name               = "vnet-liceno-staging"
  address_prefix          = "10.16.9.0/24"
  dns_servers             = ["10.16.0.4", "10.16.0.5"]
  hub_resource_group_name = "rg-hub"
  hub_vnet_name           = "vnet-hub"
}

run "shell_and_both_peering_directions" {
  command = apply
  assert {
    condition = (
      azurerm_virtual_network.spoke.address_space == toset(["10.16.9.0/24"]) &&
      toset(azurerm_virtual_network.spoke.dns_servers) == toset(["10.16.0.4", "10.16.0.5"])
    )
    error_message = "The shell must use the environment CIDR and both hub resolvers."
  }
  assert {
    condition = (
      azurerm_virtual_network_peering.hub_to_spoke.remote_virtual_network_id == azurerm_virtual_network.spoke.id &&
      azurerm_virtual_network_peering.spoke_to_hub.remote_virtual_network_id == data.azurerm_virtual_network.hub.id &&
      azurerm_virtual_network_peering.hub_to_spoke.resource_group_name == "rg-hub" &&
      azurerm_virtual_network_peering.spoke_to_hub.resource_group_name == "rg-platform" &&
      azurerm_virtual_network_peering.hub_to_spoke.allow_forwarded_traffic &&
      azurerm_virtual_network_peering.spoke_to_hub.allow_forwarded_traffic &&
      !azurerm_virtual_network_peering.hub_to_spoke.use_remote_gateways &&
      !azurerm_virtual_network_peering.spoke_to_hub.use_remote_gateways
    )
    error_message = "Both peerings must point at the opposite VNet and support hub router traffic without VPN gateway transit."
  }
}

run "one_resolver_is_refused" {
  command = plan
  variables {
    dns_servers = ["10.16.0.4", "10.16.0.4"]
  }
  expect_failures = [var.dns_servers]
}

run "maximum_length_vnet_names_produce_valid_peering_names" {
  command = apply
  variables {
    vnet_name     = join("", [for i in range(64) : "s"])
    hub_vnet_name = join("", [for i in range(64) : "h"])
  }
  assert {
    condition = alltrue([
      for name in [azurerm_virtual_network_peering.hub_to_spoke.name, azurerm_virtual_network_peering.spoke_to_hub.name] :
      length(name) <= 80 && can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9_]$", name))
    ])
    error_message = "Valid maximum-length VNet names must never produce an invalid Azure peering name."
  }
}

run "invalid_environment_prefix_is_refused" {
  command = plan
  variables {
    address_prefix = "not-a-cidr"
  }
  expect_failures = [var.address_prefix]
}
