# -----------------------------------------------------------------------------
# workload-identity.tf - lets the app read ONE thing: secrets in our Key Vault.
#
# How Workload Identity works (no passwords anywhere):
#   1. The pod runs as Kubernetes service account
#      mortgage-prequal/mortgage-prequal.
#   2. AKS signs a token for that service account (the cluster is an OIDC issuer).
#   3. The federated credential below tells Entra ID: "trust tokens from THIS
#      cluster for THIS service account, and swap them for an Azure token for
#      this managed identity".
#   4. The Key Vault CSI driver does that swap and reads the secret.
# A token from any other namespace or service account is rejected.
# -----------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.name}-app"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "app" {
  name                = "fic-mortgage-prequal"
  resource_group_name = data.azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.app.id
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:mortgage-prequal:mortgage-prequal"
  audience            = ["api://AzureADTokenExchange"]
}

# Read-only access to secret VALUES in this vault, and nothing else: it cannot
# list keys, change secrets or manage the vault.
resource "azurerm_role_assignment" "app_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}
