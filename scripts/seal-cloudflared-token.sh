#!/usr/bin/env bash
# Seal the Cloudflare Tunnel token into the cloudflared chart without echoing it.
# Usage: copy the token (Zero Trust -> Networks -> Tunnels -> <tunnel> -> install command,
#        the long string after --token), then run: scripts/seal-cloudflared-token.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# Always the homelab cluster - never whatever KUBECONFIG the shell happens to point at.
export KUBECONFIG="${HOMELAB_KUBECONFIG:-$HOME/.kube/homelab-config}"
echo "Sealing for cluster: $(kubectl config current-context) ($KUBECONFIG)"
read -rsp "Paste the tunnel token (input hidden): " token; echo
[[ ${#token} -gt 100 ]] || { echo "That doesn't look like a tunnel token." >&2; exit 1; }
printf '%s' "$token" | kubectl create secret generic cloudflared-token -n cloudflared \
    --from-file=token=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --format yaml --controller-namespace kube-system \
      --controller-name sealed-secrets-controller \
  > helm/cloudflared/templates/token-sealed.yaml
unset token
echo "Wrote helm/cloudflared/templates/token-sealed.yaml (encrypted; safe to commit)."
