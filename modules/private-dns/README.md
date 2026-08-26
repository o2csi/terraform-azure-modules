# private-dns

Creates private DNS zones and VNet links. Every caller-supplied `vnet_key` must
be non-blank. At validate/plan time, the module lowercases that key and refuses
registration for the same key in more than one zone; it also refuses duplicate
key links in the same zone. This is a caller-key guarantee, not proof that two
unknown Azure IDs resolve to different VNets. Before any zone or link is
created, an apply-time guard compares lowercased supplied `vnet_id` values and
refuses a duplicate registration ID.

```hcl
# This configuration uses illustrative values. Replace them before applying.
module "private_dns" {
  source = "git::https://github.com/o2csi/terraform-azure-modules.git//modules/private-dns?ref=v0.1.0"

  resource_group_name = "rg-example-connectivity"
  zones = {
    "privatelink.vaultcore.azure.net" = {
      vnet_links = {
        hub = { vnet_key = "hub", vnet_id = module.hub.vnet_id }
      }
    }
  }
}
```
