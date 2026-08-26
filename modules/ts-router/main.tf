locals {
  nic_name       = coalesce(var.nic_name, "${var.name}-nic")
  public_ip_name = coalesce(var.public_ip_name, "${var.name}-pip")
  os_disk_name   = coalesce(var.os_disk_name, "${var.name}-osdisk")

  key_vault_secret_endpoint = "https://${var.tailscale.key_vault_name}.vault.azure.net/secrets/${var.tailscale.oauth_secret_name}"
  bootstrap_timeout_seconds = var.bootstrap.install_deadline_seconds + var.bootstrap.max_attempts * (var.bootstrap.retry_seconds + 60 + var.bootstrap.tailscale_timeout_seconds) + 120
  bootstrap_env = join("\n", [
    "IDENTITY_CLIENT_ID='${var.identity.client_id}'",
    "ADVERTISE_ROUTES='${join(",", var.tailscale.advertise_routes)}'",
    "ACCEPT_ROUTES='${var.tailscale.accept_routes ? "true" : "false"}'",
    "TAILSCALE_EPHEMERAL='${var.tailscale.ephemeral ? "true" : "false"}'",
    "TAILSCALE_PREAUTHORIZED='${var.tailscale.preauthorized ? "true" : "false"}'",
    "ADVERTISE_TAGS='${join(",", var.tailscale.tags)}'",
    "HOSTNAME='${var.tailscale.hostname}'",
    "MAX_ATTEMPTS='${var.bootstrap.max_attempts}'",
    "RETRY_SECONDS='${var.bootstrap.retry_seconds}'",
    "TAILSCALE_TIMEOUT_SECONDS='${var.bootstrap.tailscale_timeout_seconds}'",
    "INSTALL_DEADLINE_SECONDS='${var.bootstrap.install_deadline_seconds}'",
    "TAILSCALE_VERSION='${var.tailscale_version == null ? "" : var.tailscale_version}'",
    "KEY_VAULT_SECRET_ENDPOINT='${local.key_vault_secret_endpoint}'",
    "ROUTER_PRIVATE_IP='${var.private_ip_address}'",
    "HEALTH_CHECK_FQDN='${var.bootstrap.health_check_fqdn}'",
    "HEALTH_CHECK_PRIVATE_FQDN='${var.bootstrap.health_check_private_fqdn == null ? "" : var.bootstrap.health_check_private_fqdn}'",
  ])
  unbound_config = join("\n", concat([
    "server:",
    "  interface: ${var.private_ip_address}",
    "  interface: 127.0.0.1",
    "  access-control: 127.0.0.0/8 allow",
    "  # Self-only, for the local health check.",
    "  access-control: ${var.private_ip_address}/32 allow",
    ], [for cidr in var.unbound.allowed_cidrs : "  access-control: ${cidr} allow"], [
    "  # Private answers must pass because the upstream is the trusted Azure resolver.",
    "forward-zone:",
    "  name: \".\"",
    # 168.63.129.16 is the Azure platform address (WireServer), a fixed
    # provider-side constant rather than a deployment-specific value. Keep this
    # note in the Terraform source: the rendered string below becomes the VM's
    # custom_data, and changing that forces the VM to be replaced.
    "  forward-addr: 168.63.129.16",
    "",
  ]))
  nftables_config = join("\n", concat([
    "flush table inet ts_router",
    "table inet ts_router {",
    "  chain input {",
    "    type filter hook input priority filter; policy drop;",
    "    iifname \"lo\" accept",
    "    ct state established,related accept",
    ], flatten([for cidr in var.unbound.allowed_cidrs : [
      "    ip saddr ${cidr} udp dport 53 accept",
      "    ip saddr ${cidr} tcp dport 53 accept",
    ]]), [
    "  }",
    "  chain forward {",
    "    type filter hook forward priority filter; policy drop;",
    "    ct state established,related accept",
    "    iifname \"tailscale0\" oifname != \"tailscale0\" accept",
    "    iifname != \"tailscale0\" oifname \"tailscale0\" accept",
    "  }",
    "  chain output {",
    "    type filter hook output priority filter; policy accept;",
    "  }",
    "}",
    "",
  ]))
}

resource "terraform_data" "bootstrap_dependency" {
  input = var.bootstrap_dependency_id
}

resource "azurerm_public_ip" "this" {
  count = var.public_ip_enabled ? 1 : 0

  name                = local.public_ip_name
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zone == null ? null : [var.zone]
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  name                = local.nic_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_servers         = var.nic_dns_servers
  # This NIC is an NVA interface: Azure must forward packets not addressed to it.
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.private_ip_address
    public_ip_address_id          = try(azurerm_public_ip.this[0].id, null)
  }
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.name}-nic-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "deny_ssh_inbound" {
  name                        = "DenySshInbound"
  priority                    = 3900
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "deny_internet_inbound" {
  name                        = "DenyInternetInbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "allow_dns_udp_from_trusted" {
  name                        = "AllowDnsUdpFromTrusted"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefixes     = distinct(var.unbound.allowed_cidrs)
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "allow_dns_tcp_from_trusted" {
  name                        = "AllowDnsTcpFromTrusted"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefixes     = distinct(var.unbound.allowed_cidrs)
  destination_address_prefix  = "*"
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = var.name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  zone                            = var.zone
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this.id]
  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    bootstrap_env    = local.bootstrap_env
    bootstrap_script = file("${path.module}/files/ts-router-bootstrap.sh")
    firewall_script  = file("${path.module}/files/ts-router-firewall.sh")
    nftables_config  = local.nftables_config
    unbound_config   = local.unbound_config
    timeout_seconds  = local.bootstrap_timeout_seconds
  }))
  tags = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity.id]
  }

  boot_diagnostics {}

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    name                 = local.os_disk_name
    caching              = "ReadWrite"
    storage_account_type = var.os_disk.storage_account_type
    disk_size_gb         = var.os_disk.disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = var.image_version
  }

  depends_on = [
    terraform_data.bootstrap_dependency,
    azurerm_network_interface_security_group_association.this,
    azurerm_network_security_rule.deny_ssh_inbound,
    azurerm_network_security_rule.deny_internet_inbound,
    azurerm_network_security_rule.allow_dns_udp_from_trusted,
    azurerm_network_security_rule.allow_dns_tcp_from_trusted,
  ]
}
