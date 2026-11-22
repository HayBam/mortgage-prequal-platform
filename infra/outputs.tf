# -----------------------------------------------------------------------------
# outputs.tf - values printed after apply, which the next steps need.
# None of these are secrets: they are names and IDs. The pipeline shows them in
# the run summary, and scripts/set-manifest-values.sh looks them up for the
# Kubernetes manifests.
# -----------------------------------------------------------------------------

output "resource_group_name" {
  value = data.azurerm_resource_group.this.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "aks_kubernetes_version" {
  value = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "acr_name" {
  description = "Set this as the ACR_NAME variable in GitHub."
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "app_identity_client_id" {
  description = "Goes into the Kubernetes service account annotation and the SecretProviderClass."
  value       = azurerm_user_assigned_identity.app.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.this.name
}
