# -----------------------------------------------------------------------------
# network.tf - the private network the platform lives in.
#
# Layout (one spoke VNet; in a real landing zone it would peer to a hub with a
# firewall):
#   vnet-prequal-demo    10.10.0.0/16
#     snet-aks           10.10.0.0/22   AKS nodes (pods use a separate overlay range)
#     snet-private-ep    10.10.8.0/24   private endpoints (Key Vault)
#
# AKS uses Azure CNI Overlay: nodes take IPs from snet-aks, but pods get IPs
# from a separate pod CIDR (see aks.tf). That saves VNet address space, which
# matters when many spokes share one corporate IP plan.
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  address_space       = ["10.10.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.0.0/22"]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-ep"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.8.0/24"]

  # Applies NSG rules to private endpoint traffic too (off by default in Azure).
  private_endpoint_network_policies = "Enabled"
}

# Network Security Groups. With no custom rules, Azure's default rules apply:
# traffic inside the VNet and from the Azure load balancer is allowed, and all
# other inbound traffic from the internet is denied. Attaching an NSG to every
# subnet is a standard bank control (and a Checkov check).
resource "azurerm_network_security_group" "aks" {
  name                = "nsg-${local.name}-aks"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${local.name}-pe"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# Private DNS zone for Key Vault private endpoints. Linked to the VNet so that
# anything inside it (our AKS nodes) resolves <vault>.vault.azure.net to the
# PRIVATE IP of the endpoint instead of the public one.
resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "link-${local.name}"
  resource_group_name   = data.azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}
