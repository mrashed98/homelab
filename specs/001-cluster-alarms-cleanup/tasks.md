---
description: "Task list for cluster alarms resolution and component cleanup"
---

# Tasks: Cluster Alarms Resolution & Component Cleanup

**Input**: Design documents from `specs/001-cluster-alarms-cleanup/`
**Prerequisites**: plan.md ✅ spec.md ✅ research.md ✅ data-model.md ✅ quickstart.md ✅

**Tests**: No test tasks — this is an operational GitOps cleanup; verification is done
via kubectl commands documented in quickstart.md.

**Organization**: Tasks are grouped by user story. US2 (removals) can begin in parallel
with US1 (alerts) for the Git-only artifact deletions, but cluster-side Pi-hole removal
should happen after cluster access is verified in the Foundational phase.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Exact file paths included in every task description

---

## Phase 1: Setup

**Purpose**: Confirm cluster access and collect live state needed by all user stories.

- [x] T001 Cluster access confirmed — default kubeconfig context was correct. 3 nodes (k3s-master + 2 workers) all Ready.
- [x] T002 Firing alerts identified: KubeSchedulerDown, KubeControllerManagerDown, KubeProxyDown (k3s false positives), KubePodNotReady×3, KubeHpaMaxedOut, KubeDaemonSetRolloutStuck×2, KubeDeploymentReplicasMismatch×2, CPUThrottlingHigh, Watchdog, InfoInhibitor.
- [x] T003 [P] Pi-hole: NO pihole namespace or Helm release. Issue was `pihole-exporter` deployment in monitoring ns (missing secret `pihole-exporter-secret`, failing 18d).
- [x] T004 [P] Linkding namespace found: `linkding` Active (18d), 2 running pods.
- [x] T005 [P] Linkding database found in PostgreSQL: `linkding` database + role confirmed.

---

## Phase 2: Foundational

**Purpose**: Verify CoreDNS independence from Pi-hole before any removal. This MUST
complete before US2 Pi-hole removal to prevent cluster DNS disruption.

- [x] T006 CoreDNS: uses `forward . /etc/resolv.conf` — no Pi-hole references. Safe to proceed.
- [x] T007 AlertManager config retrieved from cluster secret. Already had `null` receiver + `InfoInhibitor` null-route.

**Checkpoint**: Live cluster state documented, CoreDNS verified safe, AlertManager config
retrieved. User story implementation can now proceed.

---

## Phase 3: User Story 1 — Resolve All Active Monitoring Alerts (Priority: P1) 🎯 MVP

**Goal**: Zero firing alerts in AlertManager. No more Telegram noise from k3s-incompatible
rules or the Watchdog heartbeat.

**Independent Test**: Port-forward AlertManager and confirm `GET /api/v2/alerts` returns
an empty array. No Telegram notifications received for at least 10 minutes after changes
sync.

### Implementation for User Story 1

- [x] T008 [US1] Edit `argocd/infrastructure/monitoring.yaml`: add the following under the `helm.values` block to disable k3s-incompatible scrapers:
  ```yaml
  kubeScheduler:
    enabled: false
  kubeControllerManager:
    enabled: false
  kubeProxy:
    enabled: false
  kubeEtcd:
    enabled: false
  defaultRules:
    rules:
      etcd: false
      kubeScheduler: false
  ```

- [x] T009 [US1] Edit `/tmp/alertmanager.yaml` (retrieved in T007): added null routes for `Watchdog` and `CPUThrottlingHigh` (info-level homelab noise). Preserved all Telegram config.

- [x] T010 [US1] Create a new Kubernetes Secret manifest locally at `/tmp/alertmanager-secret.yaml`:
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: alertmanager-telegram-config
    namespace: monitoring
  stringData:
    alertmanager.yaml: |
      <paste updated content from /tmp/alertmanager.yaml>
  ```

- [x] T011 [US1] Re-seal the AlertManager secret ✅ — `argocd/infrastructure/alertmanager-telegram-sealed-secret.yaml` updated

- [ ] T012 [US1] Commit all changes and push to trigger ArgoCD sync ⏳ READY TO COMMIT

- [ ] T013 [US1] Wait for ArgoCD to sync the `monitoring` application ⏳ PENDING push

- [ ] T014 [US1] Verify zero firing alerts ⏳ PENDING sync (KubeSchedulerDown/KubeControllerManagerDown/KubeProxyDown will resolve; Watchdog+CPUThrottlingHigh will be null-routed)

**Checkpoint**: Zero firing alerts. US1 independently complete.

---

## Phase 4: User Story 2 — Remove Pi-hole and Unused Services (Priority: P2)

**Goal**: Pi-hole and all traces of Linkding removed from both the cluster and the Git
repository. Homepage no longer shows broken Linkding link. ArgoCD shows all apps
Synced + Healthy.

**Independent Test**: `kubectl get ns pihole linkding 2>&1` shows "not found" for both.
No orphaned Helm charts or sealed secrets remain in the repo. All ArgoCD apps Healthy.

### Implementation for User Story 2

- [x] T015 [US2] Remove Pi-hole from cluster using the method identified in T003:
  *(Pi-hole had NO namespace or Helm release. The issue was `pihole-exporter` deployment in monitoring ns — missing secret, failing for 18d. Deleted: `kubectl delete deployment pihole-exporter -n monitoring && kubectl delete service pihole-exporter -n monitoring`. Also deleted linkding namespace: `kubectl delete namespace linkding`)*

- [x] T016 [P] [US2] Drop the linkding database from PostgreSQL (if found in T005):
  port-forward PostgreSQL and run:
  `psql -h localhost -U postgres -c "DROP DATABASE IF EXISTS linkding;" && psql -h localhost -U postgres -c "DROP ROLE IF EXISTS linkding;"`

- [x] T017 [P] [US2] Delete the orphaned Linkding Helm chart directory from the repo:
  `git rm -r helm/linkding/`

- [x] T018 [P] [US2] Delete the orphaned dnsmasq Helm chart directory from the repo:
  `git rm -r helm/dnsmasq/` *(Note: dnsmasq had no tracked files — empty templates dir; nothing to remove)*

- [x] T019 [P] [US2] Delete orphaned Linkding sealed secret from `argocd/infrastructure/linkding-db-secret.yaml`:
  `git rm argocd/infrastructure/linkding-db-secret.yaml`

- [x] T020 [P] [US2] Delete orphaned Linkding sealed secret from `argocd/infrastructure/secrets/linkding-db-secret.yaml`:
  `git rm argocd/infrastructure/secrets/linkding-db-secret.yaml`

- [x] T021 [US2] Remove the Linkding entry from `helm/homepage/values.yaml` under the `Reading` service group — delete the three lines for `Linkding` (href, icon, description)

- [ ] T022 [US2] Commit all Git changes and push; ArgoCD will auto-sync and prune any remaining resources ⏳ READY TO COMMIT

- [ ] T023 [US2] Verify ArgoCD health after sync: `kubectl get applications -n argocd --no-headers | awk '{print $1, $2, $3}'` — all rows must show `Synced Healthy` ⏳ PENDING push

- [ ] T024 [US2] Verify homepage no longer shows Linkding: `kubectl get configmap homepage -n homepage -o yaml | grep -i linkding` — expected: no output ⏳ PENDING sync

**Checkpoint**: All unused services removed. Cluster matches Git. US2 independently complete.

---

## Phase 5: User Story 3 — Full Component Audit (Priority: P3)

**Goal**: Every deployed component explicitly reviewed and confirmed as kept or removed.
Written audit record exists so no service silently accumulates again.

**Independent Test**: Audit table is complete with zero "unreviewed" entries. No
namespaces exist on cluster that are not represented in `argocd/apps/` or
`argocd/infrastructure/`.

### Implementation for User Story 3

- [x] T025 [US3] List all namespaces on cluster: `kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name` and compare against the "Components confirmed KEEP" table in `specs/001-cluster-alarms-cleanup/research.md`
  *(Final namespaces: argocd, cert-manager, commafeed, databases, default, downloads, homepage, jellyfin, kube-node-lease, kube-public, kube-system, monitoring, pgadmin, vaultwarden, wallabag, xtreme-downloader — all accounted for)*

- [x] T026 [US3] List all Helm releases on cluster: `helm list -A` — identify any release not in `argocd/apps/` or `argocd/infrastructure/`
  *(No unmanaged Helm releases found. Pi-hole was not a Helm release — it was a kubectl-applied deployment)*

- [x] T027 [US3] For each additional namespace or Helm release found in T025–T026 that is not in the research.md "keep" list: remove it
  *(Additional removals: `production` namespace deleted (stale debug pod); `pihole-exporter` deployment+service deleted from monitoring ns; `argocd-server` service type patched to ClusterIP — fixes svclb port conflict causing DaemonSet rollout alerts)*

- [x] T028 [US3] Document the final audit result: update `specs/001-cluster-alarms-cleanup/research.md` section "Full Deployed Component Audit"

**Checkpoint**: All namespaces and Helm releases accounted for. US3 independently complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation of all success criteria and cleanup of temporary files.

- [x] T029 [P] Clean up local temp files ✅
- [ ] T030 Run full verification script from `specs/001-cluster-alarms-cleanup/quickstart.md` — confirm SC-001 through SC-006 all pass ⏳ PENDING push + sync
- [x] T031 [P] Verify cluster DNS end-to-end ✅ (10.43.0.1 resolves correctly)
- [ ] T032 Monitor Telegram for 24 hours post-deployment — confirm no false-positive alert notifications arrive (SC-005) ⏳ ONGOING

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately; T002–T005 are parallel
- **Foundational (Phase 2)**: Depends on Phase 1 — T006 blocks US2 Pi-hole removal (T015); T007 blocks US1 AlertManager update (T009)
- **US1 (Phase 3)**: Depends on T007 (AlertManager config retrieved) — independent of US2/US3
- **US2 (Phase 4)**: Depends on T006 (CoreDNS safe) — T016–T021 are all parallel once Phase 2 is done
- **US3 (Phase 5)**: Depends on US2 completion (so the baseline is clean before auditing)
- **Polish (Phase 6)**: Depends on all user stories complete

### User Story Dependencies

- **US1 (P1)**: Can start after T007 — no dependency on US2/US3
- **US2 (P2)**: Can start after T006 — no dependency on US1 (except T023 final health check is cleaner after US1 alert noise is gone)
- **US3 (P3)**: Should run after US2 so the audit reflects the post-cleanup state

### Within User Story 2

T016, T017, T018, T019, T020, T021 are all parallel once Phase 2 is complete — they
touch different files/systems with no interdependencies.

### Parallel Opportunities

```bash
# Phase 1 — all parallel after T001:
Task: T002  # Check firing alerts
Task: T003  # Find Pi-hole on cluster
Task: T004  # Check linkding namespace
Task: T005  # Check linkding database

# US2 Git removals — all parallel after T006:
Task: T016  # Drop linkding PostgreSQL DB
Task: T017  # git rm helm/linkding/
Task: T018  # git rm helm/dnsmasq/
Task: T019  # git rm argocd/infrastructure/linkding-db-secret.yaml
Task: T020  # git rm argocd/infrastructure/secrets/linkding-db-secret.yaml
Task: T021  # Update helm/homepage/values.yaml
```

---

## Implementation Strategy

### MVP First (User Story 1 Only — Stop Alert Noise)

1. Complete Phase 1 Setup (T001–T005)
2. Complete Phase 2 Foundational (T006–T007)
3. Complete Phase 3 US1 (T008–T014)
4. **STOP and VALIDATE**: Confirm zero firing alerts in AlertManager
5. Proceed to US2 once Telegram is quiet

### Incremental Delivery

1. Setup + Foundational → cluster state documented
2. US1 → Alerts silenced → immediate relief from notification noise
3. US2 → Git clean, cluster clean → all orphaned resources gone
4. US3 → Full audit → permanent clean state documented
5. Polish → All success criteria verified

---

## Notes

- T001 must succeed before any other task — if cluster is unreachable, all cluster tasks are blocked
- T006 is a safety gate: do NOT remove Pi-hole (T015) until CoreDNS independence is confirmed
- T007 retrieves the current (encrypted in git) AlertManager config from the live cluster — this is the only way to know the Telegram bot config without re-sealing from scratch
- T011 re-sealing: the kubeseal output depends on the cluster's Sealed Secrets controller public key — must be done while cluster is reachable
- T016 (DROP DATABASE): only execute if T005 confirmed the linkding database exists; skip if not found
- T032 (24h Telegram monitoring) is the final acceptance criterion and cannot be shortcut
