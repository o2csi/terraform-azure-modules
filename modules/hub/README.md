# hub

Creates an Azure resource group, hub VNet, subnets, and per-subnet NSGs. Every
subnet gets an NSG, even when `nsg_rules` is empty. Each NSG receives the
non-optional `DenyInternetInbound` rule at priority 4000; it cannot be omitted.
Caller rules cannot reserve priority 4000, repeat a name or priority in the same
subnet, or allow inbound traffic from Internet, wildcard, public, or non-private
prefixes. Inbound Allow sources are limited to RFC1918 or CGNAT (`100.64.0.0/10`)
CIDRs.

A rule naming more than one distinct source may name only CIDR prefixes or bare
IP addresses, of either family. Azure accepts a service tag or `*` solely as a
rule's single source, because its plural `sourceAddressPrefixes` argument takes
address prefixes only. Repeating one tag is fine and counts once, but the
spellings must match exactly: `["VirtualNetwork", "virtualNetwork"]` reads as two
sources and is refused.

`subnet_ids` is not released until every subnet NSG is associated and its rules,
including the mandatory deny, are created. This prevents a consumer from racing
the subnet's inbound-deny contract.

```hcl
# This configuration uses illustrative values. Replace them before applying.
module "hub" {
  source = "git::https://github.com/o2csi/terraform-azure-modules.git//modules/hub?ref=v0.1.0"

  resource_group_name = "rg-example-connectivity"
  location            = "westeurope"
  vnet_name           = "vnet-example-hub"
  address_space       = ["10.0.0.0/16"]
  subnets = {
    app = { address_prefix = "10.0.0.0/24" }
  }
}
```
