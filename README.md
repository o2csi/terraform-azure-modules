# terraform-azure-modules

Reusable OpenTofu modules for an Azure hub-and-spoke network with private DNS,
private endpoints, and Tailscale-backed resolver routers. All modules require
OpenTofu `>= 1.11` and `hashicorp/azurerm ~> 4.0`.

## Modules

| Module | Purpose |
|---|---|
| [landing-zone](./modules/landing-zone) | Platform VNet shell and both hub/spoke peerings; project owns subnets and workloads |
| [hub](./modules/hub) | Resource group, hub VNet, subnets, and per-subnet NSGs with mandatory internet-inbound deny rule and no public inbound Allows |
| [private-dns](./modules/private-dns) | Private DNS zones and VNet links with plan-time key-based single-registration protection |
| [private-endpoint](./modules/private-endpoint) | Private Endpoint with optional private DNS zone group and automatic or manual connection request |
| [ts-router](./modules/ts-router) | Tailscale subnet-router VM, Unbound forwarder, and module-owned NIC NSG |

## Inputs and intended use

- `hub` builds a resource group, VNet, subnets, NSG rules, and optional DNS
  server list from `resource_group_name`, `location`, `vnet_name`,
  `address_space`, `subnets`, `dns_servers`, and `tags`.
- `private-dns` creates private DNS zones and VNet links from
  `resource_group_name`, `zones`, and `tags`.
- `private-endpoint` connects an Azure resource to a subnet using `name`,
  `location`, `resource_group_name`, `subnet_id`,
  `private_connection_resource_id`, `subresource_names`, optional private DNS
  zone IDs, and connection settings.
- `ts-router` creates a Tailscale subnet-router and Unbound resolver from its
  resource names and location, subnet and static private IP, SSH key,
  user-assigned identity, Tailscale bootstrap settings, trusted CIDRs, and
  optional VM/network settings.

Use these modules to compose a private Azure hub with private endpoints and
resolver routers. Review each module's README for its complete input contract.

## Usage

```hcl
# This configuration uses illustrative values. Replace them before applying.
module "hub" {
  source = "git::https://github.com/o2csi/terraform-azure-modules.git//modules/hub?ref=v0.1.0"

  resource_group_name = "rg-example-connectivity"
  location            = "westeurope"
  vnet_name           = "vnet-example-hub"
  address_space       = ["10.0.0.0/16"]
  subnets             = { app = { address_prefix = "10.0.0.0/24" } }
}
```

See [examples/hub-minimal](./examples/hub-minimal) for the full composition.

## Operating notes

- Verify the Canonical Ubuntu 24.04 LTS `server` SKU, VM-zone availability, and Key Vault name in the destination subscription before the first apply.
- The two routers provide resolver and tailnet-to-Azure client-side failover. Azure-to-LAN traffic initiated from Azure through a UDR still has a single next hop; that direction is not HA.
- The staged example creates vault, private endpoint, DNS, and identities first. Stage 1 needs an operator environment that can route and resolve private DNS into the VNet (or an equivalent documented bootstrap posture) to seed the OAuth secret out-of-band. Confirm the Private Endpoint connection is `Approved` before enabling routers. The secret must never be modeled as a value in HCL.
- `ts-router` takes an identity object with an ID and client ID from the same caller-created UAMI and constructs the public-Azure Key Vault secret URI from validated vault and secret names. The OAuth secret is fetched at boot and passed from a `0600` tmpfs file, never as argv or persistent storage.
- Router public IPs have both the hub subnet NSG and a module-owned NIC NSG. The NIC NSG permits trusted DNS queries, denies SSH at priority 3900, and denies Internet inbound before the VM is created. Azure IP forwarding is enabled on the router NIC.
- The private-endpoint module supports automatic or manual connection requests; this example submits an automatic request. Approval/readiness must be observed with `azurerm_private_endpoint_connection` when a consumer depends on it.
