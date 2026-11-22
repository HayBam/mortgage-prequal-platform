# -----------------------------------------------------------------------------
# versions.tf - which Terraform and provider versions this code is allowed to use,
# and where the state file lives.
#
# Why pin versions? A bank needs repeatable builds. If a provider releases a
# breaking change, our pipeline must not pick it up silently. The exact versions
# that were tested are recorded in .terraform.lock.hcl (committed to Git), and
# upgrades happen on purpose through a pull request.
# -----------------------------------------------------------------------------

terraform {
  # Any 1.x release from 1.9 onward. The pipeline pins the exact CLI version.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    # azurerm creates every Azure resource. "~> 4.81" means 4.81 or newer, but below 5.0.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    # random generates the short suffix that makes globally unique names
    # (ACR and Key Vault names must be unique across all of Azure).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    # time gives us a short wait so a new role assignment can spread through
    # Azure before AKS checks for it (Azure RBAC is eventually consistent).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # Remote state in Azure Blob Storage.
  # - State is shared, so the pipeline and your laptop see the same truth.
  # - Blob leases give state locking: two applies cannot run at the same time.
  # - use_azuread_auth = true: Terraform signs in to storage with Entra ID
  #   (OIDC in the pipeline, Azure CLI on your laptop). No storage account keys.
  # The storage account name and resource group are passed in at init time
  # (-backend-config), so nothing environment-specific is hard-coded here.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
