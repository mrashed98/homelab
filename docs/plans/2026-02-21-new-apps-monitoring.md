# New Applications + Cluster Monitoring Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add pgAdmin, CommaFeed, Linkding, Wallabag, Transmission, and full cluster monitoring (Prometheus + Grafana) to the homelab k3s cluster via ArgoCD GitOps.

**Architecture:** Phase 1 deploys `kube-prometheus-stack` as infrastructure so Grafana is available during rollout. Phase 2 creates all sealed secrets and PostgreSQL databases. Phase 3 deploys the five user-facing applications. Phase 4 adds Pi-hole metrics scraping. All services follow the established Traefik + cert-manager + `.local` TLS pattern.

**Tech Stack:** ArgoCD GitOps, Helm (upstream + custom charts), Bitnami Sealed Secrets, cert-manager, Traefik ingress, NFS (`storageClassName: manual` for specific paths, `nfs-hdd` for auto-provisioned), local-path for Grafana/Prometheus.

---

## Conventions (read before starting)

**Ingress pattern** — every ingress in this repo uses:
```yaml
annotations:
  cert-manager.io/cluster-issuer: homelab-ca-issuer
  traefik.ingress.kubernetes.io/router.entrypoints: websecure
  traefik.ingress.kubernetes.io/router.tls: "true"
ingressClassName: traefik
```

**NFS direct-mount PV pattern** (`storageClassName: manual`, `ReadWriteMany`) — used when you need a specific known path on `192.168.68.100`. See `helm/vaultwarden/templates/pvc.yaml` for reference.

**Upstream chart ArgoCD app** — source is the chart's helm repo URL. See `argocd/infrastructure/postgres.yaml` for reference.

**Custom chart ArgoCD app** — source is this git repo with `path: helm/<name>`. See `argocd/apps/vaultwarden.yaml` for reference.

**Sealed secrets** — always create with:
```bash
kubectl create secret generic <name> --namespace <ns> \
  --from-literal=key=value \
  --dry-run=client -o yaml | kubeseal --format yaml > argocd/secrets/<name>.yaml
```

---

## Phase 1: Monitoring Stack

### Task 1: Deploy kube-prometheus-stack

**Files:**
- Create: `argocd/secrets/grafana-admin-secret.yaml`
- Create: `argocd/infrastructure/monitoring.yaml`

**Step 1: Find the current chart version**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm search repo prometheus-community/kube-prometheus-stack | head -3
```

Note the VERSION column. Use it for `<CHART_VERSION>` below.

**Step 2: Create the Grafana admin sealed secret**

```bash
kubectl create secret generic grafana-admin-secret \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<CHOOSE_A_STRONG_PASSWORD>' \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argocd/secrets/grafana-admin-secret.yaml
```

**Step 3: Create `argocd/infrastructure/monitoring.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: "<CHART_VERSION>"
    helm:
      values: |
        fullnameOverride: prometheus

        prometheus:
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              cert-manager.io/cluster-issuer: homelab-ca-issuer
              traefik.ingress.kubernetes.io/router.entrypoints: websecure
              traefik.ingress.kubernetes.io/router.tls: "true"
            hosts:
              - prometheus.local
            tls:
              - secretName: prometheus-tls
                hosts:
                  - prometheus.local
          prometheusSpec:
            retention: 15d
            storageSpec:
              volumeClaimTemplate:
                spec:
                  storageClassName: local-path
                  accessModes: ["ReadWriteOnce"]
                  resources:
                    requests:
                      storage: 20Gi

        grafana:
          ingress:
            enabled: true
            ingressClassName: traefik
            annotations:
              cert-manager.io/cluster-issuer: homelab-ca-issuer
              traefik.ingress.kubernetes.io/router.entrypoints: websecure
              traefik.ingress.kubernetes.io/router.tls: "true"
            hosts:
              - grafana.local
            tls:
              - secretName: grafana-tls
                hosts:
                  - grafana.local
          admin:
            existingSecret: grafana-admin-secret
            userKey: admin-user
            passwordKey: admin-password
          persistence:
            enabled: true
            storageClassName: local-path
            size: 10Gi

        alertmanager:
          alertmanagerSpec:
            storage:
              volumeClaimTemplate:
                spec:
                  storageClassName: local-path
                  accessModes: ["ReadWriteOnce"]
                  resources:
                    requests:
                      storage: 2Gi

        nodeExporter:
          enabled: true

        kubeStateMetrics:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 4: Commit and push**

```bash
git add argocd/secrets/grafana-admin-secret.yaml argocd/infrastructure/monitoring.yaml
git commit -m "feat: add kube-prometheus-stack monitoring infrastructure"
git push
```

**Step 5: Verify**

```bash
kubectl get pods -n monitoring -w
# Wait ~5 minutes for all pods (prometheus, grafana, alertmanager, node-exporter x3, kube-state-metrics)
kubectl get ingress -n monitoring
# Visit https://grafana.local — log in with admin / <password from Step 2>
# Visit https://prometheus.local — Status → Targets, all should be UP
```

---

## Phase 2: Secrets and Database Setup

### Task 2: Create PostgreSQL databases

**Step 1: Connect to the PostgreSQL pod**

```bash
kubectl exec -it -n databases deploy/postgres -- psql -U postgres
```

**Step 2: Create databases and users**

```sql
CREATE USER commafeed WITH PASSWORD '<COMMAFEED_DB_PASSWORD>';
CREATE DATABASE commafeed OWNER commafeed;

CREATE USER linkding WITH PASSWORD '<LINKDING_DB_PASSWORD>';
CREATE DATABASE linkding OWNER linkding;

CREATE USER wallabag WITH PASSWORD '<WALLABAG_DB_PASSWORD>';
CREATE DATABASE wallabag OWNER wallabag;

\q
```

Record these passwords — you will need them in Task 3.

**Step 3: Verify**

```bash
kubectl exec -it -n databases deploy/postgres -- psql -U postgres -c "\l"
# Should list: commafeed, linkding, wallabag databases
```

---

### Task 3: Create all application sealed secrets

**Files:**
- Create: `argocd/secrets/pgadmin-secret.yaml`
- Create: `argocd/secrets/commafeed-db-secret.yaml`
- Create: `argocd/secrets/linkding-db-secret.yaml`
- Create: `argocd/secrets/wallabag-db-secret.yaml`

**Step 1: pgAdmin admin credentials**

```bash
kubectl create secret generic pgadmin-secret \
  --namespace pgadmin \
  --from-literal=password='<PGADMIN_ADMIN_PASSWORD>' \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argocd/secrets/pgadmin-secret.yaml
```

Note: the pgAdmin admin email is set via chart values (not secret) — use `admin@homelab.local`.

**Step 2: CommaFeed database password**

```bash
kubectl create secret generic commafeed-db-secret \
  --namespace commafeed \
  --from-literal=DB_PASSWORD='<COMMAFEED_DB_PASSWORD>' \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argocd/secrets/commafeed-db-secret.yaml
```

**Step 3: Linkding database password + initial superuser password**

```bash
kubectl create secret generic linkding-db-secret \
  --namespace linkding \
  --from-literal=DB_PASSWORD='<LINKDING_DB_PASSWORD>' \
  --from-literal=LD_SUPERUSER_PASSWORD='<LINKDING_ADMIN_UI_PASSWORD>' \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argocd/secrets/linkding-db-secret.yaml
```

**Step 4: Wallabag database password + Symfony app secret**

```bash
WALLABAG_APP_SECRET=$(openssl rand -hex 32)
kubectl create secret generic wallabag-db-secret \
  --namespace wallabag \
  --from-literal=DB_PASSWORD='<WALLABAG_DB_PASSWORD>' \
  --from-literal=APP_SECRET="$WALLABAG_APP_SECRET" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argocd/secrets/wallabag-db-secret.yaml
```

**Step 5: Commit all secrets**

```bash
git add argocd/secrets/pgadmin-secret.yaml \
        argocd/secrets/commafeed-db-secret.yaml \
        argocd/secrets/linkding-db-secret.yaml \
        argocd/secrets/wallabag-db-secret.yaml
git commit -m "feat: add sealed secrets for new application credentials"
git push
```

---

## Phase 3: User Applications

### Task 4: Deploy pgAdmin

**Files:**
- Create: `argocd/apps/pgadmin.yaml`

pgAdmin uses an upstream Helm chart (`runix/pgadmin4`). No custom chart needed.

**Step 1: Find current chart version**

```bash
helm repo add runix https://helm.runix.net
helm repo update
helm search repo runix/pgadmin4 | head -3
```

Note the VERSION column. Use it for `<CHART_VERSION>` below.

**Step 2: Create `argocd/apps/pgadmin.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pgadmin
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://helm.runix.net
    chart: pgadmin4
    targetRevision: "<CHART_VERSION>"
    helm:
      values: |
        env:
          email: admin@homelab.local

        existingSecret: pgadmin-secret
        secretKeys:
          pgadminPasswordKey: password

        ingress:
          enabled: true
          ingressClassName: traefik
          annotations:
            cert-manager.io/cluster-issuer: homelab-ca-issuer
            traefik.ingress.kubernetes.io/router.entrypoints: websecure
            traefik.ingress.kubernetes.io/router.tls: "true"
          hosts:
            - host: pgadmin.local
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - secretName: pgadmin-tls
              hosts:
                - pgadmin.local

        persistentVolume:
          enabled: true
          storageClass: nfs-hdd
          size: 1Gi

        resources:
          requests:
            memory: 256Mi
            cpu: 100m
          limits:
            memory: 512Mi
            cpu: 500m
  destination:
    server: https://kubernetes.default.svc
    namespace: pgadmin
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 3: Commit and push**

```bash
git add argocd/apps/pgadmin.yaml
git commit -m "feat: add pgAdmin application"
git push
```

**Step 4: Verify**

```bash
kubectl get pods -n pgadmin -w
kubectl get ingress -n pgadmin
# Visit https://pgadmin.local — log in with admin@homelab.local / <PGADMIN_ADMIN_PASSWORD>
# Add server: Host=postgres.databases.svc.cluster.local, Port=5432, User=postgres
```

---

### Task 5: Deploy CommaFeed (RSS reader)

**Files:**
- Create: `helm/commafeed/Chart.yaml`
- Create: `helm/commafeed/values.yaml`
- Create: `helm/commafeed/templates/deployment.yaml`
- Create: `helm/commafeed/templates/service.yaml`
- Create: `helm/commafeed/templates/ingress.yaml`
- Create: `argocd/apps/commafeed.yaml`

CommaFeed is a Java/Quarkus app. It is fully database-backed — no persistent volume needed.

**Step 1: Create `helm/commafeed/Chart.yaml`**

```yaml
apiVersion: v2
name: commafeed
description: CommaFeed RSS reader
type: application
version: 0.1.0
appVersion: "latest"
```

**Step 2: Create `helm/commafeed/values.yaml`**

```yaml
image:
  repository: athou/commafeed
  tag: latest
  pullPolicy: IfNotPresent

replicaCount: 1

service:
  type: ClusterIP
  port: 8082

ingress:
  host: feed.local

db:
  host: postgres.databases.svc.cluster.local
  port: "5432"
  name: commafeed
  user: commafeed

existingSecret: commafeed-db-secret

resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 500m
```

**Step 3: Create `helm/commafeed/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: commafeed
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 8082
          env:
            - name: QUARKUS_DATASOURCE_DB_KIND
              value: postgresql
            - name: QUARKUS_DATASOURCE_USERNAME
              value: {{ .Values.db.user }}
            - name: QUARKUS_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret }}
                  key: DB_PASSWORD
            - name: QUARKUS_DATASOURCE_JDBC_URL
              value: "jdbc:postgresql://{{ .Values.db.host }}:{{ .Values.db.port }}/{{ .Values.db.name }}"
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

**Step 4: Create `helm/commafeed/templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 8082
      name: http
```

**Step 5: Create `helm/commafeed/templates/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - {{ .Values.ingress.host }}
      secretName: commafeed-tls
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: {{ .Values.service.port }}
```

**Step 6: Create `argocd/apps/commafeed.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: commafeed
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mrashed98/homelab.git
    targetRevision: master
    path: helm/commafeed
  destination:
    server: https://kubernetes.default.svc
    namespace: commafeed
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 7: Commit and push**

```bash
git add helm/commafeed/ argocd/apps/commafeed.yaml
git commit -m "feat: add CommaFeed RSS reader"
git push
```

**Step 8: Verify**

```bash
kubectl get pods -n commafeed -w
kubectl get ingress -n commafeed
# Visit https://feed.local — default credentials: admin / admin (change on first login)
```

---

### Task 6: Deploy Linkding (bookmark manager)

**Files:**
- Create: `helm/linkding/Chart.yaml`
- Create: `helm/linkding/values.yaml`
- Create: `helm/linkding/templates/deployment.yaml`
- Create: `helm/linkding/templates/service.yaml`
- Create: `helm/linkding/templates/ingress.yaml`
- Create: `argocd/apps/linkding.yaml`

Linkding is a Python/Django app. Fully database-backed — no persistent volume needed.

**Step 1: Create `helm/linkding/Chart.yaml`**

```yaml
apiVersion: v2
name: linkding
description: Linkding bookmark manager
type: application
version: 0.1.0
appVersion: "latest"
```

**Step 2: Create `helm/linkding/values.yaml`**

```yaml
image:
  repository: sissbruecker/linkding
  tag: latest
  pullPolicy: IfNotPresent

replicaCount: 1

service:
  type: ClusterIP
  port: 9090

ingress:
  host: links.local

db:
  host: postgres.databases.svc.cluster.local
  port: "5432"
  name: linkding
  user: linkding

superuser:
  name: admin

existingSecret: linkding-db-secret

resources:
  requests:
    memory: 256Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
```

**Step 3: Create `helm/linkding/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: linkding
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 9090
          env:
            - name: LD_DB_ENGINE
              value: django.db.backends.postgresql
            - name: LD_DB_HOST
              value: {{ .Values.db.host }}
            - name: LD_DB_PORT
              value: "{{ .Values.db.port }}"
            - name: LD_DB_DATABASE
              value: {{ .Values.db.name }}
            - name: LD_DB_USER
              value: {{ .Values.db.user }}
            - name: LD_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret }}
                  key: DB_PASSWORD
            - name: LD_SUPERUSER_NAME
              value: {{ .Values.superuser.name }}
            - name: LD_SUPERUSER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret }}
                  key: LD_SUPERUSER_PASSWORD
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

**Step 4: Create `helm/linkding/templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 9090
      name: http
```

**Step 5: Create `helm/linkding/templates/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - {{ .Values.ingress.host }}
      secretName: linkding-tls
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: {{ .Values.service.port }}
```

**Step 6: Create `argocd/apps/linkding.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: linkding
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mrashed98/homelab.git
    targetRevision: master
    path: helm/linkding
  destination:
    server: https://kubernetes.default.svc
    namespace: linkding
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 7: Commit and push**

```bash
git add helm/linkding/ argocd/apps/linkding.yaml
git commit -m "feat: add Linkding bookmark manager"
git push
```

**Step 8: Verify**

```bash
kubectl get pods -n linkding -w
kubectl get ingress -n linkding
# Visit https://links.local — log in with admin / <LD_SUPERUSER_PASSWORD from sealed secret>
```

---

### Task 7: Deploy Wallabag (read-it-later)

**Files:**
- Create: `helm/wallabag/Chart.yaml`
- Create: `helm/wallabag/values.yaml`
- Create: `helm/wallabag/templates/pvc.yaml`
- Create: `helm/wallabag/templates/deployment.yaml`
- Create: `helm/wallabag/templates/service.yaml`
- Create: `helm/wallabag/templates/ingress.yaml`
- Create: `argocd/apps/wallabag.yaml`

Wallabag is a PHP/Symfony app. Uses PostgreSQL for data, Redis (existing cluster Redis) for sessions, and NFS for article assets/images.

**Step 1: Create the NFS directory on the Proxmox host**

```bash
ssh ubuntu@192.168.68.100 \
  "sudo mkdir -p /mnt/pve/BigData/k3s-shares/wallabag && sudo chmod 777 /mnt/pve/BigData/k3s-shares/wallabag"
```

**Step 2: Create `helm/wallabag/Chart.yaml`**

```yaml
apiVersion: v2
name: wallabag
description: Wallabag read-it-later app
type: application
version: 0.1.0
appVersion: "latest"
```

**Step 3: Create `helm/wallabag/values.yaml`**

```yaml
image:
  repository: wallabag/wallabag
  tag: latest
  pullPolicy: IfNotPresent

replicaCount: 1

service:
  type: ClusterIP
  port: 80

ingress:
  host: read.local

db:
  host: postgres.databases.svc.cluster.local
  port: "5432"
  name: wallabag
  user: wallabag

redis:
  host: redis-master.databases.svc.cluster.local
  port: "6379"

existingSecret: wallabag-db-secret

persistence:
  size: 5Gi
  nfs:
    server: 192.168.68.100
    path: /mnt/pve/BigData/k3s-shares/wallabag

resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 500m
```

**Step 4: Create `helm/wallabag/templates/pvc.yaml`**

Follow the same pattern as `helm/vaultwarden/templates/pvc.yaml` (storageClassName: manual, ReadWriteMany):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .Release.Name }}-data
spec:
  capacity:
    storage: {{ .Values.persistence.size }}
  accessModes:
    - ReadWriteMany
  nfs:
    server: {{ .Values.persistence.nfs.server }}
    path: {{ .Values.persistence.nfs.path }}
  storageClassName: manual
  persistentVolumeReclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Release.Name }}-data
  namespace: {{ .Release.Namespace }}
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
  volumeName: {{ .Release.Name }}-data
  storageClassName: manual
```

**Step 5: Create `helm/wallabag/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: wallabag
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 80
          env:
            - name: POPULATE_DATABASE
              value: "true"
            - name: SYMFONY__ENV__DATABASE_DRIVER
              value: pdo_pgsql
            - name: SYMFONY__ENV__DATABASE_HOST
              value: {{ .Values.db.host }}
            - name: SYMFONY__ENV__DATABASE_PORT
              value: "{{ .Values.db.port }}"
            - name: SYMFONY__ENV__DATABASE_NAME
              value: {{ .Values.db.name }}
            - name: SYMFONY__ENV__DATABASE_USER
              value: {{ .Values.db.user }}
            - name: SYMFONY__ENV__DATABASE_TABLE_PREFIX
              value: "wallabag_"
            - name: SYMFONY__ENV__DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret }}
                  key: DB_PASSWORD
            - name: SYMFONY__ENV__SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret }}
                  key: APP_SECRET
            - name: SYMFONY__ENV__REDIS_SCHEME
              value: tcp
            - name: SYMFONY__ENV__REDIS_HOST
              value: {{ .Values.redis.host }}
            - name: SYMFONY__ENV__REDIS_PORT
              value: "{{ .Values.redis.port }}"
            - name: SYMFONY__ENV__DOMAIN_NAME
              value: "https://{{ .Values.ingress.host }}"
          volumeMounts:
            - name: data
              mountPath: /var/www/wallabag/web/assets
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ .Release.Name }}-data
```

**Step 6: Create `helm/wallabag/templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 80
      name: http
```

**Step 7: Create `helm/wallabag/templates/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - {{ .Values.ingress.host }}
      secretName: wallabag-tls
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: {{ .Values.service.port }}
```

**Step 8: Create `argocd/apps/wallabag.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wallabag
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mrashed98/homelab.git
    targetRevision: master
    path: helm/wallabag
  destination:
    server: https://kubernetes.default.svc
    namespace: wallabag
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 9: Commit and push**

```bash
git add helm/wallabag/ argocd/apps/wallabag.yaml
git commit -m "feat: add Wallabag read-it-later app"
git push
```

**Step 10: Verify**

```bash
kubectl get pods -n wallabag -w
# First boot: ~2 minutes for DB migration (POPULATE_DATABASE=true runs Symfony migrations)
kubectl get ingress -n wallabag
# Visit https://read.local — default credentials: wallabag / wallabag (change immediately)
```

---

### Task 8: Deploy Transmission (BitTorrent client)

**Files:**
- Create: `helm/transmission/Chart.yaml`
- Create: `helm/transmission/values.yaml`
- Create: `helm/transmission/templates/pvc.yaml`
- Create: `helm/transmission/templates/deployment.yaml`
- Create: `helm/transmission/templates/service.yaml`
- Create: `helm/transmission/templates/ingress.yaml`
- Create: `argocd/apps/transmission.yaml`

Uses `linuxserver/transmission` image. Two volumes: config (auto-provisioned via `nfs-hdd`), downloads (manual NFS PV at a specific path).

**Step 1: Create the NFS downloads directory on the Proxmox host**

```bash
ssh ubuntu@192.168.68.100 \
  "sudo mkdir -p /mnt/pve/BigData/k3s-shares/transmission && sudo chmod 777 /mnt/pve/BigData/k3s-shares/transmission"
```

**Step 2: Create `helm/transmission/Chart.yaml`**

```yaml
apiVersion: v2
name: transmission
description: Transmission BitTorrent client (linuxserver image)
type: application
version: 0.1.0
appVersion: "latest"
```

**Step 3: Create `helm/transmission/values.yaml`**

```yaml
image:
  repository: linuxserver/transmission
  tag: latest
  pullPolicy: IfNotPresent

replicaCount: 1

service:
  type: ClusterIP
  port: 9091

ingress:
  host: torrent.local

env:
  PUID: "1000"
  PGID: "1000"
  TZ: UTC

persistence:
  config:
    storageClass: nfs-hdd
    size: 1Gi
  downloads:
    size: 500Gi
    nfs:
      server: 192.168.68.100
      path: /mnt/pve/BigData/k3s-shares/transmission

resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 512Mi
    cpu: 500m
```

**Step 4: Create `helm/transmission/templates/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: transmission-downloads
spec:
  capacity:
    storage: {{ .Values.persistence.downloads.size }}
  accessModes:
    - ReadWriteMany
  nfs:
    server: {{ .Values.persistence.downloads.nfs.server }}
    path: {{ .Values.persistence.downloads.nfs.path }}
  storageClassName: manual
  persistentVolumeReclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: transmission-downloads
  namespace: {{ .Release.Namespace }}
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
  resources:
    requests:
      storage: {{ .Values.persistence.downloads.size }}
  volumeName: transmission-downloads
  storageClassName: manual
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: transmission-config
  namespace: {{ .Release.Namespace }}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .Values.persistence.config.storageClass }}
  resources:
    requests:
      storage: {{ .Values.persistence.config.size }}
```

**Step 5: Create `helm/transmission/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: transmission
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: webui
              containerPort: 9091
            - name: peer-tcp
              containerPort: 51413
              protocol: TCP
            - name: peer-udp
              containerPort: 51413
              protocol: UDP
          env:
            - name: PUID
              value: "{{ .Values.env.PUID }}"
            - name: PGID
              value: "{{ .Values.env.PGID }}"
            - name: TZ
              value: {{ .Values.env.TZ }}
          volumeMounts:
            - name: config
              mountPath: /config
            - name: downloads
              mountPath: /downloads
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: transmission-config
        - name: downloads
          persistentVolumeClaim:
            claimName: transmission-downloads
```

**Step 6: Create `helm/transmission/templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 9091
      name: webui
```

**Step 7: Create `helm/transmission/templates/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Release.Name }}
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - {{ .Values.ingress.host }}
      secretName: transmission-tls
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: {{ .Values.service.port }}
```

**Step 8: Create `argocd/apps/transmission.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: transmission
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mrashed98/homelab.git
    targetRevision: master
    path: helm/transmission
  destination:
    server: https://kubernetes.default.svc
    namespace: downloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 9: Commit and push**

```bash
git add helm/transmission/ argocd/apps/transmission.yaml
git commit -m "feat: add Transmission BitTorrent client"
git push
```

**Step 10: Verify**

```bash
kubectl get pods -n downloads -w
kubectl get ingress -n downloads
# Visit https://torrent.local — no authentication by default (add via Settings > Remote)
```

---

## Phase 4: Pi-hole Metrics

### Task 9: Add Pi-hole exporter for Prometheus

**Files:**
- Create: `helm/pihole-exporter/Chart.yaml`
- Create: `helm/pihole-exporter/templates/deployment.yaml`
- Create: `helm/pihole-exporter/templates/service.yaml`
- Create: `helm/pihole-exporter/templates/servicemonitor.yaml`
- Create: `argocd/infrastructure/pihole-exporter.yaml`

The `ekofr/pihole-exporter` image scrapes the Pi-hole API and exposes metrics for Prometheus. A `ServiceMonitor` (kube-prometheus-stack CRD) tells Prometheus to scrape it automatically.

**Step 1: Create `helm/pihole-exporter/Chart.yaml`**

```yaml
apiVersion: v2
name: pihole-exporter
description: Prometheus exporter for Pi-hole DNS metrics
type: application
version: 0.1.0
appVersion: "latest"
```

**Step 2: Create `helm/pihole-exporter/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pihole-exporter
  namespace: {{ .Release.Namespace }}
  labels:
    app: pihole-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pihole-exporter
  template:
    metadata:
      labels:
        app: pihole-exporter
    spec:
      containers:
        - name: pihole-exporter
          image: ekofr/pihole-exporter:latest
          ports:
            - containerPort: 9617
              name: metrics
          env:
            - name: PIHOLE_HOSTNAME
              value: pihole-web.pihole.svc.cluster.local
            - name: PIHOLE_PORT
              value: "80"
            - name: PIHOLE_PASSWORD
              value: "01cd01e1"
            - name: PORT
              value: "9617"
          resources:
            requests:
              memory: 64Mi
              cpu: 50m
            limits:
              memory: 128Mi
              cpu: 100m
```

**Step 3: Create `helm/pihole-exporter/templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pihole-exporter
  namespace: {{ .Release.Namespace }}
  labels:
    app: pihole-exporter
spec:
  selector:
    app: pihole-exporter
  ports:
    - name: metrics
      port: 9617
      targetPort: 9617
```

**Step 4: Create `helm/pihole-exporter/templates/servicemonitor.yaml`**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: pihole-exporter
  namespace: {{ .Release.Namespace }}
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: pihole-exporter
  endpoints:
    - port: metrics
      interval: 30s
```

**Step 5: Create `argocd/infrastructure/pihole-exporter.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pihole-exporter
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mrashed98/homelab.git
    targetRevision: master
    path: helm/pihole-exporter
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 6: Commit and push**

```bash
git add helm/pihole-exporter/ argocd/infrastructure/pihole-exporter.yaml
git commit -m "feat: add Pi-hole Prometheus exporter"
git push
```

**Step 7: Verify**

```bash
kubectl get pods -n monitoring -l app=pihole-exporter
# In Grafana: Explore → run query: pihole_domains_being_blocked
# Should return a value (the number of domains Pi-hole is blocking)
# Prometheus UI: Status → Targets → find pihole-exporter, should be UP
```

---

## Summary: New Endpoints

| Service | URL | Default Credentials |
|---|---|---|
| Grafana | https://grafana.local | admin / (from sealed secret) |
| Prometheus | https://prometheus.local | none |
| pgAdmin | https://pgadmin.local | admin@homelab.local / (from sealed secret) |
| CommaFeed | https://feed.local | admin / admin |
| Linkding | https://links.local | admin / (from sealed secret) |
| Wallabag | https://read.local | wallabag / wallabag |
| Transmission | https://torrent.local | none (add via Settings) |
