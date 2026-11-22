# -----------------------------------------------------------------------------
# keyvault.tf - Azure Key Vault holds the broker API key.
#
# Who can do what (Azure RBAC, not legacy access policies):
#   You (admin)           Key Vault Secrets Officer: create and rotate the secret
#   App managed identity  Key Vault Secrets User:    read only (workload-identity.tf)
#
# How it is reached:
#   From AKS:    through a PRIVATE ENDPOINT (private IP inside our VNet)
#   From you:    through the public endpoint, from any network. There is no IP
#                firewall; access needs an Entra ID sign-in AND an RBAC role
#   Everyone else: no role, so every request is denied (403)
#
# The secret VALUE is never in Git or in Terraform state: you create it by hand
# with the Azure CLI after the vault exists (see the build guide).
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  name                = "kv-${local.name}-${local.suffix}" # max 24 characters
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Use Azure RBAC role assignments for data access (auditable, consistent with
  # the rest of Azure) instead of vault-specific access policies.
  rbac_authorization_enabled = true

  # Deleted secrets and vaults can be recovered for 7 days. Purge protection
  # means nobody, not even an admin, can permanently delete them early.
  # Protects against accidental or malicious deletion.
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  # Network: the public endpoint is open to any IP, so you can manage the
  # secret from any network without a VPN or firewall update. Identity is the
  # control: RBAC authorization is on, so a caller without a Key Vault role gets
  # 403 even with a valid sign-in. AKS pods never use the public endpoint; they
  # go through the private endpoint below.
  # Production would set default_action = "Deny" with corporate IP rules, or
  # disable public access entirely and administer over the private network.
  public_network_access_enabled = true
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = local.tags

  #checkov:skip=CKV_AZURE_189:Public access is kept so the admin can set the secret from any network without a VPN or jump box. Access is RBAC-gated.
  #checkov:skip=CKV_AZURE_109:No IP firewall so the demo works from any network. Every request needs Entra ID + a Key Vault RBAC role; pods use the private endpoint.
}

# Private endpoint: gives the vault a private IP in snet-private-ep. The DNS
# zone group registers that IP in privatelink.vaultcore.azure.net, so pods
# resolving the vault name get the private IP. Traffic never leaves the VNet.
resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${azurerm_key_vault.this.name}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-key-vault"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}

# You need data-plane rights to create the secret. Owner on the subscription
# does NOT grant this: control plane and data plane permissions are separate.
resource "azurerm_role_assignment" "admin_kv_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.admin_object_id
  principal_type       = "User"
}
