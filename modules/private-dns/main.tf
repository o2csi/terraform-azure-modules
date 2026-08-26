locals {
  links = merge([
    for zone_name, zone in var.zones : {
      for link_name, link in zone.vnet_links : "${zone_name}/${link_name}" => merge(link, {
        zone_name = zone_name
        link_name = link_name
      })
    }
  ]...)

  registration_vnet_keys = distinct([
    for link in values(local.links) : lower(trimspace(link.vnet_key)) if link.registration_enabled
  ])

  duplicate_registration_vnet_keys = [
    for vnet_key in local.registration_vnet_keys : vnet_key
    if length([for link in values(local.links) : link if link.registration_enabled && lower(trimspace(link.vnet_key)) == vnet_key]) > 1
  ]

  registration_vnet_ids = distinct([
    for link in values(local.links) : lower(link.vnet_id) if link.registration_enabled
  ])

  duplicate_registration_vnet_ids = [
    for vnet_id in local.registration_vnet_ids : vnet_id
    if length([for link in values(local.links) : link if link.registration_enabled && lower(link.vnet_id) == vnet_id]) > 1
  ]
}

resource "terraform_data" "registration_guard" {
  input = local.registration_vnet_keys

  lifecycle {
    precondition {
      condition     = length(local.duplicate_registration_vnet_keys) == 0
      error_message = "registration_enabled may be true for a caller-supplied VNet key in only one private zone. Offending VNet keys: ${join(", ", local.duplicate_registration_vnet_keys)}."
    }
  }
}

resource "terraform_data" "registration_id_guard" {
  input = local.registration_vnet_ids

  lifecycle {
    precondition {
      condition     = length(local.duplicate_registration_vnet_ids) == 0
      error_message = "registration_enabled may be true for an Azure VNet ID in only one private zone. Offending VNet IDs: ${join(", ", local.duplicate_registration_vnet_ids)}."
    }
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each = var.zones

  name                = each.key
  resource_group_name = var.resource_group_name
  tags                = var.tags

  depends_on = [terraform_data.registration_guard, terraform_data.registration_id_guard]
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.links

  name                  = each.value.link_name
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone_name].name
  virtual_network_id    = each.value.vnet_id
  registration_enabled  = each.value.registration_enabled
  tags                  = var.tags

  depends_on = [terraform_data.registration_guard, terraform_data.registration_id_guard]
}
