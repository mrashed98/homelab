<!--
SYNC IMPACT REPORT
==================
Version change: [TEMPLATE] → 1.0.0 (initial ratification — all content new)

Modified principles: N/A (first version)

Added sections:
  - Core Principles (I–V)
  - Application Deployment Standards
  - Infrastructure Bootstrap & Dependencies
  - Governance

Removed sections: N/A

Templates reviewed:
  - .specify/templates/plan-template.md      ✅ Constitution Check section is generic; no update needed
  - .specify/templates/spec-template.md      ✅ No principle-specific references; no update needed
  - .specify/templates/tasks-template.md     ✅ No principle-specific references; no update needed
  - .specify/templates/checklist-template.md ✅ No principle-specific references; no update needed
  - .specify/templates/agent-file-template.md ✅ No principle-specific references; no update needed

Deferred TODOs: None
-->

# Homelab Constitution

## Core Principles

### I. GitOps-First

All Kubernetes cluster state MUST be declared in this Git repository and reconciled
by ArgoCD. Direct `kubectl apply` or manual Helm installs that modify production state
are PROHIBITED. ArgoCD is the single source of truth; automated sync with `prune: true`
and `selfHeal: true` MUST remain enabled for all applications.

**Rationale**: Manual mutations create drift that is invisible in Git, making the cluster
unrecoverable-by-code and undermining the entire homelab purpose.

### II. Infrastructure as Code

All VMs and nodes MUST be provisioned via Terraform (`terraform/`). All OS-level and
cluster configuration MUST be applied via Ansible (`ansible/`). Snowflake configurations
and manual SSH-based changes to nodes are PROHIBITED unless diagnosing an active outage,
and any such changes MUST be codified back into Ansible immediately afterward.

**Rationale**: Repeatability is non-negotiable — the entire cluster must be rebuildable
from scratch using only the repo and Proxmox host access.

### III. Secret Safety (NON-NEGOTIABLE)

Plaintext credentials, tokens, passwords, and private keys MUST NEVER be committed to
this repository. All secrets MUST be encrypted with Bitnami Sealed Secrets via
`kubeseal` before committing to `argocd/secrets/`. Raw `Secret` manifests may only exist
transiently on the local filesystem during the sealing process and MUST NOT be staged
or committed.

**Rationale**: This is a Git-public-by-design repo pattern. A single leaked credential
invalidates the security posture of all hosted services.

### IV. Storage Discipline

Storage class assignment MUST follow this rule without exception:
- **`nfs-hdd`** (NFS at `192.168.68.100`): application data, media, config volumes.
- **`local-path`** (k3s built-in): databases only (PostgreSQL, Redis) to prevent
  NFS file-locking issues with WAL files and advisory locks.

Assigning a database `PersistentVolumeClaim` to `nfs-hdd` is a constitution violation
and MUST be caught in plan/review before merge.

**Rationale**: NFS does not provide POSIX advisory locking semantics required by
PostgreSQL and Redis; using it for databases causes silent data corruption under load.

### V. TLS Everywhere

All ingress resources MUST terminate TLS. Internal services MUST use cert-manager with
`homelab-ca-issuer` (self-signed CA). Public-facing services MUST use Let's Encrypt via
Cloudflare DNS-01 (`letsencrypt-cloudflare` issuer). Plaintext HTTP ingresses are
PROHIBITED; the annotation `cert-manager.io/cluster-issuer` MUST be present on every
ingress manifest.

**Rationale**: Even in a homelab, unencrypted traffic between services and the browser
exposes credentials (Vaultwarden, ArgoCD, Pi-hole admin) on the LAN.

## Application Deployment Standards

New application additions MUST follow this decision tree:

1. **Upstream Helm chart exists** → Add an ArgoCD `Application` YAML to `argocd/apps/`
   referencing the upstream chart repo directly. Do NOT copy chart sources locally.
2. **No upstream chart** → Create a minimal custom chart under `helm/<app-name>/`, then
   add an ArgoCD `Application` YAML to `argocd/apps/` pointing to `path: helm/<app-name>`.
3. Custom charts MUST NOT duplicate logic already provided by cluster infrastructure
   (cert-manager, sealed-secrets, NFS provisioner). Delegate to those systems instead.

All `Application` manifests MUST target the `automated` sync policy with `prune: true`
and `selfHeal: true`. Manual sync policies require written justification in the manifest
as a comment.

All services MUST use `.local` hostnames. Hostname format: `<service>.local`.

## Infrastructure Bootstrap & Dependencies

When rebuilding or extending the cluster, components MUST be deployed in this order to
satisfy runtime dependencies:

1. **Sealed Secrets controller** — enables encrypted secret consumption by all apps.
2. **NFS storage provisioner + `local-path`** — satisfies `PersistentVolumeClaim` binding
   for all subsequent deployments.
3. **PostgreSQL / Redis** — database tier consumed by stateful applications.
4. **cert-manager + `ClusterIssuer`** — required before any ingress with TLS annotation.
5. **Applications** — depend on all of the above.

Deploying an application before its layer dependencies are `Ready` MUST be treated as
a known failure mode, not a bug in the application chart.

## Governance

This constitution supersedes all informal conventions and undocumented practices. When
a conflict exists between this document and any other file in the repository (except
`CLAUDE.md`, which provides AI-assistant guidance), this constitution takes precedence.

**Amendment procedure**:
- Amendments MUST be committed as a dedicated Git commit updating this file.
- `CONSTITUTION_VERSION` MUST be incremented following semantic versioning:
  - MAJOR: backward-incompatible governance changes or principle removals.
  - MINOR: new principle or section added, or materially expanded guidance.
  - PATCH: clarifications, wording, or non-semantic refinements.
- `LAST_AMENDED_DATE` MUST be updated to the date of the amending commit (ISO 8601).

**Compliance review**:
- Every new `argocd/apps/` or `helm/` addition MUST be reviewed against Principles I–V
  before merge, using the Constitution Check section in `plan.md` as a gate.
- Any plan that violates a principle MUST document the violation and justification in
  the `Complexity Tracking` table of `plan.md` before proceeding.

**Version**: 1.0.0 | **Ratified**: 2026-03-12 | **Last Amended**: 2026-03-12
