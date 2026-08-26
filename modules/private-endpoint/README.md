# private-endpoint

Creates an Azure Private Endpoint and, when `private_dns_zone_ids` is non-empty,
its private DNS zone group. Azure creates the target private A record through that zone group.
Set `is_manual_connection = false` (the default) for an automatic connection
request, or set it to `true` and provide a non-blank `request_message` of at
most 140 characters for approval by the target owner.
The `hashicorp/azurerm` 4.x resource schema exposes the requested approval mode
and the allocated IP, but not Azure's resulting Pending, Approved, or Rejected
state; consumers that require observed readiness must query
`azurerm_private_endpoint_connection`.

```hcl
# This configuration uses illustrative values. Replace them before applying.
module "vault_private_endpoint" {
  source = "git::https://github.com/o2csi/terraform-azure-modules.git//modules/private-endpoint?ref=v0.1.0"

  name                           = "pe-example-vault"
  location                       = "westeurope"
  resource_group_name            = "rg-example-connectivity"
  subnet_id                      = module.hub.subnet_ids["example-private-endpoints"]
  private_connection_resource_id = azurerm_key_vault.this.id
  subresource_names              = ["vault"]
  private_dns_zone_ids           = [module.private_dns.zone_ids["privatelink.vaultcore.azure.net"]]
}
```
