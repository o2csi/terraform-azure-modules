# Shared router egress

Optional Internet SNAT on existing `ts-router` VMs with existing Standard public
IPs. No VM, public IP, NAT Gateway, subnet or route table is created. The caller
owns the resource group and hub subnet. The consuming project owns its private
application subnet and route `0.0.0.0/0 -> endpoint.private_ip`.

`enabled` defaults to false. Supply explicit application subnets in
`allowed_source_cidrs` and router IDs/NIC configuration/NSG names in `routers`.
Set `active` for one router at a time and validate it before activating the next.
Supply `subnet_network_security_group_name` when the hub subnet has an NSG.
Both NSG layers receive an inbound rule at priority 130 for the granted source
subnets towards `Internet` only; default VNet rules do not admit that path.
The internal Standard LB uses floating HA ports and an HTTP readiness probe restricted
to Azure probes. Router SNAT preserves the return path through the selected VM;
existing connections can be lost on failover. Neither Tailscale HA nor a healthy
HTTP listener alone proves forwarding from a spoke: perform actual spoke tests.

The extension preserves immutable cloud-init. It validates and atomically
replaces the module-owned nftables file, retaining the original in
`/var/lib/o2csi-egress/baseline.nft`. The existing firewall boot service reloads
the augmented rules. Health validates IPv4 forwarding, the loaded rules digest
and direct HTTPS egress. Only the explicitly granted source subnets can obtain
new Azure-interface-to-Azure-interface Internet forwarding. Private destinations
are denied on that path; existing Tailscale and DNS rules are retained.

## Rollback and updates

Withdraw the project's route association first (keep default outbound disabled).
Then set each router `active=false` and apply one at a time; set `enabled=false`
in the same plan that disables the last active router. Keep the `routers`
entries: deleting an Azure extension does **not** uninstall its guest changes.
Once both guests report their original firewall restored, the entire module may
be removed. Do not edit nftables concurrently;
the installer refuses a file changed by another writer. Changes to this module's
installer must also be rolled out individually using reviewed saved plans:
target the first extension for its update, verify it, then plan the complete
root for the remaining extension. Reject plans changing two active extensions.

Tests:

```sh
tofu init -backend=false
tofu test
python3 tests/test_egress.py
sudo unshare --mount --net --propagation private python3 tests/test_egress.py --network
```

The last test exercises real forwarding/SNAT and denial/rollback in isolated
network namespaces; it does not alter the host network.

The routed packet must reach the guest with its original Internet destination,
then traverse `forward` and SNAT. The frontend is a UDR next hop, not a service
address to bind on a guest loopback. The probe targets each NIC's private IP.
Azure also supports nonfloating HA-ports designs; do not infer the behavior of
routed packets from ordinary VIP-addressed application rules alone. This module
selects floating HA ports explicitly; actual spoke evidence remains required.
See [HA ports](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-ha-ports-overview)
and [the NVA routing lab, Internet egress](https://github.com/erjosito/azure-networking-lab#lab6).
