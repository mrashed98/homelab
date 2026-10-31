#!/usr/bin/env bash
# Seal IBG Studio's dashboard login and GHCR pull credentials into helm/ibg-studio/templates/.
# Inputs are hidden and never written unencrypted. Always targets the homelab cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${HOMELAB_KUBECONFIG:-$HOME/.kube/homelab-config}"
echo "Sealing for cluster: $(kubectl config current-context) ($KUBECONFIG)"
out=helm/ibg-studio/templates
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
seal() { kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller; }

read -rp  "Dashboard username: " user
[[ -n $user && $user != *:* ]] || { echo "Username must be non-empty and cannot contain ':'." >&2; exit 1; }
read -rsp "Dashboard password (hidden): " pass; echo
[[ ${#pass} -ge 12 ]] || { echo "Use at least 12 characters." >&2; exit 1; }
# bcrypt via stdin (-i): the password never appears in argv. Assigned first so set -e sees failures.
entry=$(htpasswd -niB "$user" <<<"$pass")
unset pass
printf '%s\n' "$entry" \
  | kubectl create secret generic ibg-studio-auth -n ibg-studio --from-file=users=/dev/stdin \
      --dry-run=client -o yaml | seal > "$tmp/auth-sealed.yaml"
unset entry

echo "GitHub token with read:packages (classic PAT): https://github.com/settings/tokens/new?scopes=read:packages"
read -rsp "GHCR token (hidden): " pat; echo
[[ -n $pat ]] || { echo "GHCR token is required." >&2; exit 1; }
# Built with shell builtins and pipes only: the token never appears in a process listing.
auth=$(printf '%s:%s' mrashed98 "$pat" | base64 | tr -d '\n')
unset pat
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$auth" \
  | kubectl create secret generic ghcr-pull -n ibg-studio --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml \
  | seal > "$tmp/ghcr-pull-sealed.yaml"
unset auth

# Replace the tracked manifests only after both seals succeeded.
mv "$tmp/auth-sealed.yaml" "$tmp/ghcr-pull-sealed.yaml" "$out/"
echo "Wrote $out/auth-sealed.yaml and $out/ghcr-pull-sealed.yaml (encrypted; safe to commit)."
