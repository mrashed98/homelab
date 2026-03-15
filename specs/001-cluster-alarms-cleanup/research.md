# Research: Cluster Alarms Resolution & Component Cleanup

## 1. k3s-Incompatible Alerts in kube-prometheus-stack

### Decision
Disable Prometheus scrape/alerting targets for components that k3s replaces or removes:
`kubeScheduler`, `kubeControllerManager`, `kubeProxy`, and `kubeEtcd`. Configure
AlertManager to null-route the `Watchdog` alert (or route it silently) since it is
intended only as a dead-man's-switch heartbeat, not an actionable alarm.

### Rationale
kube-prometheus-stack ships Kubernetes-upstream alert rules that assume `kube-proxy`,
`kube-scheduler`, `kube-controller-manager`, and `etcd` expose their own scrape
endpoints. k3s consolidates these inside a single binary and does not expose them at the
expected ports. As a result, `KubeSchedulerDown`, `KubeControllerManagerDown`,
`KubeProxyDown`, and `etcdInsufficientMembers` fire permanently on every k3s cluster
running an unmodified kube-prometheus-stack deployment.

The `Watchdog` alert fires by design — it exists to verify that the alerting pipeline
is alive. On a homelab with Telegram notifications it generates constant noise. It should
be routed to a null/blackhole receiver in AlertManager rather than silenced at the rule
level (so it still confirms the pipeline is healthy without triggering a Telegram message).

### Alternatives Considered
- **Silence via AlertManager UI**: Short-term only; silences expire and are not stored
  in Git. Rejected in favour of a permanent Git-based fix.
- **Disable entire node-exporter or kube-state-metrics**: Too broad; these provide
  valuable metrics. Only the specific broken rule groups should be disabled.
- **Patch PrometheusRule CRDs directly**: Possible but not idiomatic for Helm-managed
  stacks. Preferred approach is Helm values (`kubeScheduler.enabled: false`, etc.).

### Implementation Details
Add the following to the `helm.values` block in `argocd/infrastructure/monitoring.yaml`:

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

For `Watchdog`, add a null receiver and route in the AlertManager config. Since
AlertManager config is stored in a Sealed Secret (`alertmanager-telegram-config`), the
config secret must be re-sealed with an updated `alertmanager.yaml` that includes:

```yaml
receivers:
  - name: 'null'
  - name: 'telegram'
    # ... existing telegram config ...

route:
  routes:
    - match:
        alertname: Watchdog
      receiver: 'null'
    - receiver: 'telegram'
```

---

## 2. Pi-hole Deployment Method

### Decision
Pi-hole is not managed by ArgoCD (confirmed: no `argocd/apps/pihole.yaml` exists).
It must be identified on the cluster by listing all Helm releases and namespaces, then
removed via `kubectl delete namespace` or `helm uninstall` as appropriate.

### Rationale
When an app is not in ArgoCD it was either deployed via direct `helm install` or
`kubectl apply`. Since ArgoCD runs with `prune: true`, any namespace/resource that
ArgoCD knows about would have been pruned. Its survival means it's out-of-band.

### Verification Steps (require live cluster access)

```bash
export KUBECONFIG=~/.kube/homelab-config

# Find Pi-hole namespace / release
kubectl get ns | grep -i pihole
helm list -A | grep -i pihole

# If Helm release:
helm uninstall <release-name> -n <namespace>

# If kubectl-only:
kubectl delete namespace <pihole-namespace>
```

### Cluster DNS Impact
k3s ships CoreDNS as the cluster DNS resolver. Pi-hole may be installed as an optional
LAN-wide upstream resolver, but CoreDNS does not depend on it for in-cluster resolution.
**Before removal**: verify no CoreDNS ConfigMap (`coredns` in `kube-system`) points to
Pi-hole as a forwarder.

```bash
kubectl get configmap coredns -n kube-system -o yaml | grep -i pihole
```

If the CoreDNS ConfigMap references Pi-hole, update it to use a public or LAN resolver
(e.g., `1.1.1.1`, `192.168.68.1`) before removing Pi-hole.

---

## 3. Linkding Database in PostgreSQL

### Decision
Verify and drop the `linkding` database and role from the central PostgreSQL instance
after confirming the app is gone.

### Rationale
The central PostgreSQL instance (`postgres.databases.svc.cluster.local`) likely has a
`linkding` database created when the app was originally deployed. Leaving orphaned
databases wastes storage and represents a dangling credential risk.

### Verification Steps (require live cluster access)

```bash
# Port-forward to PostgreSQL
kubectl port-forward svc/postgres 5432:5432 -n databases

# Connect with psql and check
psql -h localhost -U postgres -c "\l" | grep linkding

# If linkding DB exists, drop it:
psql -h localhost -U postgres -c "DROP DATABASE IF EXISTS linkding;"
psql -h localhost -U postgres -c "DROP ROLE IF EXISTS linkding;"
```

---

## 4. Orphaned Homepage Linkding Widget

### Decision
Remove the `Linkding` entry from `helm/homepage/values.yaml` under the `Reading`
service group.

### Rationale
Linkding has no active ArgoCD Application; `links.voltafinancials.com` resolves to
nothing. The homepage widget shows a broken link to users.

### Implementation Details
Delete these lines from `helm/homepage/values.yaml`:

```yaml
        - Linkding:
            href: https://links.voltafinancials.com
            icon: linkding.png
            description: Bookmark manager
```

---

## 5. Full Deployed Component Audit

### Components confirmed KEEP

| Component | ArgoCD App | Namespace | Status |
|-----------|------------|-----------|--------|
| ArgoCD | bootstrap | argocd | Core infrastructure |
| Sealed Secrets controller | infrastructure | kube-system | Core infrastructure |
| NFS storage provisioner | infrastructure | kube-system | Core infrastructure |
| cert-manager | infrastructure | cert-manager | Core infrastructure |
| PostgreSQL | infrastructure | databases | Core database |
| Redis | infrastructure | databases | Core database |
| Loki + Promtail | infrastructure | monitoring | Core logging |
| kube-prometheus-stack | infrastructure | monitoring | Core monitoring |
| Homepage | apps | homepage | Active |
| Vaultwarden | apps | vaultwarden | Active |
| Transmission | apps | transmission | Active |
| Wallabag | apps | wallabag | Active |
| CommaFeed | apps | commafeed | Active |
| Jellyfin | apps | jellyfin | Active |
| pgAdmin | apps | pgadmin | Active |
| Xtreme Downloader | apps | xtreme-downloader | Active |
| jellyfin-media PVC | helm/jellyfin-media | jellyfin | Required by Jellyfin |

### Components confirmed REMOVE

| Component | Location | Reason |
|-----------|----------|--------|
| Pi-hole | Cluster only (no Git manifest) | User confirmed unused; not GitOps managed |
| Linkding app | Already removed from argocd/apps | App removed previously |
| helm/linkding/ | Git repo | Orphaned Helm chart |
| argocd/infrastructure/linkding-db-secret.yaml | Git repo | Orphaned sealed secret |
| argocd/infrastructure/secrets/linkding-db-secret.yaml | Git repo | Duplicate orphaned sealed secret |
| helm/dnsmasq/ | Git repo | Empty chart directory, no ArgoCD app |
| Homepage Linkding widget | helm/homepage/values.yaml | Points to removed service |
| linkding PostgreSQL database | cluster PostgreSQL | Orphaned database for removed app |
