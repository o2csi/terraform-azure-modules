# ts-router

Creates one Linux VM that is both a Tailscale subnet router and an Unbound
forwarder. Its NIC defaults to Azure DNS (`168.63.129.16`) so forwarding remains
available during bootstrap; this is the Azure platform address (WireServer), not
an example-specific choice. Tailscale is explicitly started with `--accept-dns=false`.

```hcl
# This configuration uses illustrative values. Replace them before applying.
resource "azurerm_role_assignment" "example_router_secret_user" {
  scope                = "${azurerm_key_vault.example.id}/secrets/example-tailscale-oauth"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.example_router.principal_id
}

module "router" {
  source = "git::https://github.com/o2csi/terraform-azure-modules.git//modules/ts-router?ref=v0.1.0"

  name                = "ts-router-example-1"
  location            = "westeurope"
  resource_group_name = "rg-example-connectivity"
  subnet_id           = module.hub.subnet_ids["example-app"]
  private_ip_address  = "10.0.0.4"
  admin_username       = "example-admin"
  admin_ssh_public_key = file(pathexpand("~/.ssh/id_ed25519.pub"))
  identity = {
    id        = azurerm_user_assigned_identity.example_router.id
    client_id = "00000000-0000-0000-0000-000000000000"
  }
  bootstrap_dependency_id = azurerm_role_assignment.example_router_secret_user.id
  tailscale = {
    key_vault_name   = "kv-example-router"
    oauth_secret_name = "example-tailscale-oauth"
    advertise_routes  = ["10.0.0.0/16"]
    tags              = ["tag:example-router"]
    hostname          = "ts-router-example-1"
  }
  unbound = {
    allowed_cidrs = ["10.0.0.0/16", "100.64.0.0/10"]
  }
}
```

This module owns Canonical Ubuntu 24.04 LTS `server` images only; `image_version`
defaults to `latest`. Verify that fixed SKU and VM-zone availability with `az vm
image list` in the destination subscription before the first apply. This module
intentionally opens no SSH path at the NIC level. The VM enables managed
`boot_diagnostics {}`: Serial Console requires boot diagnostics and an account
with console permission, and is useful for kernel and boot output. Its
passwordless Linux administrator cannot log in through that console. Azure Run
Command is the working break-glass execution path. The NIC has Azure IP
forwarding enabled because it is an NVA interface. The guest firewall explicitly allows routed traffic between
`tailscale0` and the VNet NIC; a default DROP forward policy without it silently
breaks subnet routing. The default Tailscale subnet-route SNAT is kept.

The caller supplies both the UAMI resource ID and client ID from the same identity
resource, and the module builds the only secret destination as
`https://<key-vault-name>.vault.azure.net/secrets/<secret-name>`;
sovereign-cloud Key Vault suffixes are not supported. On first connection, the
secret is fetched at boot and passed to `tailscale up` through a `0600` tmpfs file
under `/run/ts-router/`, then removed. It is never an HCL value, persistent file,
or command-line value. Subsequent boots detect a running Tailscale backend and
reapply non-secret preferences without fetching it again.

`tailscale.ephemeral` defaults to `false`, so the router keeps its tailnet node
identity across ordinary downtime. `tailscale.preauthorized` also defaults to
`false`. Device approval is separate from route approval: set
`tailscale.preauthorized = true` when the OAuth client is allowed to generate the
tagged auth key; if device approval is enabled on the tailnet, the node needs
manual approval unless `tailscale.preauthorized = true`. Route approval or
`autoApprovers` remains a separate tailnet policy decision.
`tailscale.ephemeral` and `tailscale.preauthorized` are authoritative and override
any modifiers already present in the stored secret.

`ts-router-firewall.service` loads `/etc/nftables.conf` before `tailscaled` on
every boot and is independent of the distro `nftables.service`. The configuration
flushes only `table inet ts_router`, then recreates the guest input and forwarding
rules; it never uses a global `flush ruleset`. Bootstrap disables the distro
`nftables.service` rather than allowing two units to manage this table. During
bootstrap, Tailscale is installed from the signed stable `pkgs.tailscale.com`
Ubuntu noble repository, while nftables, Unbound, and dnsutils are installed from
the Ubuntu repositories. Only absent, partially configured, or pinned-version-mismatched packages are installed; a
healthy reboot therefore makes no repository download or APT update. The whole
installation phase is bounded by
`bootstrap.install_deadline_seconds` (default 900 seconds).
`unbound.allowed_cidrs` accepts only 1–20 unique RFC1918 or `100.64.0.0/10`
CGNAT CIDRs: a public DNS service is out of contract.

The module owns a NIC NSG as well as inheriting the subnet NSG. It has exactly
two trusted-DNS allow rules (UDP priority 100 and TCP priority 110), a TCP/22
deny at priority 3900, and an Internet inbound deny at priority 4000 before the
VM is created. `tailscale.accept_routes` defaults to `false`: HA routers
advertising the same prefixes must not install each other’s routes.

Bootstrap publishes an atomically replaced `/var/lib/ts-router/status` as
`initializing`, `ok`, or `failed: <step> (<last_failure>)`. The same terminal
event determines that file and the unit result: only a zero exit after the
success marker publishes `ok`. `ok` reports checks observed at bootstrap
completion: local IP forwarding, the presence of the required DNS and
`tailscale0` accept rules, a running Tailscale backend, a Tailscale postrouting
chain, and a bounded query to the router private IP that returns `NOERROR` with
a non-empty answer for `bootstrap.health_check_fqdn` (default `cloudflare.com`)
and, when set, `bootstrap.health_check_private_fqdn`; it does not attest to
later freshness, exact rule ordering, or exclusive rule ownership. The unit
timeout is
`install_deadline_seconds + max_attempts * (retry_seconds + 60 +
tailscale_timeout_seconds) + 120`: 60 seconds are the two curl maxima, and 120
seconds covers service start and health checks. `tailscale up` has
`--timeout=<tailscale_timeout_seconds>s`. Route approval, tailnet
`autoApprovers`, ACL grants, and client route acceptance remain consumer
prerequisites; `status=ok` does not assert any of them.
