resource "azurerm_private_endpoint" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name}-connection"
    private_connection_resource_id = var.private_connection_resource_id
    subresource_names              = var.subresource_names
    is_manual_connection           = var.is_manual_connection
    request_message                = var.request_message
  }

  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) == 0 ? [] : [true]
    content {
      name                 = "${var.name}-dns"
      private_dns_zone_ids = var.private_dns_zone_ids
    }
  }

  dynamic "ip_configuration" {
    for_each = var.ip_configurations
    content {
      name               = ip_configuration.key
      private_ip_address = ip_configuration.value.private_ip_address
      subresource_name   = ip_configuration.value.subresource_name
      member_name        = ip_configuration.value.member_name
    }
  }
}
