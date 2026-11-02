#!/usr/bin/env bash
# Seal the Zernio API key for IBG Studio. The key is read with hidden input and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${HOMELAB_KUBECONFIG:-$HOME/.kube/homelab-config}"
echo "Sealing for cluster: $(kubectl config current-context) ($KUBECONFIG)"
out=helm/ibg-studio/templates/zernio-sealed.yaml
tmp=$(mktemp); trap 'unset key; rm -f "$tmp"' EXIT
read -rsp "Zernio API key (hidden): " key; echo
[[ "$key" == sk_* ]] || { echo "That does not look like a Zernio key (sk_...)." >&2; exit 1; }
printf '%s' "$key" \
  | kubectl create secret generic ibg-studio-zernio -n ibg-studio --from-file=ZERNIO_API_KEY=/dev/stdin \
      --dry-run=client -o yaml \
  | kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller \
  > "$tmp"
mv "$tmp" "$out"   # replace the manifest only once sealing succeeded
echo "Wrote $out (encrypted; safe to commit)."
