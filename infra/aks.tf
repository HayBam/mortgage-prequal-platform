# -----------------------------------------------------------------------------
# aks.tf - the Azure Kubernetes Service cluster.
#
# Security posture, in one breath:
#   - Entra ID sign-in only; local admin accounts disabled; Azure RBAC decides
#     what each person can do inside Kubernetes.
#   - Public API server endpoint, but every call must carry an Entra ID token
#     AND an Azure RBAC role. No IP allowlist, so you can work from any network.
#   - Workload identity: pods get Azure access through federated tokens, with
#     no secrets stored in the cluster.
#   - Key Vault CSI driver: secrets are mounted from Key Vault, not stored in Git
#     or as Kubernetes Secrets.
#   - Cilium network policy: default-deny rules in the app namespace.
#   - Defender for Containers sensor plus Container Insights, both to Log Analytics.
#   - Automatic patch upgrades for Kubernetes and the node OS.
# -----------------------------------------------------------------------------

# --- Control-plane identity ---------------------------------------------------
# A user-assigned identity we create first, so we can grant it Network
# Contributor on the AKS subnet BEFORE the cluster exists. AKS needs that role
# to place nodes and load balancers in a subnet it does not own. (With a
# system-assigned identity, the identity only exists after the cluster is
# created, which is too late.)
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${local.name}-aks"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_subnet.aks.id # least privilege: the subnet only, not the whole VNet
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
  principal_type       = "ServicePrincipal"
}

# Azure RBAC is eventually consistent: a new role assignment can take a minute
# to be visible everywhere. Wait 60 seconds so AKS's permission check passes on
# the first try.
resource "time_sleep" "wait_for_aks_network_role" {
  depends_on      = [azurerm_role_assignment.aks_network]
  create_duration = "60s"
}

# --- The cluster -----------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.this.name
  dns_prefix          = "aks-${local.name}"
  kubernetes_version  = var.kubernetes_version

  # Free tier: no uptime SLA on the control plane. Production would use
  # "Standard" (financially backed 99.95% SLA with availability zones).
  sku_tier = "Free"

  # Patching: "patch" applies new Kubernetes patch releases automatically
  # (e.g. 1.33.1 -> 1.33.2); minor upgrades stay a deliberate change.
  # "NodeImage" keeps node OS security patches current with weekly images.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Change window: automatic upgrades may only start Saturday 01:00-05:00
  # Toronto time (EST, UTC-5). Without a window AKS can upgrade at any time,
  # including during business hours. In a bank this is the approved
  # maintenance window from change management. AKS needs at least 4 hours.
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Saturday"
    start_time  = "01:00"
    duration    = 4
    utc_offset  = "-05:00"
  }
  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Saturday"
    start_time  = "01:00"
    duration    = 4
    utc_offset  = "-05:00"
  }

  # --- Identity and access ---
  # Only Entra ID identities can sign in. No shared admin kubeconfig exists
  # that could leak.
  local_account_disabled            = true
  role_based_access_control_enabled = true

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true # Kubernetes permissions are granted as Azure role assignments
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # OIDC issuer + workload identity: AKS publishes a token issuer, so Entra ID
  # can trust tokens for a specific Kubernetes service account (see
  # workload-identity.tf).
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # API server network access: deliberately NOT IP-restricted, so the demo
  # works from any network (home, office, interview room) without changing
  # Terraform. Access is still identity-gated: local accounts are off, so every
  # request needs an Entra ID token plus an Azure RBAC role on this cluster.
  # Production would add one of: authorized_ip_ranges (corporate egress IPs),
  # a private cluster reached over VPN/ExpressRoute, or API Server VNet
  # Integration.

  # --- Nodes ---
  # One "system" pool runs everything to keep cost down. Production would add a
  # separate "user" pool for applications, with autoscaling and zones.
  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    node_count                  = var.node_count
    vnet_subnet_id              = azurerm_subnet.aks.id
    zones                       = length(var.availability_zones) > 0 ? var.availability_zones : null
    max_pods                    = 110
    os_disk_size_gb             = 64
    temporary_name_for_rotation = "systemtmp" # lets Terraform replace the pool safely if a setting requires it
    tags                        = local.tags

    upgrade_settings {
      max_surge = "10%" # during upgrades, add one extra node at a time
    }
  }

  # --- Networking ---
  # Azure CNI Overlay with the Cilium dataplane (eBPF):
  #   nodes   -> IPs from snet-aks (10.10.0.0/22)
  #   pods    -> IPs from pod_cidr (10.244.0.0/16), not routable outside the cluster
  #   services-> IPs from service_cidr (10.20.0.0/16)
  # Cilium enforces Kubernetes NetworkPolicy (our default-deny rules).
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.20.0.0/16"
    dns_service_ip      = "10.20.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  # --- Add-ons ---
  # Container Insights: the Azure Monitor Agent on every node, signing in with
  # managed identity. The Data Collection Rule in monitoring.tf tells it what
  # to collect.
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Secrets Store CSI driver with the Azure Key Vault provider. Rotation is on:
  # if the secret changes in Key Vault, the mounted file updates within 2 minutes.
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Defender for Containers sensor: runtime threat detection on the nodes.
  # "dynamic" adds the block only when enable_defender is true.
  dynamic "microsoft_defender" {
    for_each = var.enable_defender ? [1] : []
    content {
      log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
    }
  }

  tags = local.tags

  depends_on = [time_sleep.wait_for_aks_network_role]

  #checkov:skip=CKV_AZURE_115:Private cluster needs a VPN or jump box to reach the API. The demo uses a public API gated by Entra ID + Azure RBAC (local accounts disabled).
  #checkov:skip=CKV_AZURE_117:Customer-managed disk encryption keys are out of scope; disks use platform-managed encryption at rest.
  #checkov:skip=CKV_AZURE_170:Paid SLA tier (Standard) is not needed for a demo. Production would use Standard.
  #checkov:skip=CKV_AZURE_226:Ephemeral OS disks need a VM size with a local cache disk; D2s_v4 has none.
  #checkov:skip=CKV_AZURE_227:Encryption at host needs a subscription feature registration. Production would enable it.
  #checkov:skip=CKV_AZURE_232:A single node pool runs system and app pods to keep cost down. Production would split them.
  #checkov:skip=CKV_AZURE_6:No IP allowlist so the demo works from any network. Every API call still needs Entra ID + Azure RBAC (local accounts disabled). Production would set authorized IP ranges or use a private cluster.
  #checkov:skip=CKV_AZURE_116:Azure Policy add-on is a planned next step; pod security is enforced with Kubernetes Pod Security Admission (restricted) instead.
}

# --- Give YOU admin rights inside Kubernetes -------------------------------------
# "Azure Kubernetes Service RBAC Cluster Admin" = full Kubernetes admin, granted
# through Azure RBAC. Being Owner of the subscription does NOT give
# Kubernetes data-plane rights on its own.
resource "azurerm_role_assignment" "admin_aks_rbac" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.admin_object_id
  principal_type       = "User"
}
