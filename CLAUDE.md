# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps-managed homelab running on a k3s Kubernetes cluster provisioned on Proxmox VMs. The full stack is:

1. **Terraform** → provisions VMs on Proxmox (`192.168.68.100`)
2. **Ansible** → installs k3s, formats disks, configures nodes
3. **ArgoCD** → continuously syncs Kubernetes state from this repo (GitOps)
4. **Helm charts** → defines application deployments

## Common Commands

### Terraform (infrastructure provisioning)
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

### Ansible (cluster bootstrap)
```bash
ansible-playbook ansible/k3s_setup.yaml -i ansible/inventory.ini
```

### kubectl (cluster management)
```bash
# Get kubeconfig from master node after Ansible setup
ssh ubuntu@192.168.68.150 "cat ~/.kube/config" > ~/.kube/homelab-config
export KUBECONFIG=~/.kube/homelab-config
```

### Sealed Secrets (encrypting secrets for Git)
```bash
# Encrypt a secret for a specific namespace
kubeseal --format yaml < secret.yaml > sealed-secret.yaml
```

### ArgoCD sync
ArgoCD auto-syncs on Git push. Manual sync via ArgoCD UI at `https://argo.local` or:
```bash
argocd app sync <app-name>
```

## Architecture

### Cluster Nodes
- Master: `192.168.68.150`
- Workers: `192.168.68.151`, `192.168.68.152`
- NFS server (Proxmox host): `192.168.68.100:/mnt/pve/BigData/k3s-shares`

### ArgoCD Bootstrap Pattern
`argocd/bootstrap/` contains two meta-applications:
- `apps-link.yaml` — watches `argocd/apps/` and auto-deploys all app definitions
- `infra-link.yaml` — watches `argocd/infrastructure/` and auto-deploys all infrastructure

All ArgoCD apps use `automated` sync with `prune: true` and `selfHeal: true`.

### Directory Layout
- `terraform/` — Proxmox VM provisioning
- `ansible/` — k3s cluster setup playbooks
- `helm/` — custom Helm charts for apps not available upstream (vaultwarden, homepage)
- `argocd/apps/` — ArgoCD Application manifests for user-facing apps
- `argocd/infrastructure/` — ArgoCD Application manifests for cluster infrastructure
- `argocd/secrets/` — Bitnami Sealed Secrets (safe to commit)
- `argocd/bootstrap/` — bootstrap meta-applications

### Storage Strategy
- **NFS (`nfs-hdd` StorageClass)**: Used for application data. NFS server at `192.168.68.100`.
- **local-path (k3s built-in)**: Used exclusively for databases (PostgreSQL, Redis) to avoid NFS file-locking issues with WAL files.

### TLS / Certificate Management
- cert-manager (`argocd/infrastructure/cert-manager.yaml`) issues certificates via `homelab-ca-issuer`
- The CA certificate is stored as a Sealed Secret in `argocd/secrets/ca-sealed-secret.yaml`
- All ingresses use `.local` hostnames with TLS; annotate with:
  ```yaml
  cert-manager.io/cluster-issuer: homelab-ca-issuer
  ```

### Adding a New Application
1. If upstream Helm chart exists: add an ArgoCD Application YAML to `argocd/apps/` referencing the chart repo directly.
2. If custom chart needed: create chart under `helm/<app-name>/`, then add ArgoCD Application YAML to `argocd/apps/` pointing to `path: helm/<app-name>`.
3. ArgoCD auto-detects and syncs on push.

### Infrastructure Dependencies (deployment order)
1. Sealed secrets controller (enables encrypted secrets)
2. NFS storage provisioner + local-path (storage)
3. PostgreSQL / Redis (databases)
4. cert-manager + ClusterIssuer (TLS)
5. Applications (depend on all above)

### Key Infrastructure Endpoints (internal)
- PostgreSQL: `postgres.databases.svc.cluster.local:5432`
- Redis: `redis-master.databases.svc.cluster.local:6379`
- ArgoCD UI: `https://argo.local`
- Homepage dashboard: `https://home.local`
- Vaultwarden: `https://vault.local`
- Pi-hole: `https://pihole.local`
