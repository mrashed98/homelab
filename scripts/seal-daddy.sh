#!/usr/bin/env bash
# Seal the Daddy API's initial secrets into helm/daddy-api/templates/. Nothing is typed or
# printed: generated values and the OpenAI key exist only inside this process and the seals.
#   - daddy-postgres: POSTGRES_PASSWORD (random)
#   - daddy-api:      DATABASE_URL, JWT_SIGNING_KEY, APPLE_TOKEN_KEY (random) and the AI keys
#                     from ~/.config/daddy/{openai,anthropic}.env (either may be missing)
#   - ghcr-pull:      copied from the ibg-studio namespace (same read:packages token)
# Initial creation only: Postgres learns its password once, and a new APPLE_TOKEN_KEY makes
# stored Apple tokens unreadable. Rotate those by hand (see Daddy backend/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${HOMELAB_KUBECONFIG:-$HOME/.kube/homelab-config}"
echo "Sealing for cluster: $(kubectl config current-context) ($KUBECONFIG)"
ns=daddy
out=helm/daddy-api/templates
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"
seal() { kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller; }
# Sync wave -1: secrets exist before the database and the API start.
wave() { awk '{print} !done && $0 == "  namespace: '"$ns"'" {print "  annotations:"; print "    argocd.argoproj.io/sync-wave: \"-1\""; done=1}'; }

if kubectl -n "$ns" get secret daddy-postgres >/dev/null 2>&1; then
  echo "daddy-postgres already exists; this script only creates the initial secrets." >&2
  exit 1
fi

pass=$(openssl rand -hex 24)   # hex: safe in a URL without escaping
printf '%s' "$pass" \
  | kubectl create secret generic daddy-postgres -n "$ns" --from-file=POSTGRES_PASSWORD=/dev/stdin \
      --dry-run=client -o yaml | seal | wave > "$tmp/postgres-sealed.yaml"

# Env file in the private temp dir; the AI keys are sourced in a subshell and never echoed.
(
  umask 077
  ai_openai=""; ai_anthropic=""
  if [[ -f ~/.config/daddy/openai.env ]]; then ai_openai=$(set -a; . ~/.config/daddy/openai.env; printf '%s' "${OPENAI_API_KEY:-}"); fi
  if [[ -f ~/.config/daddy/anthropic.env ]]; then ai_anthropic=$(set -a; . ~/.config/daddy/anthropic.env; printf '%s' "${ANTHROPIC_API_KEY:-}"); fi
  [[ -n $ai_openai || -n $ai_anthropic ]] || { echo "No AI key in ~/.config/daddy/*.env" >&2; exit 1; }
  {
    printf 'DATABASE_URL=postgresql://daddy:%s@daddy-postgres:5432/daddy\n' "$pass"
    printf 'JWT_SIGNING_KEY=%s\n' "$(openssl rand -base64 32)"
    printf 'APPLE_TOKEN_KEY=%s\n' "$(openssl rand -base64 32)"
    [[ -n $ai_openai ]] && printf 'OPENAI_API_KEY=%s\n' "$ai_openai"
    [[ -n $ai_anthropic ]] && printf 'ANTHROPIC_API_KEY=%s\n' "$ai_anthropic"
    true
  } > "$tmp/app.env"
)
unset pass
kubectl create secret generic daddy-api -n "$ns" --from-env-file="$tmp/app.env" --dry-run=client -o yaml \
  | seal | wave > "$tmp/app-sealed.yaml"
rm -f "$tmp/app.env"

# Re-seal IBG's pull secret for this namespace (jq drops cluster metadata; nothing printed).
kubectl -n ibg-studio get secret ghcr-pull -o json \
  | jq --arg ns "$ns" '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: $ns}}' \
  | seal | wave > "$tmp/ghcr-pull-sealed.yaml"

mv "$tmp/postgres-sealed.yaml" "$tmp/app-sealed.yaml" "$tmp/ghcr-pull-sealed.yaml" "$out/"
echo "Wrote $out/{postgres,app,ghcr-pull}-sealed.yaml (encrypted; safe to commit)."
