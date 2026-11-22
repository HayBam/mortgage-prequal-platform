# -----------------------------------------------------------------------------
# acr.tf - Azure Container Registry: the private store for our app images.
#
# Flow: GitHub Actions builds and scans the image, then pushes it here.
#       AKS pulls it from here, signing in with the kubelet managed identity.
# -----------------------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  # Only letters and digits are allowed, and the name must be unique worldwide,
  # e.g. acrprequaldemo4k2xq.
  name                = "acr${var.project}${var.environment}${local.suffix}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name

  # Basic is the cheapest tier. Premium adds private endpoints, geo-replication,
  # retention policies and content trust. Those are skipped below with reasons
  # (see the checkov:skip lines).
  sku = "Basic"

  # No shared admin username and password. Every push and pull uses an Entra ID
  # identity, so every access is traceable to a named identity.
  admin_enabled = false

  tags = local.tags

  #checkov:skip=CKV_AZURE_139:Public network access is needed on Basic SKU (Premium required for private endpoints). Access is still Entra ID only.
  #checkov:skip=CKV_AZURE_163:Image vulnerability scanning is done by Trivy in the pipeline and by Defender for Containers.
  #checkov:skip=CKV_AZURE_164:Content trust (signed images) requires Premium SKU. Images are pinned by digest instead.
  #checkov:skip=CKV_AZURE_165:Geo-replication requires Premium SKU. Not needed for a single-region demo.
  #checkov:skip=CKV_AZURE_166:Quarantine requires Premium SKU. The pipeline scan gate blocks vulnerable images before push.
  #checkov:skip=CKV_AZURE_167:Untagged-manifest retention requires Premium SKU.
  #checkov:skip=CKV_AZURE_233:Zone redundancy requires Premium SKU.
  #checkov:skip=CKV_AZURE_237:Dedicated data endpoints require Premium SKU.
}

# Let the AKS nodes pull images. The kubelet identity is created by AKS itself
# (in the MC_ node resource group). AcrPull is read-only: nodes cannot push.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
