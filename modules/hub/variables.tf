variable "resource_group_name" {
  description = "Name of the resource group created for the hub network."
  type        = string
}

variable "location" {
  description = "Azure region for the resource group, virtual network, and NSGs."
  type        = string
}

variable "vnet_name" {
  description = "Name of the hub virtual network."
  type        = string
}

variable "address_space" {
  description = "CIDR ranges assigned to the virtual network."
  type        = list(string)
}

variable "dns_servers" {
  description = "DNS servers distributed by the virtual network."
  type        = list(string)
  default     = []
}

variable "subnets" {
  description = "Subnets keyed by logical name. Every subnet receives an NSG; nsg_rules is optional."
  type = map(object({
    address_prefix                    = string
    service_endpoints                 = optional(list(string), [])
    private_endpoint_network_policies = optional(string, "Enabled")
    nsg_rules = optional(list(object({
      name                    = string
      priority                = number
      direction               = string
      access                  = string
      protocol                = string
      source_address_prefixes = list(string)
      destination_port_ranges = list(string)
    })), [])
  }))

  validation {
    condition = alltrue([
      for subnet in values(var.subnets) : contains(["Enabled", "Disabled", "NetworkSecurityGroupEnabled", "RouteTableEnabled"], subnet.private_endpoint_network_policies)
    ])
    error_message = "private_endpoint_network_policies must be a valid Azure subnet policy setting."
  }

  validation {
    condition = alltrue([
      for subnet in values(var.subnets) : alltrue([
        for rule in subnet.nsg_rules : !contains(rule.destination_port_ranges, "*") || length(rule.destination_port_ranges) == 1
      ])
    ])
    error_message = "A destination_port_ranges list holding \"*\" must hold nothing else: \"*\" matches every destination port, so the other entries have no effect."
  }

  validation {
    condition = alltrue([
      for subnet in values(var.subnets) : alltrue([
        for rule in subnet.nsg_rules : rule.priority != 4000
      ])
    ])
    error_message = "subnets[*].nsg_rules may not use priority 4000; it is reserved for DenyInternetInbound."
  }

  validation {
    condition = alltrue([
      for subnet in values(var.subnets) : length(distinct([for rule in subnet.nsg_rules : lower(rule.name)])) == length(subnet.nsg_rules) && length(distinct([for rule in subnet.nsg_rules : rule.priority])) == length(subnet.nsg_rules)
    ])
    error_message = "subnets[*].nsg_rules must not repeat a rule name (case-insensitive) or priority within a subnet."
  }

  validation {
    condition = alltrue([
      for subnet in values(var.subnets) : alltrue([
        for rule in subnet.nsg_rules : !(lower(rule.direction) == "inbound" && lower(rule.access) == "allow") || alltrue([
          for prefix in rule.source_address_prefixes :
          !contains(["internet", "*", "0.0.0.0/0"], lower(prefix)) &&
          can(cidrhost(prefix, 0)) &&
          (
            can(regex("^10\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}/([89]|[12][0-9]|3[0-2])$", prefix)) ||
            can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]{1,3}\\.[0-9]{1,3}/(1[2-9]|[12][0-9]|3[0-2])$", prefix)) ||
            can(regex("^192\\.168\\.[0-9]{1,3}\\.[0-9]{1,3}/(1[6-9]|[12][0-9]|3[0-2])$", prefix)) ||
            can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]{1,3}\\.[0-9]{1,3}/(1[0-9]|[12][0-9]|3[0-2])$", prefix))
          )
        ])
      ])
    ])
    error_message = "Inbound Allow rules may source only RFC1918 or 100.64.0.0/10 CGNAT CIDRs; Internet, *, 0.0.0.0/0, and public prefixes are forbidden."
  }

  # Azure has no form for two service tags in one rule: `sourceAddressPrefix`
  # takes one tag, `sourceAddressPrefixes` takes address prefixes only. A rule
  # naming several sources therefore renders the plural argument, and a tag among
  # them is rejected at apply. Refuse it here instead, so the plan does not run.
  # The message states the rule, not the offending value: a validation block
  # emits one message for the whole condition.
  #
  # The test is whether each value parses as an address, because Azure's tag
  # catalogue changes and varies by cloud, so no allowlist of tags can be
  # correct. `cidrhost` accepts IPv4 and IPv6 CIDRs; the two suffixed attempts
  # accept a bare address of either family, so the module keeps the full set
  # Azure's plural argument accepts.
  #
  # `distinct` is case-sensitive, so `["VirtualNetwork", "virtualNetwork"]` reads
  # as two sources and is refused. Azure treats those as one tag, but choosing a
  # spelling to render on the caller's behalf is a decision the module should not
  # make silently; the README states the requirement.
  validation {
    condition = alltrue([
      for subnet in values(var.subnets) : alltrue([
        for rule in subnet.nsg_rules :
        length(distinct(rule.source_address_prefixes)) <= 1 || alltrue([
          for prefix in distinct(rule.source_address_prefixes) :
          can(cidrhost(prefix, 0)) ||
          can(cidrhost("${prefix}/32", 0)) ||
          can(cidrhost("${prefix}/128", 0))
        ])
      ])
    ])
    error_message = "A rule naming more than one distinct source may name only CIDR prefixes or bare IP addresses. Azure accepts a service tag or \"*\" only as a rule's single source, and two spellings of one tag count as two sources."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource created by this module."
  type        = map(string)
  default     = {}
}
