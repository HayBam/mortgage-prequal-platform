# Audit and compliance controls

How this platform answers the questions an auditor (internal audit, OSFI
examiners) typically asks. Mapped loosely to **OSFI Guideline B-13
(Technology and Cyber Risk Management)** themes. This is a demo, not a
compliance attestation.

| Auditor question | Control | Evidence (where to look) |
|---|---|---|
| Who approved this production change? | Every change goes through a pull request; infra apply needs approval in the `production` environment | GitHub PR history; Actions run > "Review deployments" approval record |
| What exactly is running in production? | Images deployed by **digest**; Argo CD keeps the cluster equal to Git | `deploy/mortgage-prequal/kustomization.yaml` in Git history; Argo CD app History |
| Was it scanned before release? | Trivy gate (HIGH/CRITICAL fixable = fail); Checkov on Terraform, Kubernetes and Dockerfile | Release run artifact `release-evidence-<sha>` (Trivy report + SBOM); PR checks |
| What is inside the image? | CycloneDX SBOM per release | Same artifact, kept 90 days |
| Can someone change production by hand? | Argo CD self-heal reverts drift; local accounts off; only Entra ID identities with an Azure RBAC role can call the API server | `AKSAuditAdmin` table (who ran what); Argo CD events |
| Who accessed secrets? | Key Vault RBAC; app identity is read-only; secret values never in Git or state | `AZKVAuditLogs` table |
| Are there long-lived credentials? | None. GitHub > Azure uses OIDC federation; pods use workload identity; no ACR admin user, no storage keys | Entra ID app registration > Federated credentials |
| Is access least-privilege? | Pipeline identity scoped to ONE resource group; kubelet has AcrPull only; app has Secrets User only | Azure portal > Access control (IAM) |
| How do infra changes get tracked? | Terraform in Git; remote state with versioning and soft delete | Git history; storage account blob versions |
| Are exceptions documented? | Every skipped Checkov rule has a written reason next to the code | `#checkov:skip=` comments in `infra/*.tf` |
| Is data kept in Canada? | All resources in `canadacentral` | Resource group location; Terraform plan |
| Can you detect and respond to incidents? | Prometheus alerts with runbook links; Defender for Containers; centralized logs | `docs/runbook.md`; Grafana; Defender for Cloud alerts |
| Is it recoverable? | Everything is code: infra (Terraform), config (Git), deploys (Argo CD). Rebuild = run the pipelines | This repository |

## Useful KQL for evidence

```kusto
// Every create/update/delete in the cluster, and who did it
AKSAuditAdmin
| where TimeGenerated > ago(24h)
| where Verb in ("create", "update", "patch", "delete")
| project TimeGenerated, User = tostring(User.username), Verb, ObjectRef = strcat(tostring(ObjectRef.resource), "/", tostring(ObjectRef.namespace), "/", tostring(ObjectRef.name))
| order by TimeGenerated desc
```

```kusto
// Argo CD sync activity (Kubernetes events emitted by Argo CD)
KubeEvents
| where TimeGenerated > ago(24h)
| where Namespace == "argocd"
| project TimeGenerated, Name, Reason, Message
| order by TimeGenerated desc
```

```kusto
// Who read the broker API key
AZKVAuditLogs
| where TimeGenerated > ago(24h)
| where OperationName == "SecretGet"
| project TimeGenerated, CallerIpAddress, Identity = tostring(Identity), ResultSignature
```

## What a production bank setup would add
- Private GitHub Enterprise repo, CODEOWNERS, at least one reviewer who is not the author (segregation of duties)
- Required status checks, with a GitHub App token for the release bot so its PRs run checks too
- Separate pipeline identities: read-only for PR plans, AcrPush-only for app releases
- Private AKS cluster and ACR Premium with private endpoints; self-hosted runners inside the network
- Argo CD SSO through Entra ID groups; notifications to Teams
- Image signing (Notation/Cosign) and admission policy that only allows signed images
- Log retention set to the bank's records policy, with archive tier and immutable storage
