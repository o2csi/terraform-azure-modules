# Azure keeps its wildcards and service tags in the singular member of each
# argument pair on a security rule and answers 400 when one reaches the plural
# member. Every rule this module renders therefore has to put each value in the
# right member, and nothing but a plan could observe that until these cases
# existed: three such defects reached a consumer's apply first.
#
# `command = plan` under a mocked provider, so these contact no Azure account.

# The association resource parses the subnet and NSG IDs it is handed, and the
# mock's generated values are not ARM IDs. These defaults are well-formed so the
# plan reaches the rules, which are what these cases are about.
mock_provider "azurerm" {
  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-a"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-test"
    }
  }
}

variables {
  resource_group_name = "rg-test"
  location            = "westeurope"
  vnet_name           = "vnet-test"
  address_space       = ["10.0.0.0/16"]
}

run "the_injected_deny_rule_puts_its_tag_and_wildcard_in_the_singular_members" {
  command = plan

  variables {
    subnets = {
      "snet-a" = { address_prefix = "10.0.0.0/24" }
    }
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/DenyInternetInbound"].source_address_prefix == "Internet"
    error_message = "the injected deny rule must name Internet through source_address_prefix; Azure answers 400 SecurityRuleParameterContainsUnsupportedValue for a tag in source_address_prefixes"
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/DenyInternetInbound"].source_address_prefixes == null
    error_message = "the plural source member must be null when the singular one carries the tag; the provider accepts exactly one"
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/DenyInternetInbound"].destination_port_range == "*"
    error_message = "the injected deny rule must name every port through destination_port_range; Azure answers 400 SecurityRuleParameterContainsInvalidPortRanges for a wildcard in destination_port_ranges"
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/DenyInternetInbound"].destination_port_ranges == null
    error_message = "the plural port member must be null when the singular one carries the wildcard"
  }
}

run "a_repeated_tag_names_one_source_and_still_takes_the_singular_member" {
  command = plan

  variables {
    subnets = {
      "snet-a" = {
        address_prefix = "10.0.0.0/24"
        nsg_rules = [{
          name                    = "DenyFrontDoor"
          priority                = 200
          direction               = "Inbound"
          access                  = "Deny"
          protocol                = "*"
          source_address_prefixes = ["AzureFrontDoor.Backend", "AzureFrontDoor.Backend"]
          destination_port_ranges = ["443"]
        }]
      }
    }
  }

  # A dotted tag defeats every punctuation heuristic, and a repeated entry names
  # no additional source. Both were defects before the list was made distinct and
  # the routing moved to cardinality.
  assert {
    condition     = azurerm_network_security_rule.this["snet-a/DenyFrontDoor"].source_address_prefix == "AzureFrontDoor.Backend"
    error_message = "a dotted service tag, repeated, still names one source and must take source_address_prefix"
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/DenyFrontDoor"].source_address_prefixes == null
    error_message = "the plural source member must be null for a single distinct source"
  }
}

run "several_addresses_and_named_ports_keep_the_plural_members" {
  command = plan

  variables {
    subnets = {
      "snet-a" = {
        address_prefix = "10.0.0.0/24"
        nsg_rules = [{
          name                    = "AllowDns"
          priority                = 100
          direction               = "Inbound"
          access                  = "Allow"
          protocol                = "Udp"
          source_address_prefixes = ["10.0.0.0/16", "100.64.0.0/10"]
          destination_port_ranges = ["53", "5353"]
        }]
      }
    }
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/AllowDns"].source_address_prefixes == toset(["10.0.0.0/16", "100.64.0.0/10"])
    error_message = "several distinct addresses belong in source_address_prefixes"
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/AllowDns"].source_address_prefix == null
    error_message = "the singular source member must be null when the plural one carries the list"
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/AllowDns"].destination_port_ranges == toset(["53", "5353"])
    error_message = "named ports belong in destination_port_ranges"
  }

  assert {
    condition     = azurerm_network_security_rule.this["snet-a/AllowDns"].destination_port_range == null
    error_message = "the singular port member must be null when the plural one carries the list"
  }
}

run "a_single_address_takes_the_singular_member_like_any_other_single_source" {
  command = plan

  variables {
    subnets = {
      "snet-a" = {
        address_prefix = "10.0.0.0/24"
        nsg_rules = [{
          name                    = "AllowOneSubnet"
          priority                = 120
          direction               = "Inbound"
          access                  = "Allow"
          protocol                = "Tcp"
          source_address_prefixes = ["10.1.0.0/16"]
          destination_port_ranges = ["443"]
        }]
      }
    }
  }

  # Routing is on cardinality, so a lone CIDR takes the same member a lone tag
  # does. The singular argument accepts both.
  assert {
    condition     = azurerm_network_security_rule.this["snet-a/AllowOneSubnet"].source_address_prefix == "10.1.0.0/16"
    error_message = "one distinct source takes source_address_prefix whatever it spells"
  }
}

run "a_wildcard_mixed_with_named_ports_is_refused_before_any_call" {
  command = plan

  variables {
    subnets = {
      "snet-a" = {
        address_prefix = "10.0.0.0/24"
        nsg_rules = [{
          name                    = "Ambiguous"
          priority                = 130
          direction               = "Inbound"
          access                  = "Allow"
          protocol                = "Tcp"
          source_address_prefixes = ["10.1.0.0/16"]
          destination_port_ranges = ["443", "*"]
        }]
      }
    }
  }

  # "*" already matches every port, so the named entries would have no effect
  # while the configuration reads as if they did.
  expect_failures = [var.subnets]
}
