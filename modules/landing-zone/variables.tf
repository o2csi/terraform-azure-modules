variable "resource_group_name" {
  description = "Platform-owned resource group for the VNet shell, separate from the project resource group."
  type        = string
}

variable "location" {
  description = "Azure region of the platform resource group and spoke VNet."
  type        = string
}

variable "vnet_name" {
  description = "Name of the platform-owned spoke VNet."
  type        = string
}

variable "address_prefix" {
  description = "One environment IPv4 CIDR, allocated by the platform address plan."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.address_prefix))
    error_message = "address_prefix must be an IPv4 CIDR."
  }
}

variable "dns_servers" {
  description = "Private hub resolver addresses distributed to project nodes."
  type        = list(string)
  validation {
    condition     = length(distinct(var.dns_servers)) >= 2 && alltrue([for ip in var.dns_servers : can(cidrnetmask("${ip}/32"))])
    error_message = "Supply at least two distinct IPv4 DNS resolver addresses."
  }
}

variable "hub_resource_group_name" {
  description = "Resource group of the existing hub VNet."
  type        = string
}

variable "hub_vnet_name" {
  description = "Name of the existing hub VNet; its ID is read from Azure, not reconstructed by the project."
  type        = string
}

variable "tags" {
  description = "Platform ownership, project and environment tags."
  type        = map(string)
  default     = {}
}
