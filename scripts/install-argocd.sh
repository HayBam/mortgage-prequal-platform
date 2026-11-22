#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install-argocd.sh - the ONE-TIME manual bootstrap of GitOps. After this,
# nothing in the cluster is changed by hand.
#   1. Connect kubectl to AKS with your Entra ID login
#   2. Create the Grafana admin secret (random password, never in Git)
#   3. Install Argo CD with Helm (pinned chart version)
#   4. Apply the root "app of apps", from which Argo CD installs everything else
#
# Usage: ./scripts/install-argocd.sh
# -----------------------------------------------------------------------------
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

RG="rg-prequal-demo"
AKS="aks-prequal-demo"
ARGOCD_CHART_VERSION="10.11.6" # Argo CD v3.5.6

for tool in az kubectl kubelogin helm openssl; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool. Install kubelogin with: winget install --id Microsoft.Azure.Kubelogin -e (then reopen Git Bash)"; exit 1; }
done

if grep -q "REPLACE_GITHUB_OWNER" argocd/root-app.yaml; then
  echo "Run scripts/set-manifest-values.sh first (and merge that PR)."; exit 1
fi

echo "[1/4] Getting AKS credentials (Entra ID login via kubelogin)"
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes -o wide

echo "[2/4] Grafana admin secret (random password)"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
fi

echo "[3/4] Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --values argocd/values.yaml \
  --wait --timeout 10m

echo "[4/4] Applying the root application (app of apps)"
kubectl apply -f argocd/root-app.yaml

cat <<'EOF'

Argo CD is installed and is now syncing from Git.
  Argo CD UI : kubectl -n argocd port-forward svc/argocd-server 8080:443   -> https://localhost:8080
  Username   : admin
  Password   : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  Grafana    : kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 -> http://localhost:3000
  Grafana pw : kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
EOF
