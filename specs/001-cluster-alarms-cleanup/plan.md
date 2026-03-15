# Implementation Plan: Cluster Alarms Resolution & Component Cleanup

**Branch**: `001-cluster-alarms-cleanup` | **Date**: 2026-03-12 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/001-cluster-alarms-cleanup/spec.md`

## Summary

Resolve all currently firing Prometheus/AlertManager alerts on the k3s homelab cluster
(most likely caused by k3s-incompatible default rules in kube-prometheus-stack), then
purge all unused deployed services and orphaned Git artifacts. Confirmed orphans from
repo analysis: `linkding` (app removed but Helm chart + sealed secrets remain), `dnsmasq`
(empty chart, no ArgoCD app), and Pi-hole (deployed out-of-band, not in Git). The
Homepage dashboard also has a stale Linkding widget that must be removed.

## Technical Context

**Language/Version**: YAML (Kubernetes manifests, Helm values)
**Primary Dependencies**: ArgoCD, kube-prometheus-stack 82.2.0, Bitnami Sealed Secrets,
  Traefik ingress, cert-manager, k3s 1.x
**Storage**: N/A — no new storage; removing PVCs for decommissioned services
**Testing**: `kubectl` verification commands; ArgoCD UI health checks; AlertManager UI
**Target Platform**: k3s 3-node cluster (master: 192.168.68.150,
  workers: 192.168.68.151/152)
**Project Type**: GitOps infrastructure operations (YAML-only, no application code)
**Performance Goals**: N/A
**Constraints**: Zero downtime for all kept services during cleanup; all persistent
  state changes via Git + ArgoCD (GitOps-First); direct `kubectl delete` allowed only
  for removing out-of-band Pi-hole resources that ArgoCD does not manage
**Scale/Scope**: 8 ArgoCD apps + monitoring stack; 3–4 resource sets to remove

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. GitOps-First | ✅ PASS | All Git changes deployed via ArgoCD auto-sync. The only `kubectl` usage is to **remove** Pi-hole resources that ArgoCD never managed — this restores GitOps compliance rather than violating it. |
| II. Infrastructure as Code | ✅ PASS | No node/VM changes. No Ansible/Terraform modifications needed. |
| III. Secret Safety | ✅ PASS | Removing Sealed Secret manifests from repo; no plaintext secrets introduced. |
| IV. Storage Discipline | ✅ PASS | No new PVCs added. Removing PVCs for decommissioned services does not affect storage class assignments for kept services. |
| V. TLS Everywhere | ✅ PASS | No new ingresses added. Removing a service removes its ingress entirely — no HTTP exposure created. |

**Constitution Check result**: ✅ All gates pass. No Complexity Tracking entries needed.

## Project Structure

### Documentation (this feature)

```text
specs/001-cluster-alarms-cleanup/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output — verification steps
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
# Files to MODIFY
argocd/infrastructure/monitoring.yaml        # Disable k3s-incompatible alert rules
helm/homepage/values.yaml                    # Remove Linkding entry from services list

# Files to DELETE
helm/linkding/                               # Entire directory (no active ArgoCD app)
helm/dnsmasq/                                # Entire directory (empty chart, no app)
argocd/infrastructure/linkding-db-secret.yaml
argocd/infrastructure/secrets/linkding-db-secret.yaml

# Cluster-only actions (kubectl, not Git)
kubectl delete namespace pihole              # Or equivalent — confirmed after cluster query
```

**Structure Decision**: This is a pure GitOps operations task. There is no `src/`
directory. All changes are YAML file edits/deletions in `argocd/` and `helm/`.
Live cluster verification requires `kubectl` and `KUBECONFIG=~/.kube/homelab-config`.

## Complexity Tracking

> No constitution violations requiring justification.
