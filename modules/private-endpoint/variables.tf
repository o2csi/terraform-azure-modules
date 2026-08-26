variable "name" {
  description = "Private endpoint name."
  type        = string
}
variable "location" {
  description = "Azure region for the private endpoint."
  type        = string
}
variable "resource_group_name" {
  description = "Resource group for the private endpoint."
  type        = string
}
variable "subnet_id" {
  description = "Subnet ID for the private endpoint."
  type        = string
}
variable "private_connection_resource_id" {
  description = "Resource ID of the target private-link resource."
  type        = string
}
variable "subresource_names" {
  description = "Target private-link subresource names."
  type        = list(string)
}
variable "private_dns_zone_ids" {
  description = "Private DNS zone IDs to associate; empty disables the zone group."
  type        = list(string)
  default     = []
}
variable "is_manual_connection" {
  description = "Whether the private service connection requires target-owner approval."
  type        = bool
  default     = false
}
variable "request_message" {
  description = "Optional message presented to the target owner for a manual private endpoint approval."
  type        = string
  default     = null

  validation {
    condition     = var.is_manual_connection ? var.request_message != null && length(trimspace(var.request_message)) > 0 && length(var.request_message) <= 140 : var.request_message == null
    error_message = "request_message must be non-blank and at most 140 characters when is_manual_connection is true, and must be null when it is false."
  }
}
variable "ip_configurations" {
  description = "Optional static private IP configurations keyed by configuration name."
  type = map(object({
    private_ip_address = string
    subresource_name   = string
    member_name        = optional(string)
  }))
  default = {}
}
variable "tags" {
  description = "Tags applied to the private endpoint."
  type        = map(string)
  default     = {}
}
