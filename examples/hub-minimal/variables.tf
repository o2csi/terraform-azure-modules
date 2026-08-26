variable "subscription_id" {
  description = "Azure subscription ID for this example."
  type        = string
}
variable "tenant_id" {
  description = "Microsoft Entra tenant ID for the Key Vault."
  type        = string
}
variable "location" {
  description = "Azure region. Verify image and zone availability before applying."
  type        = string
  default     = "westeurope"
}
variable "resource_group_name" {
  description = "Resource group name."
  type        = string
  default     = "rg-example-hub-minimal"
}
variable "key_vault_name" {
  description = "Key Vault name. This default is illustrative; verify global availability before applying."
  type        = string
  default     = "kv-example-hub-minimal"
}
variable "kv_public_access" {
  description = "Whether Key Vault public network access is enabled."
  type        = bool
  default     = false
}
variable "kv_allowed_subnet_ids" {
  description = "Subnets permitted by Key Vault network ACLs."
  type        = list(string)
  default     = []
}
variable "oauth_secret_name" {
  description = "Versionless Key Vault OAuth secret name. Seed this secret out-of-band before enabling routers; never provide its value in HCL."
  type        = string
  default     = "example-tailscale-oauth"
}
variable "create_routers" {
  description = "Stage 2 switch. False creates the vault, private endpoint, DNS, and router identities only; after seeding oauth_secret_name out-of-band, set true to create routers."
  type        = bool
  default     = false
}
variable "admin_username" {
  description = "Router VM administrator username."
  type        = string
  default     = "example-admin"
}
variable "admin_ssh_public_key" {
  description = "Router VM SSH public key."
  type        = string
  sensitive   = true
}
variable "tailscale_tags" {
  description = "Illustrative Tailscale tags advertised by routers; replace before applying."
  type        = list(string)
  default     = ["tag:example-router"]
}
variable "tags" {
  description = "Tags applied to all taggable resources."
  type        = map(string)
  default     = {}
}
