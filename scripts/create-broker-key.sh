#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# create-broker-key.sh - creates (or rotates) the broker API key in Key Vault.
# The value is generated here and goes straight into Key Vault. It is never
# written to Git, Terraform state or a Kubernetes Secret.
# The secret expires in 90 days, which forces regular rotation.
#
# Usage: ./scripts/create-broker-key.sh
# Run it again at any time to rotate: the pods pick up the new value within
# about 2 minutes (CSI driver rotation), with no restart.
# -----------------------------------------------------------------------------
set -euo pipefail
export MSYS_NO_PATHCONV=1

RG="rg-prequal-demo"
KV_NAME=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv)
KEY=$(openssl rand -hex 24)
EXPIRES=$(date -u -d "+90 days" +%Y-%m-%dT%H:%M:%SZ)

# Your "Key Vault Secrets Officer" role can take a few minutes to become active
# after terraform apply, so retry a few times.
for attempt in 1 2 3 4 5; do
  if az keyvault secret set --vault-name "$KV_NAME" --name broker-api-key \
       --value "$KEY" --expires "$EXPIRES" --content-type "broker-api-key" --output none 2>/dev/null; then
    echo "Stored broker-api-key in $KV_NAME (expires $EXPIRES)."
    echo "Broker API key for your demo calls (keep it private): $KEY"
    exit 0
  fi
  echo "Attempt $attempt failed (your Key Vault role may still be spreading). Retrying in 30s..."
  sleep 30
done
echo "Could not write the secret. Check: 'az account show' is the right subscription, and you have Key Vault Secrets Officer on the vault."
exit 1
