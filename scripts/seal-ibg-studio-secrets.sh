#!/usr/bin/env bash
# Seal IBG Studio's dashboard login and GHCR pull credentials into helm/ibg-studio/templates/.
# Inputs are hidden and never written unencrypted. Always targets the homelab cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${HOMELAB_KUBECONFIG:-$HOME/.kube/homelab-config}"
echo "Sealing for cluster: $(kubectl config current-context) ($KUBECONFIG)"
seal() { kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller; }

read -rp  "Dashboard username: " user
read -rsp "Dashboard password (hidden): " pass; echo
[[ ${#pass} -ge 12 ]] || { echo "Use at least 12 characters." >&2; exit 1; }
# Traefik basicAuth accepts apr1 (htpasswd -m) hashes.
printf '%s:%s\n' "$user" "$(openssl passwd -apr1 -stdin <<<"$pass")" \
  | kubectl create secret generic ibg-studio-auth -n ibg-studio --from-file=users=/dev/stdin \
      --dry-run=client -o yaml | seal > helm/ibg-studio/templates/auth-sealed.yaml
unset pass

echo "GitHub token with read:packages (classic PAT): https://github.com/settings/tokens/new?scopes=read:packages"
read -rsp "GHCR token (hidden): " pat; echo
kubectl create secret docker-registry ghcr-pull -n ibg-studio --docker-server=ghcr.io \
    --docker-username=mrashed98 --docker-password="$pat" --dry-run=client -o yaml \
  | seal > helm/ibg-studio/templates/ghcr-pull-sealed.yaml
unset pat
echo "Wrote auth-sealed.yaml and ghcr-pull-sealed.yaml (encrypted; safe to commit)."
