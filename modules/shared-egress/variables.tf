variable "enabled" {
  description = "Enable the shared egress endpoint. Disable and apply to roll back guest configuration before removing this module."
  type        = bool
  default     = false
}

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "subnet_id" { type = string }
variable "frontend_ip" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

variable "allowed_source_cidrs" {
  description = "Explicit IPv4 application subnets allowed to use Internet egress; never an implicit subscription-wide grant."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for cidr in var.allowed_source_cidrs : can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) >= 24, false)])
    error_message = "Egress grants must be individual IPv4 subnets (/24 or narrower)."
  }
}

variable "routers" {
  description = "Existing router resources. Set active=true one router at a time; retain both entries during rollback so the guest uninstall runs."
  type = map(object({
    vm_id                       = string
    nic_id                      = string
    nic_ip_configuration        = string
    network_security_group_name = string
    private_ip                  = string
    active                      = bool
  }))
  default = {}
  validation {
    condition     = length(distinct([for router in values(var.routers) : lower(router.network_security_group_name)])) == length(var.routers)
    error_message = "Each router must use a distinct NIC NSG; sharing creates duplicate probe/transit rule ownership."
  }
}

variable "subnet_network_security_group_name" {
  description = "Existing hub subnet NSG, if attached: transit must pass both subnet and router NIC NSGs."
  type        = string
  default     = null
  validation {
    condition     = var.subnet_network_security_group_name == null ? true : !contains([for router in values(var.routers) : lower(router.network_security_group_name)], lower(var.subnet_network_security_group_name))
    error_message = "The subnet NSG must be distinct from all router NIC NSGs; shared-NSG topologies are not supported by this module."
  }
}
