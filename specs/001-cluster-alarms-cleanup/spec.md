# Feature Specification: Cluster Alarms Resolution & Component Cleanup

**Feature Branch**: `001-cluster-alarms-cleanup`
**Created**: 2026-03-12
**Status**: Draft
**Input**: User description: "Check the Alarms That popped out and fix them, check all
deployed components used like pihole is installed but not used so it needs to be removed"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resolve All Active Monitoring Alerts (Priority: P1)

As a homelab operator, I need all currently firing Prometheus/AlertManager alerts to be
investigated and resolved so that the Telegram notification channel only fires on genuine
future incidents, not on persistent known-bad state.

**Why this priority**: Active alarms indicate real cluster health issues. Unresolved alerts
produce alert fatigue, causing future critical issues to be missed or ignored.

**Independent Test**: The AlertManager UI at `https://prometheus.voltafinancials.com`
shows zero firing alerts, and no new Telegram notifications arrive for previously firing
conditions.

**Acceptance Scenarios**:

1. **Given** AlertManager is currently showing firing alerts, **When** each alert's root
   cause is identified and remediated, **Then** the alert transitions to resolved state
   and no longer generates Telegram notifications.
2. **Given** an alert fires due to misconfigured thresholds unsuitable for a homelab
   scale, **When** the rule is adjusted to appropriate values, **Then** the alert no
   longer fires spuriously while still detecting genuine failures.
3. **Given** an alert fires because a removed service still has alerting rules, **When**
   the orphaned alerting rules are cleaned up, **Then** no further spurious alerts fire
   for that service.

---

### User Story 2 - Remove Pi-hole and Other Unused Deployed Services (Priority: P2)

As a homelab operator, I need all services that are deployed on the cluster but no longer
actively used to be fully removed (from both the cluster and the Git repository) so that
cluster resources are not wasted and the repository accurately reflects the running state.

**Why this priority**: Unused services consume CPU, memory, and storage. They create
unnecessary attack surface and drift between Git state and cluster state.

**Independent Test**: Pi-hole (and any other identified unused services) no longer have
running pods or persistent volumes on the cluster, and no ArgoCD Application or Helm
chart for them exists in the repository.

**Acceptance Scenarios**:

1. **Given** Pi-hole is deployed on the cluster but not serving as the cluster's DNS
   resolver, **When** its resources are removed (ArgoCD Application or direct Helm
   release, pods, PVCs, namespace), **Then** no Pi-hole resources remain on the cluster
   and cluster DNS continues to function normally.
2. **Given** a service has been removed from `argocd/apps/` but its supporting artifacts
   (Helm chart, sealed secrets, database secrets) remain in the repo, **When** those
   orphaned files are deleted from Git, **Then** ArgoCD no longer references them and
   the repository contains no dead code.
3. **Given** a service is removed, **When** the operator checks the Homepage dashboard,
   **Then** any link or widget for the removed service is also removed from the dashboard
   configuration.

---

### User Story 3 - Audit All Deployed Components (Priority: P3)

As a homelab operator, I need a confirmed audit of every service currently deployed on
the cluster, with each one explicitly categorised as "active and kept" or "removed", so
that the cluster reflects only intentionally kept services going forward.

**Why this priority**: Pi-hole was identified reactively. A systematic audit prevents
the same accumulation problem from recurring.

**Independent Test**: A written audit record confirms the disposition of every ArgoCD
Application and any non-ArgoCD Helm releases found on the cluster, with zero unreviewed
entries.

**Acceptance Scenarios**:

1. **Given** the full list of ArgoCD Applications and any non-GitOps Helm releases on
   the cluster, **When** each is reviewed against actual operator usage, **Then** each is
   explicitly marked keep or remove with a stated reason.
2. **Given** the audit identifies additional unused services beyond Pi-hole, **When**
   those services are removed following the same process as User Story 2, **Then** the
   cluster state matches the Git repository with no orphaned namespaces remaining.

---

### Edge Cases

- What if Pi-hole is acting as LAN-wide DNS for non-cluster devices? Cluster DNS MUST
  be verified unaffected before removal; if external devices depend on Pi-hole, a
  migration plan MUST be agreed before decommissioning.
- What if a removed service owns a database in the central PostgreSQL instance? The
  database and its user MUST be dropped after confirming the service is gone and data is
  no longer needed.
- What if an alert is firing due to a legitimate ongoing issue (e.g., node memory
  pressure)? The underlying issue MUST be fixed, not silenced — alerts MUST only be
  closed after the root condition is resolved.
- What if a Sealed Secret in `argocd/infrastructure/` references a namespace with no
  active ArgoCD Application? The Sealed Secret manifest MUST be removed from the repo
  to avoid ArgoCD sync errors targeting non-existent namespaces.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The operator MUST identify every currently firing Prometheus alert by
  querying the AlertManager or Grafana alerting UI.
- **FR-002**: Each firing alert MUST have its root cause identified (misconfigured
  threshold, degraded service, orphaned rule, or legitimate failure) and an appropriate
  fix applied — no alert MUST be silenced without first addressing root cause.
- **FR-003**: Alert thresholds that are inappropriate for a homelab scale MUST be
  adjusted in `argocd/infrastructure/monitoring.yaml`.
- **FR-004**: Pi-hole MUST be fully removed: its ArgoCD Application (if present) or
  direct Helm release removed, all pods, PVCs, and its namespace deleted from the
  cluster.
- **FR-005**: Orphaned Helm charts in `helm/` with no active ArgoCD Application MUST
  be removed from the repository. Confirmed candidates: `helm/linkding/`,
  `helm/dnsmasq/`.
- **FR-006**: Orphaned Sealed Secret manifests in `argocd/infrastructure/` referencing
  apps with no active ArgoCD Application MUST be removed. Confirmed candidates:
  `argocd/infrastructure/linkding-db-secret.yaml` and
  `argocd/infrastructure/secrets/linkding-db-secret.yaml`.
- **FR-007**: After every removal, all remaining ArgoCD Applications MUST show `Synced`
  and `Healthy` status — no `OutOfSync` or `Degraded` state is acceptable.
- **FR-008**: Cluster DNS MUST remain fully functional throughout and after any
  DNS-adjacent component removal.
- **FR-009**: The Homepage dashboard configuration MUST be updated to remove links or
  widgets for any decommissioned services.

### Key Entities

- **Firing Alert**: A Prometheus alert in `Firing` state; characterised by alert name,
  namespace, severity, and start time. Resolution changes state to `Inactive`.
- **Deployed Component**: Any ArgoCD Application, standalone Helm release, or
  directly-applied manifest running on the cluster. May be GitOps-managed or out-of-band.
- **Orphaned Artifact**: A file in the repo (`helm/`, `argocd/`) for a service with no
  active ArgoCD Application and no current operational use.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero firing alerts remain in AlertManager after all remediations are
  applied and confirmed.
- **SC-002**: Zero pods or PVCs running in any namespace corresponding to a removed or
  decommissioned service.
- **SC-003**: Zero orphaned Helm charts or Sealed Secret manifests remain in the
  repository for services with no active ArgoCD Application.
- **SC-004**: All ArgoCD Applications show `Synced` and `Healthy` status after cleanup.
- **SC-005**: No false-positive Telegram alert notifications are received for at least
  24 hours following completion of all remediations.
- **SC-006**: Cluster DNS resolution continues to function correctly for all remaining
  services after removal of any DNS-related components.

## Assumptions

- Alarms route via AlertManager to a Telegram bot (confirmed from
  `argocd/infrastructure/alertmanager-telegram-sealed-secret.yaml`).
- Pi-hole is not managed by ArgoCD (no `argocd/apps/pihole.yaml` exists); it was likely
  deployed manually or via a direct Helm release directly on the cluster.
- Linkding was intentionally removed from `argocd/apps/` at some earlier point, but its
  supporting artifacts (`helm/linkding/`, `linkding-db-secret` sealed secrets) were not
  cleaned up at that time.
- `helm/dnsmasq/` has an empty `templates/` directory and no ArgoCD Application — it is
  safe to remove as a dead artifact.
- `helm/jellyfin-media/` is actively used: it provides the `jellyfin-media` PVC consumed
  by the `jellyfin` ArgoCD Application and MUST be kept.
- The central PostgreSQL instance may hold a `linkding` database that MUST be confirmed
  dropped as part of linkding cleanup.
- Cluster-internal DNS is handled by CoreDNS (k3s default), not Pi-hole, so Pi-hole
  removal will not affect in-cluster service DNS resolution.
