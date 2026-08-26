module "hub" {
  source = "../../modules/hub"

  resource_group_name = var.resource_group_name
  location            = var.location
  vnet_name           = "vnet-example-hub-minimal"
  address_space       = ["10.0.0.0/16"]
  # Azure platform address (WireServer), not an example-specific choice.
  dns_servers = ["168.63.129.16"]
  tags        = var.tags

  subnets = {
    "snet-app" = {
      address_prefix = "10.0.0.0/24"
      nsg_rules = [{
        name                    = "AllowDnsFromConsumers"
        priority                = 100
        direction               = "Inbound"
        access                  = "Allow"
        protocol                = "*"
        source_address_prefixes = ["10.0.0.0/16", "100.64.0.0/10"]
        destination_port_ranges = ["53"]
      }]
    }
    "snet-pe" = {
      address_prefix                    = "10.0.1.0/24"
      private_endpoint_network_policies = "Disabled"
    }
  }
}

module "private_dns" {
  source = "../../modules/private-dns"

  resource_group_name = module.hub.resource_group_name
  tags                = var.tags
  zones = {
    "privatelink.vaultcore.azure.net" = {
      vnet_links = {
        hub = { vnet_id = module.hub.vnet_id, vnet_key = "hub" }
      }
    }
    "azure.example.invalid" = {
      vnet_links = {
        hub = { vnet_id = module.hub.vnet_id, vnet_key = "hub", registration_enabled = true }
      }
    }
  }
}

resource "azurerm_key_vault" "this" {
  name                          = var.key_vault_name
  location                      = var.location
  resource_group_name           = module.hub.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = true
  rbac_authorization_enabled    = true
  public_network_access_enabled = var.kv_public_access
  tags                          = var.tags

  network_acls {
    default_action             = "Deny"
    bypass                     = "None"
    virtual_network_subnet_ids = var.kv_allowed_subnet_ids
  }
}

module "vault_private_endpoint" {
  source = "../../modules/private-endpoint"

  name                           = "pe-example-hub-minimal-vault"
  location                       = var.location
  resource_group_name            = module.hub.resource_group_name
  subnet_id                      = module.hub.subnet_ids["snet-pe"]
  private_connection_resource_id = azurerm_key_vault.this.id
  subresource_names              = ["vault"]
  private_dns_zone_ids           = [module.private_dns.zone_ids["privatelink.vaultcore.azure.net"]]
  tags                           = var.tags
}

resource "azurerm_user_assigned_identity" "router" {
  for_each = toset(["one", "two"])

  name                = "uai-example-hub-router-${each.key}"
  location            = var.location
  resource_group_name = module.hub.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_assignment" "router_secret_user" {
  for_each = var.create_routers ? azurerm_user_assigned_identity.router : {}

  scope                = "${azurerm_key_vault.this.id}/secrets/${var.oauth_secret_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value.principal_id
}

module "ts_router" {
  for_each = var.create_routers ? {
    one = { private_ip_address = "10.0.0.4", zone = "1" }
    two = { private_ip_address = "10.0.0.5", zone = "2" }
  } : {}
  source = "../../modules/ts-router"

  name                 = "ts-router-example-${each.key}"
  location             = var.location
  resource_group_name  = module.hub.resource_group_name
  zone                 = each.value.zone
  subnet_id            = module.hub.subnet_ids["snet-app"]
  private_ip_address   = each.value.private_ip_address
  admin_username       = var.admin_username
  admin_ssh_public_key = var.admin_ssh_public_key
  identity = {
    id        = azurerm_user_assigned_identity.router[each.key].id
    client_id = azurerm_user_assigned_identity.router[each.key].client_id
  }
  bootstrap_dependency_id = azurerm_role_assignment.router_secret_user[each.key].id
  tags                    = var.tags

  tailscale = {
    key_vault_name    = var.key_vault_name
    oauth_secret_name = var.oauth_secret_name
    advertise_routes  = ["10.0.0.0/16"]
    tags              = var.tailscale_tags
    hostname          = "ts-router-example-${each.key}"
  }
  unbound = {
    allowed_cidrs = ["10.0.0.0/16", "100.64.0.0/10"]
  }

  depends_on = [
    module.vault_private_endpoint,
    module.private_dns,
  ]
}
