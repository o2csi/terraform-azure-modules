# Landing-zone VNet shell

Creates only the platform resource group, the spoke VNet and both hub/spoke
peerings. The existing hub is read through an Azure data source. The caller's
platform identity needs authority over the spoke RG and the hub peering; this
module creates no role or role assignment.

The project repository owns its separate RG, standalone subnets, NSGs, route
tables, egress and VMs. This module declares no inline or standalone subnet and
ignores subsequent changes to the VNet's subnet collection. It also creates no
public IP, NAT gateway, VM, cluster or application resource.

Use one environment CIDR from the platform's authoritative address plan, not the
whole project reservation. Supply both private DNS router addresses. Both
peerings permit forwarded traffic for subnet-router access; neither enables
Azure VPN gateway transit. Peering alone does not supply Internet egress or
authorize inbound traffic through project NSGs.

Peering names contain a capped readable target name and a suffix derived from
the target VNet's case-normalized resource ID. They stay below Azure's 80-character
limit even for 64-character VNet names, and distinguish identical VNet names in
different resource groups. They are resolved when the target VNet ID is available.

The VNet and peerings belong in the platform state. A project looks up its VNet
through explicit identifiers or Azure data sources, without reading platform
state. Creating or deleting project subnets requires a role scoped to this VNet;
no Contributor grant on the platform RG is needed by the project.

Before applying, inventory any existing VNet/peerings and resolve ownership.
An empty plan against this new module is not an inventory of unmanaged resources.
Do not destroy the VNet while project-owned subnets or workloads remain.
