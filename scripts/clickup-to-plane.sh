#!/bin/bash
# clickup-to-plane.sh — Full-mirror sync: ClickUp team (all lists/sprints) → Plane workspace
# Runs nightly via cron. Requires scripts/.env to be populated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/logs/clickup-to-plane.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
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

: "${CLICKUP_API_TOKEN:?CLICKUP_API_TOKEN not set}"
: "${CLICKUP_TEAM_ID:?CLICKUP_TEAM_ID not set}"
: "${PLANE_API_KEY:?PLANE_API_KEY not set}"
: "${PLANE_WORKSPACE_CLICKUP:?PLANE_WORKSPACE_CLICKUP not set}"
: "${PLANE_PROJECT_CLICKUP:?PLANE_PROJECT_CLICKUP not set}"

CLICKUP_BASE="https://api.clickup.com/api/v2"
PLANE_BASE="https://api.plane.so/api/v1"

# Resolve the authenticated ClickUp user ID for assignee filtering
CLICKUP_USER_ID=$(curl -s -f \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "${CLICKUP_BASE}/user" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['user']['id'])" 2>/dev/null || echo "")
if [[ -z "$CLICKUP_USER_ID" ]]; then
  log ERROR "Could not resolve ClickUp user ID — check CLICKUP_API_TOKEN"
  exit 1
fi
log INFO "Filtering tasks for ClickUp user ID: ${CLICKUP_USER_ID}"

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
# Helper: ClickUp GET request
# ---------------------------------------------------------------------------
clickup_get() {
  local path="$1"
  local url="${CLICKUP_BASE}${path}"
  local response
  if ! response=$(curl -s -f \
      -H "Authorization: ${CLICKUP_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "$url" 2>&1); then
    log ERROR "ClickUp GET $path failed: $response"
    return 1
  fi
  printf '%s' "$response"
}

# ---------------------------------------------------------------------------
# map_priority: ClickUp priority → Plane priority
# ---------------------------------------------------------------------------
map_priority() {
  local p
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$p" in
    urgent)  printf 'urgent' ;;
    high)    printf 'high'   ;;
    normal)  printf 'medium' ;;
    low)     printf 'low'    ;;
    *)       printf 'none'   ;;
  esac
}

# ---------------------------------------------------------------------------
# fetch_plane_states: populate STATE_MAP for the ClickUp workspace/project
# ---------------------------------------------------------------------------
fetch_plane_states() {
  log INFO "Fetching Plane states..."
  local resp
  resp=$(plane_api GET "/workspaces/${PLANE_WORKSPACE_CLICKUP}/projects/${PLANE_PROJECT_CLICKUP}/states/")

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
# map_status: ClickUp status → Plane state id
# ---------------------------------------------------------------------------
map_status() {
  local clickup_status="${1}"
  local cs plane_name
  cs=$(printf '%s' "$clickup_status" | tr '[:upper:]' '[:lower:]')
  case "$cs" in
    "open"|"todo"|"to do")         plane_name="Backlog"     ;;
    "in progress")                  plane_name="In Progress" ;;
    "review")                       plane_name="In Review"   ;;
    "complete"|"closed"|"done")     plane_name="Done"        ;;
    *)                              plane_name="Backlog"     ;;
  esac

  local sid
  sid=$(_map_get "$STATE_MAP_FILE" "$plane_name")
  if [[ -z "$sid" ]]; then
    log WARN "State '$plane_name' not found — attempting to create"
    local resp
    resp=$(plane_api POST \
      "/workspaces/${PLANE_WORKSPACE_CLICKUP}/projects/${PLANE_PROJECT_CLICKUP}/states/" \
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
# fetch_plane_issues: populate PLANE_MAP keyed by external_id (clickup task id)
# ---------------------------------------------------------------------------
fetch_plane_issues() {
  log INFO "Fetching existing Plane issues (external_source=clickup)..."
  local page=1
  local total=0

  while true; do
    local resp
    resp=$(plane_api GET \
      "/workspaces/${PLANE_WORKSPACE_CLICKUP}/projects/${PLANE_PROJECT_CLICKUP}/issues/?external_source=clickup&per_page=100&page=${page}")

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
  log INFO "Found $total existing Plane issues with external_source=clickup"
}

# ---------------------------------------------------------------------------
# fetch_clickup_tasks: paginated fetch of all tasks across the entire team
# Uses the team-level endpoint so new sprints/lists are picked up automatically.
# ---------------------------------------------------------------------------
fetch_clickup_tasks() {
  log INFO "Fetching ClickUp tasks for team ${CLICKUP_TEAM_ID} (all lists)..."
  local page=0
  local total=0
  local tmpfile
  tmpfile=$(mktemp)

  while true; do
    local resp
    resp=$(clickup_get "/team/${CLICKUP_TEAM_ID}/task?page=${page}&include_closed=true&subtasks=true&assignees[]=${CLICKUP_USER_ID}")

    local count
    count=$(printf '%s' "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('tasks', [])))
" 2>/dev/null || echo 0)

    if [[ "$count" -eq 0 ]]; then break; fi

    printf '%s' "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for task in d.get('tasks', []):
    print(json.dumps(task))
" >> "$tmpfile"

    total=$((total + count))
    log INFO "Fetched page $page ($count tasks, $total total)"
    page=$((page + 1))

    # ClickUp returns last_page=true when done
    local last
    last=$(printf '%s' "$resp" | python3 -c "
import sys, json; d=json.load(sys.stdin); print(d.get('last_page', True))
" 2>/dev/null || echo "True")
    [[ "$last" == "True" || "$last" == "true" ]] && break
  done

  log INFO "Total ClickUp tasks fetched: $total"
  cat "$tmpfile"
  rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# build_plane_payload: ClickUp task JSON → Plane issue JSON
# ---------------------------------------------------------------------------
build_plane_payload() {
  local task_json="$1"
  local state_id="$2"

  printf '%s' "$task_json" | python3 -c "
import sys, json

task = json.load(sys.stdin)

priority_map = {
    'urgent': 'urgent',
    'high':   'high',
    'normal': 'medium',
    'low':    'low',
}
raw_pri = (task.get('priority') or {}).get('priority', '') or ''
plane_priority = priority_map.get(raw_pri.lower(), 'none')

payload = {
    'name': task.get('name', '(no title)'),
    'state': '$state_id',
    'priority': plane_priority,
    'external_id': str(task.get('id', '')),
    'external_source': 'clickup',
}
print(json.dumps(payload))
"
}

# ---------------------------------------------------------------------------
# Main sync
# ---------------------------------------------------------------------------
main() {
  log INFO "=== ClickUp → Plane sync started ==="

  fetch_plane_states
  fetch_plane_issues

  local tmpfile
  tmpfile=$(mktemp)
  fetch_clickup_tasks > "$tmpfile"

  local created=0 updated=0 deleted=0 errors=0

  while IFS= read -r task_json; do
    [[ -z "$task_json" ]] && continue

    local ext_id
    ext_id=$(printf '%s' "$task_json" | python3 -c "
import sys, json; print(str(json.load(sys.stdin).get('id', '')))
" 2>/dev/null || echo "")
    [[ -z "$ext_id" ]] && continue

    printf '%s\n' "$ext_id" >> "$SOURCE_IDS_FILE"

    local clickup_status
    clickup_status=$(printf '%s' "$task_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print((d.get('status') or {}).get('status', 'Open'))
" 2>/dev/null || echo "Open")

    local state_id
    state_id=$(map_status "$clickup_status")

    local payload
    payload=$(build_plane_payload "$task_json" "$state_id")

    local plane_id
    plane_id=$(_map_get "$PLANE_MAP_FILE" "$ext_id")

    if [[ -z "$plane_id" ]]; then
      # Create
      if plane_api POST \
          "/workspaces/${PLANE_WORKSPACE_CLICKUP}/projects/${PLANE_PROJECT_CLICKUP}/issues/" \
          "$payload" > /dev/null; then
        log INFO "CREATED task $ext_id"
        created=$((created + 1))
      else
        log ERROR "Failed to create task $ext_id"
        errors=$((errors + 1))
      fi
    else
      # Update
      if plane_api PATCH \
          "/workspaces/${PLANE_WORKSPACE_CLICKUP}/projects/${PLANE_PROJECT_CLICKUP}/issues/${plane_id}/" \
          "$payload" > /dev/null; then
        log INFO "UPDATED task $ext_id (plane_id=$plane_id)"
        updated=$((updated + 1))
      else
        log ERROR "Failed to update task $ext_id"
        errors=$((errors + 1))
      fi
    fi
  done < "$tmpfile"
  rm -f "$tmpfile"

  # Deletions
  while IFS= read -r ext_id; do
    [[ -z "$ext_id" ]] && continue
    if ! grep -qx "$ext_id" "$SOURCE_IDS_FILE" 2>/dev/null; then
      local plane_id
      plane_id=$(_map_get "$PLANE_MAP_FILE" "$ext_id")
      if plane_api DELETE \
          "/workspaces/${PLANE_WORKSPACE_CLICKUP}/projects/${PLANE_PROJECT_CLICKUP}/issues/${plane_id}/" > /dev/null; then
        log INFO "DELETED task $ext_id (plane_id=$plane_id) — no longer in ClickUp"
        deleted=$((deleted + 1))
      else
        log ERROR "Failed to delete task $ext_id"
        errors=$((errors + 1))
      fi
    fi
  done < <(_map_keys "$PLANE_MAP_FILE")

  log INFO "=== Sync complete: created=$created updated=$updated deleted=$deleted errors=$errors ==="
  [[ "$errors" -gt 0 ]] && exit 1
  exit 0
}

main "$@"
