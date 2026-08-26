# hub-minimal example

This is a validate-able composition example, not a production stack. **Every
value in this example is illustrative and must be replaced before applying.**
It is staged so a secret is never required while its vault is being created.

1. Stage 1 (default): apply with `create_routers = false`. This creates the hub,
   private DNS, Key Vault private endpoint, and caller-owned router identities.
   It requires an operator execution environment with routing and private DNS
   into the VNet (or the consumer's documented Key Vault bootstrap posture) to
   seed the secret; this example is not self-bootstrapping.
2. Seed the Key Vault secret named by `oauth_secret_name` out-of-band. Its value is
   never supplied to OpenTofu.
3. Before Stage 2, require the Private Endpoint connection to be approved:

   ```sh
   az network private-endpoint show --resource-group rg-example-hub-minimal --name pe-example-hub-minimal-vault --query 'privateLinkServiceConnections[0].privateLinkServiceConnectionState.status' --output tsv
   ```

   Continue only when the result is `Approved`, then set `create_routers = true`
   to create the two zonal Tailscale routers at `10.0.0.4` and `10.0.0.5`.
   Each waits for its secret role assignment, Key Vault private endpoint, and
   private DNS links.

Before an apply, verify the image SKU, B1s zone availability, and Key Vault name
in the target subscription. Use `file(pathexpand("~/.ssh/id_ed25519.pub"))` for
the router SSH public key when supplying a home-relative path.
