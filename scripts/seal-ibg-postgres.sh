#!/usr/bin/env bash
# Seal a fresh random password for IBG's own Postgres, plus the app's DATABASE_URL pointing at
# it. Nothing is typed or printed: the password exists only inside this process and the seals.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${HOMELAB_KUBECONFIG:-$HOME/.kube/homelab-config}"
echo "Sealing for cluster: $(kubectl config current-context) ($KUBECONFIG)"
out=helm/ibg-studio/templates
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
seal() { kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller; }
# Sync wave -1: both secrets must exist before the database and the app start.
wave() { awk '{print} !done && /^  namespace: ibg-studio$/ {print "  annotations:"; print "    argocd.argoproj.io/sync-wave: \"-1\""; done=1}'; }

# Postgres sets the password only when it initializes an empty volume. Resealing afterwards
# would hand the app a password the server never learned.
if kubectl -n ibg-studio get secret ibg-postgres >/dev/null 2>&1; then
  echo "ibg-postgres already exists. Rotate with ALTER ROLE inside the database first;" >&2
  echo "this script only creates the initial password." >&2
  exit 1
fi

pass=$(openssl rand -hex 24)   # hex: safe in a URL without escaping
printf '%s' "$pass" \
  | kubectl create secret generic ibg-postgres -n ibg-studio --from-file=POSTGRES_PASSWORD=/dev/stdin \
      --dry-run=client -o yaml | seal | wave > "$tmp/postgres-sealed.yaml"
printf 'postgresql://ibg_automator:%s@ibg-postgres:5432/ibg_automator' "$pass" \
  | kubectl create secret generic ibg-studio-db -n ibg-studio --from-file=DATABASE_URL=/dev/stdin \
      --dry-run=client -o yaml | seal | wave > "$tmp/db-sealed.yaml"
unset pass

mv "$tmp/postgres-sealed.yaml" "$tmp/db-sealed.yaml" "$out/"
echo "Wrote $out/postgres-sealed.yaml and $out/db-sealed.yaml (encrypted; safe to commit)."
