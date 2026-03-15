# Data Model: Cluster Alarms Resolution & Component Cleanup

This feature does not introduce new data entities to the system. It operates on the
existing cluster inventory. The entities below define the operational model used to
track work and validate completion.

---

## Deployed Component

Represents any workload running on the cluster, regardless of how it was installed.

| Field | Type | Description |
|-------|------|-------------|
| name | string | Human-readable service name (e.g., "Pi-hole", "Linkding") |
| namespace | string | Kubernetes namespace |
| argocd_app | string \| null | Name of ArgoCD Application manifest, or `null` if not GitOps-managed |
| helm_chart | string \| null | Path to `helm/<name>/` chart in repo, or `null` if upstream |
| git_secrets | []string | Paths to `argocd/infrastructure/` sealed secret files |
| postgresql_database | string \| null | Database name in central PostgreSQL, if any |
| homepage_widget | bool | Whether an entry exists in `helm/homepage/values.yaml` |
| disposition | enum | `keep` \| `remove` |

**State transition**: `deployed (out-of-band)` → `removed from cluster` → `removed from git`

---

## Firing Alert

Represents a Prometheus alert currently in `Firing` state.

| Field | Type | Description |
|-------|------|-------------|
| alert_name | string | Prometheus alert name (e.g., `KubeSchedulerDown`) |
| namespace | string | Originating namespace |
| severity | enum | `critical` \| `warning` \| `info` |
| start_time | datetime | When the alert entered Firing state |
| root_cause | enum | `k3s_incompatible_rule` \| `bad_threshold` \| `orphaned_rule` \| `legitimate_failure` |
| resolution | string | Descriptive fix applied |

**State transition**: `Firing` → `Pending` → `Inactive` (after fix committed and synced)

---

## Orphaned Artifact

Represents a file in the Git repo that belongs to a removed or non-existent service.

| Field | Type | Description |
|-------|------|-------------|
| path | string | Relative path in repo (e.g., `helm/linkding/`) |
| artifact_type | enum | `helm_chart` \| `sealed_secret` \| `argocd_app` |
| associated_service | string | The service this artifact was for |
| safe_to_delete | bool | `true` if confirmed no active app references it |

**State transition**: `present` → `deleted in Git` → `pruned by ArgoCD`

---

## Confirmed Instances

### Deployed Components → Remove

| Name | Namespace | ArgoCD App | Helm Chart | Git Secrets | PG Database | Homepage Widget |
|------|-----------|------------|------------|-------------|-------------|-----------------|
| Pi-hole | pihole (TBC) | null | null | none | none | false |
| Linkding | linkding (TBC) | null (removed) | helm/linkding/ | linkding-db-secret (×2) | linkding (TBC) | true |

### Orphaned Artifacts → Delete

| Path | Type | Service | Safe to Delete |
|------|------|---------|---------------|
| helm/linkding/ | helm_chart | Linkding | true |
| helm/dnsmasq/ | helm_chart | dnsmasq | true |
| argocd/infrastructure/linkding-db-secret.yaml | sealed_secret | Linkding | true |
| argocd/infrastructure/secrets/linkding-db-secret.yaml | sealed_secret | Linkding | true |
