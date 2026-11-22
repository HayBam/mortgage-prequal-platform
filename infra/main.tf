# -----------------------------------------------------------------------------
# main.tf - shared lookups, naming and tags used by every other file.
#
# Terraform reads every .tf file in this folder as one configuration. Splitting
# into files is only for people: network.tf, aks.tf and so on are easier to
# review than one big file.
# -----------------------------------------------------------------------------

# "data" blocks READ something that already exists; they never create it.
# The resource group is created in the bootstrap (Phase 2), not by Terraform, so
# the pipeline identity can be limited to this one resource group.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# Who is Terraform running as? Gives us the tenant ID for AKS and Key Vault.
data "azurerm_client_config" "current" {}

# A random 5-character suffix. Some Azure names (ACR, Key Vault) must be unique
# worldwide; the suffix avoids clashes. It is generated once and then stored in
# state, so names stay the same on every later run.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# "locals" are named values computed inside the configuration, like constants.
locals {
  name     = "${var.project}-${var.environment}" # e.g. prequal-demo
  location = data.azurerm_resource_group.this.location
  suffix   = random_string.suffix.result

  # Tags on every resource. In a bank, tags drive cost reports, ownership and
  # data-classification controls (Azure Policy can deny untagged resources).
  tags = {
    project             = "mortgage-prequal"
    environment         = var.environment
    owner               = var.owner
    managed_by          = "terraform"
    data_classification = "confidential"
  }
}
