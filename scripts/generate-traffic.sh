#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# generate-traffic.sh - sends broker-like traffic so the Grafana dashboard has
# something to show.
#   ./scripts/generate-traffic.sh <broker-api-key> [seconds]          normal traffic
#   ./scripts/generate-traffic.sh --bad-key [seconds]                 wrong keys: fires PrequalUnauthorizedSpike
# Needs the port-forward from smoke-test.sh running.
# -----------------------------------------------------------------------------
set -uo pipefail
URL="${URL:-http://localhost:8000}"
MODE="${1:?usage: $0 <broker-api-key>|--bad-key [seconds]}"
DURATION="${2:-120}"
END=$((SECONDS + DURATION))
KEY="$MODE"; [ "$MODE" = "--bad-key" ] && KEY="not-a-valid-key"

count=0
while [ $SECONDS -lt $END ]; do
  income=$(( (RANDOM % 150 + 50) * 1000 ))  # 50k - 200k
  loan=$(( (RANDOM % 600 + 200) * 1000 ))   # 200k - 800k
  debt=$(( RANDOM % 2000 ))
  curl -s -o /dev/null -X POST "$URL/v1/prequalify" -H "Content-Type: application/json" -H "X-API-Key: $KEY" \
    -d "{\"annual_income\":$income,\"loan_amount\":$loan,\"contract_rate\":4.79,\"property_tax_annual\":4200,\"other_debt_monthly\":$debt}"
  count=$((count + 1))
  sleep 0.5
done
echo "Sent $count requests in ${DURATION}s"
