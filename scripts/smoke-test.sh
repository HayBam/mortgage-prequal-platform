#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# smoke-test.sh - quick end-to-end check of the deployed API.
# First, in another terminal:
#   kubectl -n mortgage-prequal port-forward svc/mortgage-prequal 8000:80
# Then: ./scripts/smoke-test.sh <broker-api-key>
# -----------------------------------------------------------------------------
set -euo pipefail
KEY="${1:?usage: $0 <broker-api-key>}"
URL="${URL:-http://localhost:8000}"

echo "--- health and version"
curl -sf "$URL/healthz"; echo
curl -sf "$URL/readyz"; echo
curl -sf "$URL/version"; echo

echo "--- broker portal page (expect HTTP 200 and the CSP header)"
curl -sf -o /dev/null -D - "$URL/" | grep -iE "^HTTP|^content-security-policy" | cut -c1-80

echo "--- strong application (expect approved: true)"
curl -sf -X POST "$URL/v1/prequalify" -H "Content-Type: application/json" -H "X-API-Key: $KEY" \
  -d '{"annual_income":150000,"loan_amount":450000,"contract_rate":4.5,"property_tax_annual":4800,"other_debt_monthly":300}'
echo

echo "--- high-debt application (expect approved: false, TDS reason)"
curl -sf -X POST "$URL/v1/prequalify" -H "Content-Type: application/json" -H "X-API-Key: $KEY" \
  -d '{"annual_income":90000,"loan_amount":500000,"contract_rate":4.5,"property_tax_annual":4000,"other_debt_monthly":1500}'
echo

echo "--- wrong API key (expect HTTP 401)"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$URL/v1/prequalify" \
  -H "Content-Type: application/json" -H "X-API-Key: wrong" -d '{"annual_income":1,"loan_amount":1,"contract_rate":1}'
