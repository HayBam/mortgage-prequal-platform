#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# bootstrap-azure.sh - one-time setup that must exist BEFORE Terraform can run.
#
# Chicken-and-egg: Terraform needs somewhere to store state and an identity to
# run as. Those cannot be created by the same Terraform run, so this script
# creates them:
#   1. Registers the Azure resource providers we use
#   2. Terraform state storage (versioned, Entra ID-only, no public access)
#   3. The application resource group (Terraform builds INSIDE it)
#   4. An Entra ID app registration for GitHub Actions
#   5. Federated credentials: trust GitHub OIDC tokens from THIS repo only
#   6. Least-privilege role assignments for that identity
#   7. Turns on Microsoft Defender for Containers
#
# Run it from Git Bash or Azure Cloud Shell, after `az login`:
#   ./scripts/bootstrap-azure.sh <github-owner> [repo-name]
# It is safe to run again: existing items are reused.
# -----------------------------------------------------------------------------
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: do not rewrite /subscriptions/... into C:/...

GITHUB_OWNER="${1:?usage: $0 <github-owner> [repo-name]}"
GITHUB_REPO="${2:-mortgage-prequal-platform}"
LOCATION="${LOCATION:-canadacentral}" # Canadian region: data residency for a Canadian bank
APP_RG="rg-prequal-demo"
STATE_RG="rg-prequal-tfstate"
APP_REG_NAME="github-${GITHUB_REPO}"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ADMIN_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Deterministic, globally unique-ish storage account name (3-24 lowercase letters/digits).
SA_NAME="stprequaltf$(echo -n "$SUBSCRIPTION_ID" | md5sum | cut -c1-8)"

echo "Subscription: $SUBSCRIPTION_ID"
echo "GitHub repo:  $GITHUB_OWNER/$GITHUB_REPO"
echo "IMPORTANT: owner and repo must match GitHub EXACTLY, including capital letters,"
echo "           or GitHub sign-in to Azure fails (AADSTS700213/AADSTS70021). Press Ctrl+C now if not."
sleep 5
echo

echo "[1/7] Registering resource providers (first time can take a few minutes)..."
for p in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.KeyVault \
         Microsoft.OperationalInsights Microsoft.OperationsManagement Microsoft.Insights \
         Microsoft.Network Microsoft.Compute Microsoft.ManagedIdentity Microsoft.Storage \
         Microsoft.Security; do
  az provider register --namespace "$p" --wait --output none
done

echo "[2/7] Terraform state storage: $STATE_RG / $SA_NAME"
az group create --name "$STATE_RG" --location "$LOCATION" \
  --tags project=mortgage-prequal purpose=terraform-state --output none
az storage account create --name "$SA_NAME" --resource-group "$STATE_RG" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --https-only true \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --tags project=mortgage-prequal purpose=terraform-state --output none
# Versioning + soft delete: every state change is kept, and a deleted or
# corrupted state file can be restored. Important for audit and recovery.
az storage account blob-service-properties update --account-name "$SA_NAME" --resource-group "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 --output none
# container-rm uses the management plane, so it works with shared keys disabled.
az storage container-rm create --storage-account "$SA_NAME" --resource-group "$STATE_RG" \
  --name tfstate --output none
SA_ID=$(az storage account show --name "$SA_NAME" --resource-group "$STATE_RG" --query id -o tsv)

echo "[3/7] Application resource group: $APP_RG"
az group create --name "$APP_RG" --location "$LOCATION" \
  --tags project=mortgage-prequal environment=demo managed_by=terraform --output none
APP_RG_ID=$(az group show --name "$APP_RG" --query id -o tsv)

echo "[4/7] Entra ID app registration for GitHub Actions: $APP_REG_NAME"
APP_ID=$(az ad app list --display-name "$APP_REG_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_REG_NAME" --query appId -o tsv)
fi
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
if [ -z "$SP_OBJECT_ID" ]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
fi

echo "[5/7] Federated credentials (which GitHub workflows may sign in)"
add_federated_credential() {
  local name="$1" subject="$2"
  if [ -z "$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name'].name" -o tsv)" ]; then
    az ad app federated-credential create --id "$APP_ID" --output none --parameters \
      "{\"name\":\"$name\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$subject\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
  fi
  echo "   $name -> $subject"
}
add_federated_credential "github-main"           "repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/main"
add_federated_credential "github-pull-request"   "repo:${GITHUB_OWNER}/${GITHUB_REPO}:pull_request"
add_federated_credential "github-env-production" "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:production"

echo "[6/7] Role assignments (least privilege: one resource group, not the subscription)"
assign() { # role, scope, principal, type
  az role assignment create --role "$1" --scope "$2" \
    --assignee-object-id "$3" --assignee-principal-type "$4" --output none
  echo "   $1 -> $(basename "$2") ($4)"
}
assign "Contributor"                               "$APP_RG_ID" "$SP_OBJECT_ID" ServicePrincipal
assign "Role Based Access Control Administrator"   "$APP_RG_ID" "$SP_OBJECT_ID" ServicePrincipal
assign "Storage Blob Data Contributor"             "$SA_ID"     "$SP_OBJECT_ID" ServicePrincipal
assign "Storage Blob Data Contributor"             "$SA_ID"     "$ADMIN_OBJECT_ID" User

echo "[7/7] Microsoft Defender for Containers (subscription plan)"
az security pricing create --name Containers --tier standard --output none

cat <<EOF

=============================================================================
Bootstrap complete. Add these in GitHub:
  Repo > Settings > Secrets and variables > Actions

  SECRETS tab (New repository secret):
    AZURE_CLIENT_ID        $APP_ID
    AZURE_TENANT_ID        $TENANT_ID
    AZURE_SUBSCRIPTION_ID  $SUBSCRIPTION_ID
    ADMIN_OBJECT_ID        $ADMIN_OBJECT_ID

  VARIABLES tab (New repository variable):
    TFSTATE_RESOURCE_GROUP   $STATE_RG
    TFSTATE_STORAGE_ACCOUNT  $SA_NAME
    (ACR_NAME is added later, after the first terraform apply)
=============================================================================
EOF
