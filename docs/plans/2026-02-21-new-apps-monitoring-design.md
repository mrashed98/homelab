# Design: New Applications + Cluster Monitoring

**Date:** 2026-02-21
**Status:** Approved

## Overview

Add 7 new services to the homelab k3s cluster: pgAdmin, CommaFeed, Linkding, Wallabag, Transmission, Prometheus, and Grafana. Also establish full cluster monitoring via `kube-prometheus-stack`.

## Deployment Approach

**Infrastructure first, apps second.** Deploy `kube-prometheus-stack` as infrastructure first, then create all sealed secrets and database credentials, then roll out the 5 user apps. This gives Grafana dashboards during the app rollout and aligns with the existing `argocd/infrastructure/` vs `argocd/apps/` pattern.

## App Inventory and Chart Strategy

| App | Chart source | ArgoCD manifest | Namespace |
|---|---|---|---|
| kube-prometheus-stack | `prometheus-community` upstream | `argocd/infrastructure/monitoring.yaml` | `monitoring` |
| pgAdmin | `runix/pgadmin4` upstream | `argocd/apps/pgadmin.yaml` | `pgadmin` |
| CommaFeed | Custom `helm/commafeed/` | `argocd/apps/commafeed.yaml` | `commafeed` |
| Linkding | Custom `helm/linkding/` | `argocd/apps/linkding.yaml` | `linkding` |
| Wallabag | Custom `helm/wallabag/` | `argocd/apps/wallabag.yaml` | `wallabag` |
| Transmission | Custom `helm/transmission/` | `argocd/apps/transmission.yaml` | `downloads` |

CommaFeed, Linkding, Wallabag, and Transmission have no maintained upstream Helm charts. They use custom charts with official Docker images, following the same pattern as Vaultwarden.

## Data Layer

### PostgreSQL Databases (shared existing instance)
- `commafeed` database + user `commafeed`
- `linkding` database + user `linkding`
- `wallabag` database + user `wallabag`

pgAdmin is a client tool — no own database needed. Its config lives in its data directory.

Databases must be created manually on the PostgreSQL instance before apps deploy:
```sql
CREATE USER commafeed WITH PASSWORD '...';
CREATE DATABASE commafeed OWNER commafeed;

CREATE USER linkding WITH PASSWORD '...';
CREATE DATABASE linkding OWNER linkding;

CREATE USER wallabag WITH PASSWORD '...';
CREATE DATABASE wallabag OWNER wallabag;
```

### Sealed Secrets

| Secret file | Contents | Namespace |
|---|---|---|
| `argocd/secrets/app-db-credentials.yaml` | commafeed, linkding, wallabag DB passwords | respective app namespaces |
| `argocd/secrets/pgadmin-secret.yaml` | pgAdmin admin email + password | `pgadmin` |

### Storage

| App | StorageClass | NFS Path / Note |
|---|---|---|
| Transmission downloads | `nfs-hdd` | `/mnt/pve/BigData/k3s-shares/transmission` |
| pgAdmin data | `nfs-hdd` | `/mnt/pve/BigData/k3s-shares/pgadmin` |
| Wallabag assets | `nfs-hdd` | `/mnt/pve/BigData/k3s-shares/wallabag` |
| CommaFeed | none (DB-backed) | — |
| Linkding | none (DB-backed) | — |
| Grafana | `local-path` 10Gi | Dashboard/datasource state |
| Prometheus | `local-path` 20Gi | Time-series data |

## Ingress / TLS

All services use `.local` hostnames with TLS via `homelab-ca-issuer` (cert-manager).

| App | Hostname |
|---|---|
| Grafana | `grafana.local` |
| Prometheus | `prometheus.local` |
| pgAdmin | `pgadmin.local` |
| CommaFeed | `feed.local` |
| Linkding | `links.local` |
| Wallabag | `read.local` |
| Transmission | `torrent.local` |

All ingresses annotated with:
```yaml
cert-manager.io/cluster-issuer: homelab-ca-issuer
```

## Monitoring (kube-prometheus-stack)

**Included components:**
- Prometheus — metrics collection and storage
- Grafana — dashboards and visualization
- Alertmanager — alert routing (initially no routes configured)
- node-exporter DaemonSet — CPU, memory, disk, network per node
- kube-state-metrics — pod health, deployments, PVCs
- Pre-built dashboards — Node Exporter Full, Kubernetes cluster overview

**Scrape targets:**
- All 3 cluster nodes (via node-exporter)
- Kubernetes control plane (API server, scheduler, controller-manager)
- Pi-hole metrics endpoint (via ServiceMonitor)

**Retention:** Prometheus default (15 days), stored on `local-path` 20Gi.

**Alertmanager:** Deployed but no alert routes configured initially.

## Dependencies and Deployment Order

1. `kube-prometheus-stack` (monitoring infrastructure, no deps)
2. Sealed secrets for app DB credentials
3. PostgreSQL databases created manually
4. `pgadmin` (no DB deps, just NFS)
5. `commafeed`, `linkding`, `wallabag` (depend on DB secrets)
6. `transmission` (NFS only, no DB)
