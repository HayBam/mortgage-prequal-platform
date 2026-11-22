# -----------------------------------------------------------------------------
# monitoring.tf - central logging with Azure Monitor.
#
# Everything sends logs to ONE Log Analytics workspace, so a single KQL query
# can answer an auditor or an incident question:
#   - Container Insights: pod logs, Kubernetes events, node and pod inventory
#   - AKS control-plane audit log: who changed what in the cluster (kubectl,
#     ArgoCD, the pipeline)
#   - Key Vault audit log: every secret read, with the caller's identity
# Prometheus and Grafana (installed by ArgoCD) handle metrics and alerting
# inside the cluster. Azure Monitor handles logs and audit evidence.
# -----------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  sku                 = "PerGB2018" # pay per GB ingested
  retention_in_days   = var.log_retention_days

  # Cost guardrail: ingestion stops for the day after 2 GB. Plenty for a demo;
  # a production workspace would not cap audit logs.
  daily_quota_gb = 2

  tags = local.tags
}

# --- Container Insights ------------------------------------------------------
# The AKS monitoring add-on (oms_agent in aks.tf) runs the Azure Monitor Agent
# on each node. With managed-identity auth, the agent learns WHAT to collect
# from a Data Collection Rule (DCR). The portal creates this for you;
# Terraform must create it explicitly.
resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "dcr-${local.name}-ci"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags

  # Where data goes: our workspace.
  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
      name                  = "ciworkspace"
    }
  }

  # Which data stream flows to which destination.
  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["ciworkspace"]
  }

  # The Container Insights extension, collecting every minute, all namespaces,
  # using the ContainerLogV2 schema (adds pod and container names to log lines).
  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
    }
  }
}

# Attach the rule to the cluster. The name must be "ContainerInsightsExtension".
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
}

# --- AKS control-plane logs ---------------------------------------------------
# kube-audit-admin = the Kubernetes audit log WITHOUT read-only get/list calls.
# It keeps every create, update and delete (the audit-relevant part) at a
# fraction of the volume and cost of the full kube-audit log.
# guard = Entra ID authentication and authorization decisions.
# "Dedicated" sends each category to its own table (AKSAuditAdmin,
# AKSControlPlane), which is cheaper and easier to query than AzureDiagnostics.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-aks-to-log-analytics"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "kube-audit-admin"
  }

  enabled_log {
    category = "guard"
  }
}

# --- Key Vault audit log -------------------------------------------------------
# Every secret get, set and delete is logged with the caller's identity and IP.
# In a bank this answers "who accessed this secret, and when?".
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                           = "diag-kv-to-log-analytics"
  target_resource_id             = azurerm_key_vault.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AuditEvent"
  }
}
