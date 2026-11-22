# -----------------------------------------------------------------------------
# providers.tf - how Terraform connects to Azure.
#
# There are no credentials in this file. Terraform reads them from environment
# variables:
#   In GitHub Actions: ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID and
#                      ARM_USE_OIDC=true. GitHub issues a short-lived OIDC token,
#                      and Entra ID swaps it for an Azure token. No secret is stored.
#   On your laptop:    `az login`, then export ARM_SUBSCRIPTION_ID.
# -----------------------------------------------------------------------------

provider "azurerm" {
  features {
    key_vault {
      # Purge protection is on, so Terraform cannot purge the vault on destroy.
      # It is soft-deleted and kept for the retention period instead.
      purge_soft_delete_on_destroy = false
    }
  }

  # The pipeline identity only has rights on ONE resource group (least privilege).
  # By default azurerm tries to register resource providers across the whole
  # subscription, which would fail with those limited rights. The bootstrap
  # script registers the providers once, so we turn that behaviour off here.
  resource_provider_registrations = "none"

  # Use Entra ID (not storage keys) for any storage data-plane calls.
  storage_use_azuread = true
}
