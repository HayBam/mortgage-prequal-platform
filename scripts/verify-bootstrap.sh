#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# verify-bootstrap.sh - READ-ONLY check of the Phase 2 bootstrap, whether you
# did it by hand in the Azure portal or with bootstrap-azure.sh.
# It changes nothing in Azure. For every item it prints PASS, or FAIL with the
# fix. At the end it prints the values to paste into GitHub (Phase 3).
#
# Usage: ./scripts/verify-bootstrap.sh <github-owner> [repo-name]
# Run it as often as you like; fix the FAIL lines and run it again.
# -----------------------------------------------------------------------------
set -uo pipefail          # no -e: keep checking after a failure
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: do not rewrite /subscriptions/... into C:/...

GITHUB_OWNER="${1:?usage: $0 <github-owner> [repo-name]}"
GITHUB_REPO="${2:-mortgage-prequal-platform}"
APP_RG="rg-prequal-demo"
STATE_RG="rg-prequal-tfstate"
APP_REG_NAME="github-${GITHUB_REPO}"
PROVIDERS="Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.KeyVault
  Microsoft.OperationalInsights Microsoft.OperationsManagement Microsoft.Insights
  Microsoft.Network Microsoft.Compute Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Security"

FAILS=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n        fix: %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
# check <what> <expected> <actual> <fix>
check() {
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (expected '$2', found '${3:-nothing}')" "$4"; fi
}
q()  { az "$@" 2>/dev/null | tr -d '\r'; }                       # quiet az, Windows line endings removed
ql() { q "$@" | tr '[:upper:]' '[:lower:]'; }                    # same, lower-cased (True/true)
has_role() { # <principal object id> <role> <scope>: prints yes/no (exact scope, case-insensitive)
  q role assignment list --assignee "$1" --role "$2" --scope "$3" --query "[].scope" -o tsv \
    | grep -qixF "$3" && echo yes || echo no
}

SUBSCRIPTION_NAME=$(q account show --query name -o tsv)
[ -n "$SUBSCRIPTION_NAME" ] || { echo "Not signed in to Azure. Run: az login"; exit 1; }
SUBSCRIPTION_ID=$(q account show --query id -o tsv)
TENANT_ID=$(q account show --query tenantId -o tsv)
ADMIN_OBJECT_ID=$(q ad signed-in-user show --query id -o tsv)
echo "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "GitHub repo:  $GITHUB_OWNER/$GITHUB_REPO   (must match GitHub exactly, including capitals)"

echo; echo "[1/7] Resource providers"
for p in $PROVIDERS; do
  check "$p" "Registered" "$(q provider show --namespace "$p" --query registrationState -o tsv)" \
    "Subscriptions > $SUBSCRIPTION_NAME > Resource providers > $p > Register. 'Registering' just needs a few minutes."
done

echo; echo "[2/7] Terraform state storage"
check "Resource group $STATE_RG exists" "true" "$(q group exists --name "$STATE_RG")" \
  "Resource groups > + Create > $STATE_RG, region Canada Central"
SA_NAME=$(q storage account list --resource-group "$STATE_RG" --query "[].name" -o tsv)
SA_COUNT=$(printf '%s' "$SA_NAME" | grep -c . || true)
SA_ID=""
if [ "$SA_COUNT" != "1" ]; then
  fail "Exactly one storage account in $STATE_RG (found $SA_COUNT)" "Create one (Phase 2 step 2b), or delete the extra one"
  SA_NAME=""
else
  pass "Storage account $SA_NAME"
  SA_ID=$(q storage account show --name "$SA_NAME" --resource-group "$STATE_RG" --query id -o tsv)
  mapfile -t V < <(ql storage account show --name "$SA_NAME" --resource-group "$STATE_RG" --query \
    "[minimumTlsVersion, enableHttpsTrafficOnly, allowBlobPublicAccess, allowSharedKeyAccess, isHnsEnabled]" -o tsv)
  FIX="Storage account > Settings > Configuration, then Save"
  check "Minimum TLS version 1.2"             "tls1_2" "${V[0]:-}" "$FIX: Minimum TLS version = Version 1.2"
  check "Secure transfer required"            "true"   "${V[1]:-}" "$FIX: Secure transfer required = Enabled"
  check "Anonymous blob access off"           "false"  "${V[2]:-}" "$FIX: Allow Blob anonymous access = Disabled"
  check "Storage account key access off"      "false"  "${V[3]:-}" "$FIX: Allow storage account key access = Disabled"
  check "Hierarchical namespace off"          "false"  "${V[4]:-false}" "Cannot be changed: delete the account and create it again with hierarchical namespace unticked"
  mapfile -t B < <(ql storage account blob-service-properties show --account-name "$SA_NAME" --resource-group "$STATE_RG" --query \
    "[isVersioningEnabled, deleteRetentionPolicy.enabled, deleteRetentionPolicy.days, containerDeleteRetentionPolicy.enabled, containerDeleteRetentionPolicy.days]" -o tsv)
  FIX="Storage account > Data management > Data protection, then Save"
  check "Blob versioning on"                  "true"   "${B[0]:-}" "$FIX: Enable versioning for blobs"
  check "Blob soft delete on"                 "true"   "${B[1]:-}" "$FIX: Enable soft delete for blobs"
  check "Blob soft delete 30 days"            "30"     "${B[2]:-}" "$FIX: Keep deleted blobs for 30 days"
  check "Container soft delete on"            "true"   "${B[3]:-}" "$FIX: Enable soft delete for containers"
  check "Container soft delete 30 days"       "30"     "${B[4]:-}" "$FIX: Keep deleted containers for 30 days"
  check "Container tfstate exists"            "tfstate" \
    "$(q storage container-rm show --storage-account "$SA_NAME" --resource-group "$STATE_RG" --name tfstate --query name -o tsv)" \
    "Storage account > Data storage > Containers > + Container > name tfstate, Private"
fi

echo; echo "[3/7] Application resource group"
check "Resource group $APP_RG exists" "true" "$(q group exists --name "$APP_RG")" \
  "Resource groups > + Create > $APP_RG, region Canada Central"
APP_RG_ID=$(q group show --name "$APP_RG" --query id -o tsv)

echo; echo "[4/7] App registration for GitHub Actions"
APP_ID=$(q ad app list --display-name "$APP_REG_NAME" --query "[].appId" -o tsv)
APP_COUNT=$(printf '%s' "$APP_ID" | grep -c . || true)
SP_OBJECT_ID=""
if [ "$APP_COUNT" != "1" ]; then
  fail "Exactly one app registration named $APP_REG_NAME (found $APP_COUNT)" \
    "Microsoft Entra ID > App registrations > + New registration (or delete the duplicate)"
  APP_ID=""
else
  pass "App registration $APP_REG_NAME (client ID $APP_ID)"
  check "No client secrets (password-less)" "0" "$(q ad app show --id "$APP_ID" --query "length(passwordCredentials)" -o tsv)" \
    "App registration > Certificates & secrets > Client secrets: delete them. OIDC needs none."
  SP_OBJECT_ID=$(q ad sp show --id "$APP_ID" --query id -o tsv)
  if [ -n "$SP_OBJECT_ID" ]; then pass "Service principal (enterprise application) exists"
  else fail "Service principal (enterprise application) exists" "Run: az ad sp create --id $APP_ID"; fi
fi

echo; echo "[5/7] Federated credentials"
if [ -n "$APP_ID" ]; then
  FED=$(q ad app federated-credential list --id "$APP_ID" --query "[].[subject, issuer, join(',', audiences)]" -o tsv)
  for subject in "repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/main" \
                 "repo:${GITHUB_OWNER}/${GITHUB_REPO}:pull_request" \
                 "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:production"; do
    line=$(printf '%s\n' "$FED" | awk -F'\t' -v s="$subject" '$1 == s')  # exact, case-sensitive
    if [ -z "$line" ]; then
      fail "Subject $subject" "Certificates & secrets > Federated credentials > + Add credential (GitHub Actions scenario). Spelling and capitals must match exactly."
    elif [ "$(printf '%s' "$line" | cut -f2)" != "https://token.actions.githubusercontent.com" ] \
      || [ "$(printf '%s' "$line" | cut -f3)" != "api://AzureADTokenExchange" ]; then
      fail "Subject $subject (wrong issuer or audience)" "Edit it: issuer https://token.actions.githubusercontent.com, audience api://AzureADTokenExchange"
    else
      pass "$subject"
    fi
  done
else
  fail "Federated credentials" "Create the app registration first"
fi

echo; echo "[6/7] Role assignments (least privilege)"
if [ -n "$SP_OBJECT_ID" ] && [ -n "$APP_RG_ID" ]; then
  check "Pipeline: Contributor on $APP_RG" "yes" "$(has_role "$SP_OBJECT_ID" "Contributor" "$APP_RG_ID")" \
    "$APP_RG > Access control (IAM) > Add role assignment > Contributor > $APP_REG_NAME"
  check "Pipeline: Role Based Access Control Administrator on $APP_RG" "yes" \
    "$(has_role "$SP_OBJECT_ID" "Role Based Access Control Administrator" "$APP_RG_ID")" \
    "$APP_RG > Access control (IAM) > Add role assignment > Role Based Access Control Administrator > $APP_REG_NAME"
  SUB_ROLES=$(q role assignment list --assignee "$SP_OBJECT_ID" --scope "/subscriptions/$SUBSCRIPTION_ID" \
    --query "[?scope=='/subscriptions/$SUBSCRIPTION_ID'].roleDefinitionName" -o tsv)
  check "Pipeline: nothing at subscription level" "" "$SUB_ROLES" \
    "Subscriptions > $SUBSCRIPTION_NAME > Access control (IAM) > Role assignments: remove $APP_REG_NAME"
else
  fail "Pipeline roles on $APP_RG" "Create the resource group and the app registration first"
fi
if [ -n "$SP_OBJECT_ID" ] && [ -n "$SA_ID" ]; then
  check "Pipeline: Storage Blob Data Contributor on $SA_NAME" "yes" \
    "$(has_role "$SP_OBJECT_ID" "Storage Blob Data Contributor" "$SA_ID")" \
    "$SA_NAME > Access control (IAM) > Add role assignment > Storage Blob Data Contributor > $APP_REG_NAME"
fi
if [ -n "$SA_ID" ]; then
  check "You: Storage Blob Data Contributor on $SA_NAME" "yes" \
    "$(has_role "$ADMIN_OBJECT_ID" "Storage Blob Data Contributor" "$SA_ID")" \
    "$SA_NAME > Access control (IAM) > Add role assignment > Storage Blob Data Contributor > your own user"
fi

echo; echo "[7/7] Microsoft Defender for Containers"
check "Containers plan on" "standard" "$(ql security pricing show --name Containers --query pricingTier -o tsv)" \
  "Microsoft Defender for Cloud > Environment settings > $SUBSCRIPTION_NAME > Defender plans > Containers = On > Save"

cat <<EOF

=============================================================================
Values for GitHub: Repo > Settings > Secrets and variables > Actions

  SECRETS tab (New repository secret):
    AZURE_CLIENT_ID        ${APP_ID:-<missing>}
    AZURE_TENANT_ID        $TENANT_ID
    AZURE_SUBSCRIPTION_ID  $SUBSCRIPTION_ID
    ADMIN_OBJECT_ID        $ADMIN_OBJECT_ID

  VARIABLES tab (New repository variable):
    TFSTATE_RESOURCE_GROUP   $STATE_RG
    TFSTATE_STORAGE_ACCOUNT  ${SA_NAME:-<missing>}
    (ACR_NAME is added later, after the first terraform apply)
=============================================================================
EOF

if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Continue with Phase 3."
else
  echo "$FAILS check(s) failed. Fix them (see 'fix:' lines) and run this again."
  exit 1
fi
