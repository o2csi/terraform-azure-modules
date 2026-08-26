variable "name" {
  description = "Virtual machine name; also prefixes default NIC, public IP, and OS disk names."
  type        = string
}
variable "nic_name" {
  description = "Optional NIC name."
  type        = string
  default     = null
}
variable "public_ip_name" {
  description = "Optional public IP name."
  type        = string
  default     = null
}
variable "os_disk_name" {
  description = "Optional OS disk name."
  type        = string
  default     = null
}
variable "location" {
  description = "Azure region for all resources."
  type        = string
}
variable "resource_group_name" {
  description = "Resource group containing the router."
  type        = string
}
variable "zone" {
  description = "Optional availability zone applied to the VM and public IP; the VM OS disk inherits the VM zone."
  type        = string
  default     = null
}
variable "subnet_id" {
  description = "Subnet ID for the router NIC."
  type        = string
}
variable "private_ip_address" {
  description = "Static private IP address for the router NIC."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.private_ip_address)) && can(cidrhost("${var.private_ip_address}/32", 0))
    error_message = "private_ip_address must be an IPv4 address."
  }
}
variable "nic_dns_servers" {
  description = "DNS resolvers configured directly on the NIC. The Azure platform address (WireServer) default avoids forwarder bootstrap deadlock."
  type        = list(string)
  default = [
    # Azure platform address (WireServer), not a deployment-specific value.
    "168.63.129.16",
  ]
}
variable "public_ip_enabled" {
  description = "Whether to create a Standard static public IP for explicit VM egress."
  type        = bool
  default     = true
}
variable "vm_size" {
  description = "Azure VM size."
  type        = string
  default     = "Standard_B1s"
}
variable "image_version" {
  description = "Canonical Ubuntu 24.04 LTS server image version. Verify the fixed SKU and zone availability in the destination subscription before first apply."
  type        = string
  default     = "latest"
}
variable "admin_username" {
  description = "Linux administrator username."
  type        = string
}
variable "admin_ssh_public_key" {
  description = "SSH public key installed for the administrator."
  type        = string
  sensitive   = true
}
variable "identity" {
  description = "Caller-created user-assigned identity ID and client ID from the same identity resource."
  type = object({
    id        = string
    client_id = string
  })

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft.managedidentity/userassignedidentities/[^/]+$", lower(var.identity.id)))
    error_message = "identity.id must be a complete user-assigned identity resource ID, including its subscription and resource group."
  }

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.identity.client_id))
    error_message = "identity.client_id must be a UUID from the same user-assigned identity resource."
  }
}
variable "os_disk" {
  description = "OS disk settings. The disk is managed by azurerm_linux_virtual_machine."
  type = object({
    storage_account_type = optional(string, "StandardSSD_LRS")
    disk_size_gb         = optional(number, 30)
  })
  default = {}
}
variable "tailscale" {
  description = "Tailscale bootstrap contract. The OAuth secret value is fetched at boot from this module-built public Azure Key Vault URI; sovereign clouds are out of scope."
  type = object({
    key_vault_name    = string
    oauth_secret_name = string
    advertise_routes  = list(string)
    accept_routes     = optional(bool, false)
    ephemeral         = optional(bool, false)
    preauthorized     = optional(bool, false)
    tags              = list(string)
    hostname          = string
  })
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.tailscale.key_vault_name)) && !strcontains(var.tailscale.key_vault_name, "--")
    error_message = "tailscale.key_vault_name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ and must not contain consecutive hyphens."
  }
  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,127}$", var.tailscale.oauth_secret_name))
    error_message = "tailscale.oauth_secret_name must match ^[A-Za-z0-9-]{1,127}$."
  }
  validation {
    condition     = length(var.tailscale.advertise_routes) > 0 && alltrue([for cidr in var.tailscale.advertise_routes : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", cidr)) && strcontains(cidr, "/") && can(cidrhost(cidr, 0))])
    error_message = "tailscale.advertise_routes must contain one or more IPv4 CIDRs."
  }
  validation {
    condition     = length(var.tailscale.tags) > 0 && alltrue([for tag in var.tailscale.tags : can(regex("^tag:[a-z0-9-]+$", tag))])
    error_message = "tailscale.tags must contain one or more tags matching ^tag:[a-z0-9-]+$."
  }
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.tailscale.hostname))
    error_message = "tailscale.hostname must be a DNS label matching ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$."
  }
}
variable "unbound" {
  description = "Private or CGNAT CIDRs permitted to query Unbound. Public DNS service is outside this module's contract."
  type = object({
    allowed_cidrs = list(string)
  })
  validation {
    condition = length(var.unbound.allowed_cidrs) > 0 && length(var.unbound.allowed_cidrs) <= 20 && length(distinct(var.unbound.allowed_cidrs)) == length(var.unbound.allowed_cidrs) && alltrue([
      for cidr in var.unbound.allowed_cidrs :
      !contains(["internet", "*", "0.0.0.0/0"], lower(cidr)) &&
      can(cidrhost(cidr, 0)) &&
      (
        can(regex("^10\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}/([89]|[12][0-9]|3[0-2])$", cidr)) ||
        can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]{1,3}\\.[0-9]{1,3}/(1[2-9]|[12][0-9]|3[0-2])$", cidr)) ||
        can(regex("^192\\.168\\.[0-9]{1,3}\\.[0-9]{1,3}/(1[6-9]|[12][0-9]|3[0-2])$", cidr)) ||
        can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]{1,3}\\.[0-9]{1,3}/(1[0-9]|[12][0-9]|3[0-2])$", cidr))
      )
    ])
    error_message = "unbound.allowed_cidrs must contain 1 to 20 unique RFC1918 or 100.64.0.0/10 CGNAT IPv4 CIDRs; public prefixes including 0.0.0.0/0 are forbidden."
  }
}
variable "bootstrap" {
  description = "Bounded install, retry, and resolver-health controls for managed-identity and Tailscale bootstrap."
  type = object({
    max_attempts              = optional(number, 30)
    retry_seconds             = optional(number, 20)
    tailscale_timeout_seconds = optional(number, 60)
    install_deadline_seconds  = optional(number, 900)
    health_check_fqdn         = optional(string, "cloudflare.com")
    health_check_private_fqdn = optional(string)
  })
  default = {}
  validation {
    condition     = floor(var.bootstrap.max_attempts) == var.bootstrap.max_attempts && var.bootstrap.max_attempts >= 1 && var.bootstrap.max_attempts <= 200 && floor(var.bootstrap.retry_seconds) == var.bootstrap.retry_seconds && var.bootstrap.retry_seconds >= 1 && var.bootstrap.retry_seconds <= 300 && floor(var.bootstrap.tailscale_timeout_seconds) == var.bootstrap.tailscale_timeout_seconds && var.bootstrap.tailscale_timeout_seconds >= 1 && var.bootstrap.tailscale_timeout_seconds <= 600 && floor(var.bootstrap.install_deadline_seconds) == var.bootstrap.install_deadline_seconds && var.bootstrap.install_deadline_seconds >= 1 && var.bootstrap.install_deadline_seconds <= 3600
    error_message = "bootstrap.max_attempts must be 1-200, retry_seconds 1-300, tailscale_timeout_seconds 1-600, and install_deadline_seconds 1-3600; all must be integers."
  }
  validation {
    condition     = length(trimsuffix(var.bootstrap.health_check_fqdn, ".")) <= 253 && can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+\\.?$", var.bootstrap.health_check_fqdn))
    error_message = "bootstrap.health_check_fqdn must be a DNS name with at least two labels and at most 253 characters, excluding an optional trailing dot."
  }
  validation {
    condition     = var.bootstrap.health_check_private_fqdn == null || length(trimsuffix(var.bootstrap.health_check_private_fqdn, ".")) <= 253 && can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+\\.?$", var.bootstrap.health_check_private_fqdn))
    error_message = "bootstrap.health_check_private_fqdn must be null or a DNS name with at least two labels and at most 253 characters, excluding an optional trailing dot."
  }
}
variable "tailscale_version" {
  description = "Optional exact Tailscale APT package version. Null installs the latest version from Tailscale's signed Ubuntu noble repository."
  type        = string
  default     = null

  validation {
    condition     = var.tailscale_version == null || can(regex("^[0-9][A-Za-z0-9.+:~_-]*$", var.tailscale_version))
    error_message = "tailscale_version must be null or a safe APT version string."
  }
}
variable "bootstrap_dependency_id" {
  description = "Caller-owned dependency token, normally the router's secret role-assignment ID. It creates a per-router graph edge without changing Azure resources."
  type        = string

  validation {
    condition     = trimspace(var.bootstrap_dependency_id) != ""
    error_message = "bootstrap_dependency_id must be a non-blank caller-supplied dependency token, normally the Key Vault secret role-assignment ID."
  }
}
variable "tags" {
  description = "Tags applied to every taggable resource created by this module."
  type        = map(string)
  default     = {}
}
