#!/usr/bin/env bash
# Run this once to create the two SealedSecrets needed by the Affine chart.
# Prerequisites: kubeseal must be configured against the cluster.
set -euo pipefail

AFFINE_DB_PASSWORD="${AFFINE_DB_PASSWORD:-}"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-}"

if [[ -z "$AFFINE_DB_PASSWORD" || -z "$POSTGRES_ADMIN_PASSWORD" ]]; then
  echo "Usage:"
  echo "  AFFINE_DB_PASSWORD=<choose-a-password> \\"
  echo "  POSTGRES_ADMIN_PASSWORD=<same-as-databases/postgres-admin-secret> \\"
  echo "  bash helm/affine/create-secrets.sh"
  exit 1
fi

# 1. affine-db-secret — affine user's own DB password
kubectl create secret generic affine-db-secret \
  --namespace affine \
  --from-literal=password="$AFFINE_DB_PASSWORD" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > helm/affine/templates/affine-db-sealed-secret.yaml

echo "Written: helm/affine/templates/affine-db-sealed-secret.yaml"

# 2. affine-postgres-admin-secret — postgres superuser (needed by the db-init Job)
#    Same password as databases/postgres-admin-secret but sealed for the affine namespace.
kubectl create secret generic affine-postgres-admin-secret \
  --namespace affine \
  --from-literal=postgres-password="$POSTGRES_ADMIN_PASSWORD" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > helm/affine/templates/affine-postgres-admin-sealed-secret.yaml

echo "Written: helm/affine/templates/affine-postgres-admin-sealed-secret.yaml"
echo ""
echo "Commit both files and push. ArgoCD will pick them up automatically."
