# Runbook: Broker Mortgage Pre-Qualification API

Each alert in `deploy/mortgage-prequal/prometheusrule.yaml` links to a section here.

**First moves for any alert**
1. Open Grafana dashboard **Broker Mortgage Pre-Qualification API**.
2. Check Argo CD: was there a sync (release) in the last 30 minutes? (`Application > History and rollback`)
3. Check pods: `kubectl -n mortgage-prequal get pods -o wide` and `kubectl -n mortgage-prequal describe pod <pod>`.

**Rollback (any alert caused by a release)**
Revert the release PR in GitHub (**Revert** button on the merged PR, then merge the revert PR). Argo CD redeploys the previous digest. Do **not** roll back with `kubectl`: self-heal would undo it, and it leaves no audit trail.

---

## PrequalHighErrorRate
More than 5% of requests return 5xx for 2 minutes.
- Logs (Log Analytics, KQL):
  ```kusto
  ContainerLogV2
  | where PodNamespace == "mortgage-prequal"
  | where TimeGenerated > ago(30m)
  | where LogMessage has_any ("ERROR", "Traceback", " 500 ")
  | project TimeGenerated, PodName, LogMessage
  | order by TimeGenerated desc
  ```
- If it started at a release: roll back (above).
- Otherwise: check node health (`kubectl get nodes`) and recent Kubernetes events (`KubeEvents` table).

## PrequalHighLatency
p95 latency above 500 ms for 5 minutes.
- Check CPU throttling on the dashboard (CPU per pod vs the 500m limit).
- Check node pressure: `kubectl top nodes`, `kubectl top pods -n mortgage-prequal`.
- Short-term fix: raise replicas in `deployment.yaml` through a PR.

## PrequalUnauthorizedSpike
More than 0.2 rejected API keys per second for 1 minute.
- Likely causes: (a) a broker using an old key after rotation; (b) credential stuffing or abuse.
- Check whether the key was rotated recently (Key Vault audit log):
  ```kusto
  AZKVAuditLogs
  | where TimeGenerated > ago(24h)
  | where OperationName in ("SecretSet", "SecretGet")
  | project TimeGenerated, OperationName, CallerIpAddress, Identity = tostring(Identity), ResultSignature
  | order by TimeGenerated desc
  ```
- If abuse is suspected: escalate to Security (SOC). In production, block the source at the WAF.

## PrequalReplicasUnavailable
Fewer than 2 ready pods for 2 minutes.
- `kubectl -n mortgage-prequal get pods` and `describe pod`:
  - `ImagePullBackOff`: digest not in ACR, or the kubelet identity lost AcrPull.
  - `ContainerCreating` with a CSI mount error: the Key Vault secret is missing, or the private endpoint/DNS is broken.
  - Readiness failing: `/readyz` returns 503 = the API key file did not load.
- Check Argo CD for sync errors.

---

## After the incident
Write a short RCA (template in `docs/rca-template.md`): timeline, impact, root cause, corrective and preventive actions. File the actions as GitHub issues.
