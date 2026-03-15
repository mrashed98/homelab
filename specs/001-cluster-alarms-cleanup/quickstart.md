# Quickstart & Verification Guide: Cluster Alarms Resolution & Component Cleanup

This guide describes how to verify the cluster before starting, and how to confirm
each success criterion after each change is applied.

## Prerequisites

```bash
export KUBECONFIG=~/.kube/homelab-config
kubectl get nodes   # Confirm cluster is reachable
```

---

## Step 1: Triage Firing Alerts

```bash
# List all currently firing alerts
kubectl port-forward svc/prometheus-alertmanager 9093:9093 -n monitoring &
curl -s http://localhost:9093/api/v2/alerts | \
  jq '.[] | select(.status.state == "active") | {alert: .labels.alertname, severity: .labels.severity, since: .startsAt}'
```

Expected common output on a fresh k3s + kube-prometheus-stack install:
- `KubeSchedulerDown` → fix: disable in Helm values
- `KubeControllerManagerDown` → fix: disable in Helm values
- `KubeProxyDown` → fix: disable in Helm values
- `etcdInsufficientMembers` → fix: disable etcd rules in Helm values
- `Watchdog` → fix: null-route in AlertManager config

Any other alerts must be investigated individually before applying fixes.

---

## Step 2: Identify Pi-hole Deployment

```bash
# Find Pi-hole by namespace
kubectl get ns | grep -i pihole

# Find any Helm release
helm list -A | grep -i pihole

# Check if CoreDNS uses Pi-hole as upstream
kubectl get configmap coredns -n kube-system -o yaml
```

---

## Step 3: Verify Linkding is Not Running

```bash
kubectl get ns linkding 2>/dev/null && echo "NAMESPACE EXISTS" || echo "Already gone"
kubectl get pods -n linkding 2>/dev/null
```

---

## Step 4: Check for Linkding PostgreSQL Database

```bash
kubectl port-forward svc/postgres 5432:5432 -n databases &
psql -h localhost -U postgres -c "\l" | grep linkding
```

---

## Verification After Each Change

### After monitoring.yaml update (alert rule fix)

```bash
# Wait for ArgoCD sync (~60s), then re-check
kubectl port-forward svc/prometheus-alertmanager 9093:9093 -n monitoring &
curl -s http://localhost:9093/api/v2/alerts | jq 'length'
# Expected: 0 (or only Watchdog, which should be null-routed)
```

### After Pi-hole removal

```bash
# No Pi-hole namespace or pods
kubectl get ns | grep -i pihole   # Expected: no output

# Cluster DNS still works
kubectl run dns-test --image=busybox --restart=Never --rm -it -- nslookup kubernetes.default
# Expected: successful resolution
```

### After Git artifact cleanup (linkding, dnsmasq) merged to master

```bash
# ArgoCD shows no OutOfSync or Degraded apps
kubectl get applications -n argocd -o wide
# Expected: all apps show Synced + Healthy

# No linkding namespace
kubectl get ns linkding 2>/dev/null || echo "Clean"

# No pihole namespace
kubectl get ns pihole 2>/dev/null || echo "Clean"
```

### After homepage values.yaml update

```bash
# Check homepage configmap has no Linkding entry
kubectl get configmap homepage -n homepage -o yaml | grep -i linkding
# Expected: no output
```

### Final success criteria verification

```bash
# SC-001: Zero firing alerts
curl -s http://localhost:9093/api/v2/alerts | jq '[.[] | select(.status.state == "active")] | length'
# Expected: 0

# SC-002: No pods in removed namespaces
for ns in linkding pihole; do
  echo -n "$ns: "
  kubectl get pods -n $ns 2>/dev/null || echo "namespace not found (clean)"
done

# SC-003: Orphaned files removed from Git
ls helm/linkding 2>/dev/null && echo "STILL EXISTS" || echo "Removed"
ls helm/dnsmasq 2>/dev/null && echo "STILL EXISTS" || echo "Removed"
ls argocd/infrastructure/linkding-db-secret.yaml 2>/dev/null && echo "STILL EXISTS" || echo "Removed"

# SC-004: All ArgoCD apps Synced + Healthy
kubectl get applications -n argocd --no-headers | awk '{print $1, $2, $3}' | grep -v "Synced.*Healthy" && echo "Some apps not healthy" || echo "All apps Synced + Healthy"

# SC-006: DNS works
kubectl run dns-test --image=busybox --restart=Never --rm -it -- nslookup kubernetes.default
```
