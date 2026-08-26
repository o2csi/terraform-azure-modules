variable "resource_group_name" {
  description = "Resource group in which private DNS zones are created."
  type        = string
}

variable "zones" {
  description = "Private zones keyed by real zone name and their VNet links."
  type = map(object({
    vnet_links = map(object({
      vnet_id              = string
      vnet_key             = string
      registration_enabled = optional(bool, false)
    }))
  }))

  validation {
    condition = alltrue(flatten([
      for zone in values(var.zones) : [
        for link in values(zone.vnet_links) : trimspace(link.vnet_key) != ""
      ]
    ]))
    error_message = "Every vnet_key must be non-blank."
  }

  validation {
    condition = length(flatten([
      for zone_name, zone in var.zones : [
        for link in values(zone.vnet_links) : lower(trimspace(link.vnet_key)) if link.registration_enabled
      ]
      ])) == length(distinct(flatten([
        for zone_name, zone in var.zones : [
          for link in values(zone.vnet_links) : lower(trimspace(link.vnet_key)) if link.registration_enabled
        ]
    ])))
    error_message = "registration_enabled may be true for a caller-supplied VNet key in only one private zone (comparison is case-insensitive)."
  }

  validation {
    condition = length(flatten([
      for zone_name, zone in var.zones : [
        for link in values(zone.vnet_links) : "${lower(zone_name)}/${lower(trimspace(link.vnet_key))}"
      ]
      ])) == length(distinct(flatten([
        for zone_name, zone in var.zones : [
          for link in values(zone.vnet_links) : "${lower(zone_name)}/${lower(trimspace(link.vnet_key))}"
        ]
    ])))
    error_message = "A zone may link a caller-supplied VNet key only once (comparison is case-insensitive)."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource created by this module."
  type        = map(string)
  default     = {}
}
