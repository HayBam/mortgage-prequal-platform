#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# teardown-azure.sh - removes what the bootstrap (Phase 2) created, AFTER Terraform
# has destroyed the platform (GitHub > Actions > terraform > Run workflow >
# action = destroy).
#
# Usage: ./scripts/teardown-azure.sh [repo-name]
# -----------------------------------------------------------------------------
set -euo pipefail
export MSYS_NO_PATHCONV=1

GITHUB_REPO="${1:-mortgage-prequal-platform}"
APP_RG="rg-prequal-demo"
STATE_RG="rg-prequal-tfstate"
APP_REG_NAME="github-${GITHUB_REPO}"

echo "This deletes: $APP_RG, $STATE_RG (Terraform state!), app registration $APP_REG_NAME,"
echo "and sets Defender for Containers back to Free."
read -r -p "Type DELETE to continue: " answer
[ "$answer" = "DELETE" ] || { echo "Cancelled."; exit 1; }

# Safety net: if Terraform destroy was skipped or failed, deleting the resource
# group removes everything in it (AKS also deletes its MC_ node resource group).
if [ "$(az group exists --name "$APP_RG")" = "true" ]; then
  echo "Deleting $APP_RG (5-10 minutes)..."
  az group delete --name "$APP_RG" --yes
fi

echo "Deleting $STATE_RG..."
az group delete --name "$STATE_RG" --yes

APP_ID=$(az ad app list --display-name "$APP_REG_NAME" --query "[0].appId" -o tsv)
if [ -n "$APP_ID" ]; then
  echo "Deleting app registration $APP_REG_NAME..."
  az ad app delete --id "$APP_ID"
fi

echo "Setting Defender for Containers back to Free..."
az security pricing create --name Containers --tier free --output none

echo
echo "Done. Notes:"
echo " - The Key Vault is soft-deleted (purge protection) and is removed automatically after 7 days. It costs nothing."
echo " - Check for leftovers: az group list --query \"[?starts_with(name,'rg-prequal') || starts_with(name,'MC_rg-prequal')].name\" -o tsv"
