# MetalLB + Pi-hole DNS Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Install MetalLB to give Pi-hole a stable LAN IP (192.168.68.200) so router DHCP can reliably point to it for DNS.

**Architecture:** MetalLB runs in L2 mode and assigns 192.168.68.200 to Pi-hole's DNS LoadBalancer service. Pi-hole no longer uses hostNetwork (which conflicted with systemd-resolved on all nodes). The router DHCP primary DNS is set to 192.168.68.200.

**Tech Stack:** MetalLB v0.14.9 (helm chart), ArgoCD GitOps, Pi-hole helm chart v2.26.0

---

### Task 1: Add MetalLB ArgoCD Application

**Files:**
- Create: `argocd/infrastructure/metallb.yaml`

**Step 1: Create the MetalLB ArgoCD app**

```yaml
# argocd/infrastructure/metallb.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://metallb.github.io/metallb
    chart: metallb
    targetRevision: 0.14.9
    helm:
      values: |
        controller:
          tolerations: []
        speaker:
          tolerations: []
        crds:
          enabled: true
        extraObjects:
          - apiVersion: metallb.io/v1beta1
            kind: IPAddressPool
            metadata:
              name: homelab-pool
              namespace: metallb-system
            spec:
              addresses:
                - 192.168.68.200-192.168.68.210
          - apiVersion: metallb.io/v1beta1
            kind: L2Advertisement
            metadata:
              name: homelab-l2
              namespace: metallb-system
            spec:
              ipAddressPools:
                - homelab-pool
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Verify file was created correctly**

```bash
cat argocd/infrastructure/metallb.yaml
```

Expected: file matches above YAML with no indentation errors.

**Step 3: Commit**

```bash
git add argocd/infrastructure/metallb.yaml
git commit -m "feat: add MetalLB with L2 IP pool 192.168.68.200-210"
```

---

### Task 2: Update Pi-hole to Use LoadBalancer DNS Service

**Files:**
- Modify: `argocd/infrastructure/pihole.yaml`

**Step 1: Remove hostNetwork and fix serviceDns**

Replace the Pi-hole helm values block. Key changes:
- Remove `hostNetwork: "true"`
- Remove `dnsPolicy: ClusterFirstWithHostNet`
- Change `serviceDns.type` from `ClusterIP` to `LoadBalancer`
- Add `serviceDns.loadBalancerIP: 192.168.68.200` to pin the IP

Updated `argocd/infrastructure/pihole.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pihole
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://mojo2600.github.io/pihole-kubernetes/
    chart: pihole
    targetRevision: 2.26.0
    helm:
      values: |
        replicaCount: 1
        image:
          repository: pihole/pihole
          tag: latest
          pullPolicy: IfNotPresent

        serviceDns:
          type: LoadBalancer
          loadBalancerIP: 192.168.68.200
          port: 53
        serviceWeb:
          type: ClusterIP
          http:
            enabled: true
            port: 80
          https:
            enabled: false
        ingress:
          enabled: true
          ingressClassName: traefik
          annotations:
            cert-manager.io/cluster-issuer: homelab-ca-issuer
            traefik.ingress.kubernetes.io/router.entrypoints: websecure
            traefik.ingress.kubernetes.io/router.tls: "true"
          hosts:
            - pihole.local
          tls:
            - secretName: pihole-tls
              hosts:
                - pihole.local
        admin:
          password: 01cd01e1
        DNSservers:
          - 8.8.8.8
          - 8.8.4.4
        extraEnvVars:
          TZ: UTC
        dnsmasq:
          customDnsEntries:
            - address=/local/192.168.68.150
        persistentVolumeClaim:
          enabled: true
          storageClassName: nfs-hdd
          accessModes:
            - ReadWriteOnce
          size: 1Gi
        resources:
          requests:
            memory: 256Mi
            cpu: 250m
          limits:
            memory: 512Mi
            cpu: 500m
        probes:
          liveness:
            enabled: false
          readiness:
            enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: pihole
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add argocd/infrastructure/pihole.yaml
git commit -m "fix: remove hostNetwork, use MetalLB LoadBalancer for Pi-hole DNS at 192.168.68.200"
```

---

### Task 3: Push and Verify ArgoCD Sync

**Step 1: Push to remote**

```bash
git push
```

**Step 2: Watch MetalLB deploy (allow 2-3 minutes)**

```bash
kubectl get pods -n metallb-system -w
```

Expected: `controller` and `speaker` pods reach `Running` state.

**Step 3: Watch Pi-hole redeploy**

```bash
kubectl get pods -n pihole -w
```

Expected: pod transitions from `Pending` → `ContainerCreating` → `Running`.

**Step 4: Verify Pi-hole DNS service got 192.168.68.200**

```bash
kubectl get svc -n pihole
```

Expected: a service of type `LoadBalancer` with `EXTERNAL-IP: 192.168.68.200`.

**Step 5: Test DNS resolution from your machine**

```bash
dig @192.168.68.200 google.com
```

Expected: returns A records with NOERROR status.

**Step 6: Set router DHCP primary DNS to 192.168.68.200**

After confirming dig works, update your router's DHCP primary DNS to `192.168.68.200`. Devices will pick up the new DNS on next DHCP lease renewal (or reconnect).
