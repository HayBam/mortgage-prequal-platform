# -----------------------------------------------------------------------------
# variables.tf - the inputs to this configuration.
#
# Values come from (highest priority first):
#   1. TF_VAR_<name> environment variables (the pipeline sets these from
#      GitHub secrets and variables)
#   2. a terraform.tfvars file (only for local runs; it is git-ignored)
#   3. the defaults below
# Validation blocks reject bad input at plan time, before anything is built.
# -----------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Existing resource group created in the bootstrap (Phase 2). Terraform builds everything inside it."
  type        = string
  default     = "rg-prequal-demo"
}

variable "project" {
  description = "Short project name used in resource names."
  type        = string
  default     = "prequal"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.project))
    error_message = "Use 3-10 lowercase letters or digits (it is part of the ACR name, which allows no dashes)."
  }
}

variable "environment" {
  description = "Environment name, used in names and tags."
  type        = string
  default     = "demo"
}

variable "owner" {
  description = "Owner tag value, so anyone in the bank can see who is accountable for these resources."
  type        = string
  default     = "platform-team"
}

variable "admin_object_id" {
  description = "Entra ID object ID of the human administrator (you). Gets cluster-admin and Key Vault secret rights."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f-]{36}$", var.admin_object_id))
    error_message = "admin_object_id must be a GUID. Get it with: az ad signed-in-user show --query id -o tsv"
  }
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. null = the current AKS default; patch versions are then kept current by the auto-upgrade channel."
  type        = string
  default     = null
}

variable "node_vm_size" {
  # New subscriptions often get 0 quota for DSv5 in Canada Central but 10 for
  # DSv4. Check yours: az vm list-usage --location canadacentral -o table
  description = "VM size for the AKS nodes. D2s_v4 = 2 vCPU, 8 GiB RAM (DSv4 family)."
  type        = string
  default     = "Standard_D2s_v4"
}

variable "node_count" {
  description = "Number of AKS nodes. Two lets us spread the app's two replicas across nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 5
    error_message = "node_count must be between 1 and 5 for this demo."
  }
}

variable "availability_zones" {
  description = "Zones for the nodes, e.g. [\"1\",\"2\",\"3\"]. Empty = no zone pinning (avoids zone capacity errors on small subscriptions)."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "How long Log Analytics keeps logs. A real bank keeps audit logs much longer (often years, via archive tiers)."
  type        = number
  default     = 30
}

variable "enable_defender" {
  description = "Deploy the Microsoft Defender for Containers sensor on AKS. Needs the Defender for Containers plan turned on for the subscription (done in the bootstrap, Phase 2)."
  type        = bool
  default     = true
}
