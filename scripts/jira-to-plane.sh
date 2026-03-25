#!/bin/bash
# jira-to-plane.sh — Full-mirror sync: Jira project → Plane workspace
# Runs nightly via cron. Requires scripts/.env to be populated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/logs/jira-to-plane.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local level="$1"
  shift
  printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  log ERROR ".env not found at $ENV_FILE — copy .env.example and fill in tokens"
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

mkdir -p "$SCRIPT_DIR/logs"

: "${JIRA_DOMAIN:?JIRA_DOMAIN not set}"
: "${JIRA_EMAIL:?JIRA_EMAIL not set}"
: "${JIRA_API_TOKEN:?JIRA_API_TOKEN not set}"
: "${JIRA_PROJECT_KEY:?JIRA_PROJECT_KEY not set}"
: "${PLANE_API_KEY:?PLANE_API_KEY not set}"
: "${PLANE_WORKSPACE_JIRA:?PLANE_WORKSPACE_JIRA not set}"
: "${PLANE_PROJECT_JIRA:?PLANE_PROJECT_JIRA not set}"

JIRA_BASE="https://${JIRA_DOMAIN}/rest/api/3"
JIRA_SEARCH="${JIRA_BASE}/search/jql"
PLANE_BASE="https://api.plane.so/api/v1"
JIRA_AUTH="$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64)"

# ---------------------------------------------------------------------------
# Map storage (replaces bash 4 declare -A; uses tab-delimited temp files)
# ---------------------------------------------------------------------------
_MAP_DIR=$(mktemp -d)
PLANE_MAP_FILE="$_MAP_DIR/plane_map"
STATE_MAP_FILE="$_MAP_DIR/state_map"
SOURCE_IDS_FILE="$_MAP_DIR/source_ids"
touch "$PLANE_MAP_FILE" "$STATE_MAP_FILE" "$SOURCE_IDS_FILE"
trap 'rm -rf "$_MAP_DIR"' EXIT

_map_get() {
  # Usage: _map_get <file> <key>  → prints value or empty string
  awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null || true
}

_map_set() {
  # Usage: _map_set <file> <key> <value>  — appends; _map_get returns first match
  printf '%s\t%s\n' "$2" "$3" >> "$1"
}

_map_keys() {
  # Usage: _map_keys <file>  → one key per line
  cut -f1 "$1" 2>/dev/null || true
}

_map_size() {
  # Usage: _map_size <file>  → number of entries
  wc -l < "$1" | tr -d ' ' || echo 0
}

# ---------------------------------------------------------------------------
# Helper: generic Plane API call
# Usage: plane_api <METHOD> <path> [json-body]
# ---------------------------------------------------------------------------
plane_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url="${PLANE_BASE}${path}"
  local args=(-s -f -X "$method" -H "X-API-Key: ${PLANE_API_KEY}" -H "Content-Type: application/json")

  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi

  local response
  if ! response=$(curl "${args[@]}" "$url" 2>&1); then
    log ERROR "Plane API $method $path failed: $response"
    return 1
  fi
  printf '%s' "$response"
}

# ---------------------------------------------------------------------------
# Helper: Jira REST call (GET only; pagination handled by callers)
# ---------------------------------------------------------------------------
jira_get() {
  local path="$1"
  local url="${JIRA_BASE}${path}"
  local response
  if ! response=$(curl -s -f \
    -H "Authorization: Basic ${JIRA_AUTH}" \
    -H "Content-Type: application/json" \
    "$url" 2>&1); then
    log ERROR "Jira GET $path failed: $response"
    return 1
  fi
  printf '%s' "$response"
}

# ---------------------------------------------------------------------------
# map_priority: Jira priority name → Plane priority string
# ---------------------------------------------------------------------------
map_priority() {
  local p
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$p" in
  highest) printf 'urgent' ;;
  high) printf 'high' ;;
  medium) printf 'medium' ;;
  low) printf 'low' ;;
  lowest) printf 'none' ;;
  *) printf 'none' ;;
  esac
}

# ---------------------------------------------------------------------------
# fetch_plane_states: populate STATE_MAP (name→id) for the project
# ---------------------------------------------------------------------------
fetch_plane_states() {
  log INFO "Fetching Plane states..."
  local resp
  resp=$(plane_api GET "/workspaces/${PLANE_WORKSPACE_JIRA}/projects/${PLANE_PROJECT_JIRA}/states/")

  while IFS=$'\t' read -r sid sname; do
    _map_set "$STATE_MAP_FILE" "$sname" "$sid"
  done < <(printf '%s' "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('results', d) if isinstance(d, dict) else d
for s in items:
    print(s['id'] + '\t' + s['name'])
")
  log INFO "Loaded $(_map_size "$STATE_MAP_FILE") Plane states"
}

# ---------------------------------------------------------------------------
# map_status: Jira status → Plane state id
# ---------------------------------------------------------------------------
map_status() {
  local jira_status="${1}"
  local js plane_name
  js=$(printf '%s' "$jira_status" | tr '[:upper:]' '[:lower:]')
  case "$js" in
  "to do" | "open" | "todo" | "backlog") plane_name="Backlog" ;;
  "in progress") plane_name="In Progress" ;;
  "in review" | "review") plane_name="In Review" ;;
  "done" | "closed" | "resolved") plane_name="Done" ;;
  *) plane_name="Backlog" ;;
  esac

  local sid
  sid=$(_map_get "$STATE_MAP_FILE" "$plane_name")
  if [[ -z "$sid" ]]; then
    # Try to create missing state
    log WARN "State '$plane_name' not found — attempting to create"
    local resp
    resp=$(plane_api POST \
      "/workspaces/${PLANE_WORKSPACE_JIRA}/projects/${PLANE_PROJECT_JIRA}/states/" \
      "{\"name\":\"${plane_name}\",\"color\":\"#808080\",\"group\":\"backlog\"}") || true
    sid=$(printf '%s' "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [[ -n "$sid" ]]; then
      _map_set "$STATE_MAP_FILE" "$plane_name" "$sid"
      log INFO "Created Plane state '$plane_name' (id=$sid)"
    fi
  fi
  printf '%s' "$sid"
}

# ---------------------------------------------------------------------------
# fetch_plane_issues: populate PLANE_MAP keyed by external_id
# ---------------------------------------------------------------------------
fetch_plane_issues() {
  log INFO "Fetching existing Plane issues (external_source=jira)..."
  local page=1
  local total=0

  while true; do
    local resp
    resp=$(plane_api GET \
      "/workspaces/${PLANE_WORKSPACE_JIRA}/projects/${PLANE_PROJECT_JIRA}/issues/?external_source=jira&per_page=100&page=${page}")

    local count
    count=$(printf '%s' "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('results', d) if isinstance(d, dict) else d
print(len(items))
" 2>/dev/null || echo 0)

    if [[ "$count" -eq 0 ]]; then break; fi

    while IFS=$'\t' read -r pid eid; do
      _map_set "$PLANE_MAP_FILE" "$eid" "$pid"
    done < <(printf '%s' "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('results', d) if isinstance(d, dict) else d
for i in items:
    eid = i.get('external_id') or ''
    if eid:
        print(i['id'] + '\t' + eid)
")
    total=$((total + count))
    page=$((page + 1))
    [[ "$count" -lt 100 ]] && break
  done
  log INFO "Found $total existing Plane issues with external_source=jira"
}

# ---------------------------------------------------------------------------
# fetch_jira_issues: returns newline-separated JSON objects, one per issue
# ---------------------------------------------------------------------------
fetch_jira_issues() {
  log INFO "Fetching Jira issues assigned to me in project ${JIRA_PROJECT_KEY}..."
  local page_size=50
  local total_fetched=0
  local next_token=""
  local tmpfile
  tmpfile=$(mktemp)

  while true; do
    local url="${JIRA_SEARCH}?jql=project=${JIRA_PROJECT_KEY}%20AND%20assignee%3DcurrentUser()&maxResults=${page_size}&fields=summary,status,priority,description,assignee"
    [[ -n "$next_token" ]] && url="${url}&nextPageToken=${next_token}"

    local resp
    resp=$(curl -s -f \
      -H "Authorization: Basic ${JIRA_AUTH}" \
      -H "Content-Type: application/json" \
      "$url" 2>&1) || { log ERROR "Jira fetch failed"; break; }

    local count
    count=$(printf '%s' "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('issues', [])))
" 2>/dev/null || echo 0)

    if [[ "$count" -eq 0 ]]; then break; fi

    printf '%s' "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for issue in d.get('issues', []):
    print(json.dumps(issue))
" >>"$tmpfile"

    total_fetched=$((total_fetched + count))
    log INFO "Fetched $total_fetched Jira issues so far..."

    local is_last
    is_last=$(printf '%s' "$resp" | python3 -c "
import sys, json; d=json.load(sys.stdin); print(d.get('isLast', True))
" 2>/dev/null || echo "True")
    [[ "$is_last" == "True" || "$is_last" == "true" ]] && break

    next_token=$(printf '%s' "$resp" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('nextPageToken', ''))
" 2>/dev/null || echo "")
    [[ -z "$next_token" ]] && break
  done

  log INFO "Total Jira issues fetched: $total_fetched"
  cat "$tmpfile"
  rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# build_plane_payload: convert a Jira issue JSON line → Plane issue JSON
# ---------------------------------------------------------------------------
build_plane_payload() {
  local jira_json="$1"
  local state_id="$2"

  printf '%s' "$jira_json" | python3 -c "
import sys, json

d = json.load(sys.stdin)
fields = d.get('fields', {})

priority_map = {'highest': 'urgent', 'high': 'high', 'medium': 'medium', 'low': 'low', 'lowest': 'none'}
raw_pri = (fields.get('priority') or {}).get('name', 'Medium')
plane_priority = priority_map.get(raw_pri.lower(), 'none')

payload = {
    'name': fields.get('summary', '(no title)'),
    'state': '$state_id',
    'priority': plane_priority,
    'external_id': d['key'],
    'external_source': 'jira',
}
print(json.dumps(payload))
"
}

# ---------------------------------------------------------------------------
# Main sync
# ---------------------------------------------------------------------------
main() {
  log INFO "=== Jira → Plane sync started ==="

  fetch_plane_states
  fetch_plane_issues

  local tmpfile
  tmpfile=$(mktemp)
  fetch_jira_issues >"$tmpfile"

  local created=0 updated=0 deleted=0 errors=0

  while IFS= read -r issue_json; do
    [[ -z "$issue_json" ]] && continue

    local ext_id
    ext_id=$(printf '%s' "$issue_json" | python3 -c "
import sys, json; print(json.load(sys.stdin)['key'])
" 2>/dev/null || echo "")
    [[ -z "$ext_id" ]] && continue

    printf '%s\n' "$ext_id" >> "$SOURCE_IDS_FILE"

    local jira_status
    jira_status=$(printf '%s' "$issue_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['fields']['status']['name'])
" 2>/dev/null || echo "To Do")

    local state_id
    state_id=$(map_status "$jira_status")

    local payload
    payload=$(build_plane_payload "$issue_json" "$state_id")

    local plane_id
    plane_id=$(_map_get "$PLANE_MAP_FILE" "$ext_id")

    if [[ -z "$plane_id" ]]; then
      # Create
      if plane_api POST \
        "/workspaces/${PLANE_WORKSPACE_JIRA}/projects/${PLANE_PROJECT_JIRA}/issues/" \
        "$payload" >/dev/null; then
        log INFO "CREATED issue $ext_id"
        created=$((created + 1))
      else
        log ERROR "Failed to create issue $ext_id"
        errors=$((errors + 1))
      fi
    else
      # Update
      if plane_api PATCH \
        "/workspaces/${PLANE_WORKSPACE_JIRA}/projects/${PLANE_PROJECT_JIRA}/issues/${plane_id}/" \
        "$payload" >/dev/null; then
        log INFO "UPDATED issue $ext_id (plane_id=$plane_id)"
        updated=$((updated + 1))
      else
        log ERROR "Failed to update issue $ext_id"
        errors=$((errors + 1))
      fi
    fi
  done <"$tmpfile"
  rm -f "$tmpfile"

  # Deletions: Plane issues whose external_id no longer exists in Jira
  while IFS= read -r ext_id; do
    [[ -z "$ext_id" ]] && continue
    if ! grep -qx "$ext_id" "$SOURCE_IDS_FILE" 2>/dev/null; then
      local plane_id
      plane_id=$(_map_get "$PLANE_MAP_FILE" "$ext_id")
      if plane_api DELETE \
        "/workspaces/${PLANE_WORKSPACE_JIRA}/projects/${PLANE_PROJECT_JIRA}/issues/${plane_id}/" >/dev/null; then
        log INFO "DELETED issue $ext_id (plane_id=$plane_id) — no longer in Jira"
        deleted=$((deleted + 1))
      else
        log ERROR "Failed to delete issue $ext_id"
        errors=$((errors + 1))
      fi
    fi
  done < <(_map_keys "$PLANE_MAP_FILE")

  log INFO "=== Sync complete: created=$created updated=$updated deleted=$deleted errors=$errors ==="
  [[ "$errors" -gt 0 ]] && exit 1
  exit 0
}

main "$@"
