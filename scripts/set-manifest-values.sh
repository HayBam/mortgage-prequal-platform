#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# set-manifest-values.sh - fills the REPLACE_* placeholders in the Kubernetes
# and Argo CD manifests with real values from Azure. Run once after the first
# terraform apply, then commit the changes through a pull request.
#
# The values are IDs and names, not secrets:
#   - GitHub owner          -> Argo CD repo URLs
#   - ACR name              -> image location in kustomization.yaml
#   - Key Vault name        -> SecretProviderClass
#   - App identity clientId -> ServiceAccount + SecretProviderClass
#   - Tenant ID             -> SecretProviderClass
#
# Usage: ./scripts/set-manifest-values.sh <github-owner>
# -----------------------------------------------------------------------------
set -euo pipefail
export MSYS_NO_PATHCONV=1

GITHUB_OWNER="${1:?usage: $0 <github-owner>}"
RG="rg-prequal-demo"
cd "$(dirname "$0")/.."

ACR_NAME=$(az acr list --resource-group "$RG" --query "[0].name" -o tsv)
KV_NAME=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv)
CLIENT_ID=$(az identity show --resource-group "$RG" --name id-prequal-demo-app --query clientId -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

for v in ACR_NAME KV_NAME CLIENT_ID TENANT_ID; do
  if [ -z "${!v}" ]; then echo "Could not find $v in $RG. Has terraform apply finished?"; exit 1; fi
  echo "$v = ${!v}"
done

sed -i \
  -e "s/REPLACE_GITHUB_OWNER/${GITHUB_OWNER}/g" \
  argocd/root-app.yaml argocd/apps/projects.yaml argocd/apps/mortgage-prequal.yaml
sed -i -e "s/REPLACE_ACR_NAME/${ACR_NAME}/g" deploy/mortgage-prequal/kustomization.yaml
sed -i \
  -e "s/REPLACE_APP_IDENTITY_CLIENT_ID/${CLIENT_ID}/g" \
  -e "s/REPLACE_KEY_VAULT_NAME/${KV_NAME}/g" \
  -e "s/REPLACE_TENANT_ID/${TENANT_ID}/g" \
  deploy/mortgage-prequal/serviceaccount.yaml deploy/mortgage-prequal/secretproviderclass.yaml

if grep -rn "REPLACE_" argocd deploy; then
  echo "Some placeholders are still present (listed above)."; exit 1
fi
echo
echo "All placeholders filled. Now: git switch -c config/manifest-values && git add -A && git commit -m 'Set Azure values in manifests' && git push -u origin config/manifest-values"
echo "Also set the GitHub repository variable ACR_NAME = ${ACR_NAME}"
