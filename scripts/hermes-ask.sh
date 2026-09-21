#!/usr/bin/env bash
# hermes-ask.sh — the bridge Antigravity 2.0 uses to talk to Hermes in Docker.
#
#   ./scripts/hermes-ask.sh "which of my projects already parses EVN hourly meters?"
#   git -C ~/proj diff | ./scripts/hermes-ask.sh -          # read the prompt from stdin
#
# This is the "slash command protocol" of the README: `/hermes <question>` in the
# Antigravity chat resolves to .agents/workflows/hermes.md, which runs this script.
#
# Transports
#   docker (default) — `docker exec ... hermes --in /workspace/projects -z "<prompt>"`.
#       `hermes -z` is the pure one-shot entry point: final answer text on stdout, no
#       banner/spinner/tool previews. No port, no API key, works on a fresh container.
#   http            — the gateway's OpenAI-compatible server
#       (POST 127.0.0.1:8642/v1/chat/completions, model "hermes-agent"). Needs
#       HERMES_API_ENABLED=true + HERMES_API_KEY in .env and a restart.
#
# Exit codes: 0 answer on stdout | 1 empty answer | 2 Hermes failed/partial |
#             3 container not running | 4 preconditions missing | 130 interrupted
# Output contract: stdout = ONLY the answer (safe to paste into a chat), stderr = diagnostics.

set -eu

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read .env as DATA, never as a script: only KEY=value lines are honoured, no eval,
# so a hand-edited .env containing `$(...)` or `; rm -rf` cannot execute here.
if [ -f "$repo_root/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    val="${val#"${val%%[![:space:]]*}"}"          # ltrim
    case "$val" in \#*) val="" ;; esac             # inline comment
    if [ "${#val}" -ge 2 ]; then                    # strip one layer of matching quotes
      case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
      esac
    fi
    # Precedence: the caller's environment wins over .env, so Antigravity/skill callers
    # can override a transport or container name per-invocation without editing files.
    [ -n "${!key+set}" ] && continue
    export "$key=$val" 2>/dev/null || true
  done < "$repo_root/.env"
fi

TRANSPORT="${HERMES_TRANSPORT:-docker}"
CONTAINER="${HERMES_CONTAINER:-hermes_local}"
CW="${HERMES_WORKSPACE:-/workspace/projects}"
TIMEOUT_S="${HERMES_TIMEOUT:-300}"
API_URL="${HERMES_API_URL:-http://127.0.0.1:8642/v1}"
API_KEY="${HERMES_API_KEY:-}"
API_MODEL="${HERMES_API_MODEL:-hermes-agent}"
CHECK_INDEX=1
SYSTEM_PROMPT=""

say() { echo "hermes-ask: $*" >&2; }
die() { say "$1"; exit "${2:-4}"; }

usage() {
  cat <<'EOF'
usage: scripts/hermes-ask.sh [options] <prompt|->

  -                       read the prompt from stdin
  --transport T           docker (default) | http
  --container NAME        docker container  (default $HERMES_CONTAINER / hermes_local)
  --cwd PATH              working dir inside the container (default /workspace/projects)
  --timeout SECS          wall-clock cap    (default 300; CPU models are slow — raise it)
  --system TEXT           extra system instructions (http transport only)
  --no-index-check        skip the "is INDEX.md stale?" warning

Requires a running container: ./start-hermes.sh
EOF
}

PROMPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --transport)      TRANSPORT="${2:-}"; shift 2 ;;
    --container)      CONTAINER="${2:-}"; shift 2 ;;
    --cwd)            CW="${2:-}"; shift 2 ;;
    --timeout)        TIMEOUT_S="${2:-}"; shift 2 ;;
    --system)         SYSTEM_PROMPT="${2:-}"; shift 2 ;;
    --no-index-check) CHECK_INDEX=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    -)                PROMPT="$(cat)"; shift ;;
    --*)              die "unknown option: $1 (see --help)" 4 ;;
    *)                PROMPT="${PROMPT:+$PROMPT
}$1"; shift ;;
  esac
done

[ -n "$PROMPT" ] || { usage >&2; die "empty prompt" 4; }
command -v docker >/dev/null 2>&1 || [ "$TRANSPORT" = "http" ] || die "docker not installed — see README.md" 4

# A stale index is the #1 cause of "Hermes doesn't know my new project".
if [ "$CHECK_INDEX" = 1 ] && [ -x "$repo_root/scripts/hermes-index.sh" ]; then
  if ! "$repo_root/scripts/hermes-index.sh" --check --quiet 2>/dev/null; then
    say "⚠ drop-zone INDEX.md is stale/missing → run: ./scripts/hermes-index.sh"
  fi
fi

run_capped() {   # run_capped <secs> <cmd...>  — honour the timeout without requiring coreutils
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else say "no \`timeout\` binary — running uncapped"; "$@"; fi
}

case "$TRANSPORT" in
# ---------------------------------------------------------------- docker transport
docker)
  running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)"
  if [ "$running" != "true" ]; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
      die "container '$CONTAINER' exists but is not running — docker start $CONTAINER (or ./start-hermes.sh)" 3
    fi
    die "container '$CONTAINER' not found — start it with ./start-hermes.sh" 3
  fi
  TMPD="${TMPDIR:-/tmp}"
  errf="$(mktemp "$TMPD/hermes-ask.XXXXXX")"
  out="$(run_capped "$TIMEOUT_S" docker exec -i "$CONTAINER" hermes --in "$CW" -z "$PROMPT" 2>"$errf")" && rc=0 || rc=$?
  err="$(cat "$errf" 2>/dev/null || true)"; rm -f "$errf"
  # `set -e` would abort on a bare `[ -n "$err" ] && ...` when stderr is empty.
  if [ -n "$err" ]; then printf '%s\n' "$err" >&2; fi
  case "$rc" in
    0) ;;
    124) die "timed out after ${TIMEOUT_S}s — CPU inference is slow; raise HERMES_TIMEOUT or use a bigger host GPU" 2 ;;
    130) die "interrupted" 130 ;;
    2)   die "Hermes returned a failed/partial turn (see stderr above)" 2 ;;
    *)   die "hermes exited $rc (see stderr above)" 2 ;;
  esac
  [ -n "${out//[[:space:]]/}" ] || die "Hermes produced no text (empty answer)" 1
  printf '%s\n' "$out"
  ;;
# ------------------------------------------------------------------ http transport
http)
  command -v curl >/dev/null 2>&1 || die "curl is required for --transport http" 4
  [ -n "$API_KEY" ] || die "HERMES_API_KEY is empty — set it in .env, then: docker compose up -d" 4
  if command -v jq >/dev/null 2>&1; then
    # NB: jq 1.6 cannot parse `key: (if … end) + […]` inside an object constructor — the
    # `.messages = (…)` assignment after a pipe is what compiles.
    body="$(jq -cn --arg m "$API_MODEL" --arg c "$PROMPT" --arg s "$SYSTEM_PROMPT" \
      '{model:$m, stream:false} | .messages = ((if $s == "" then [] else [{role:"system", content:$s}] end)
                                               + [{role:"user", content:$c}])')" || die "could not build the JSON request body" 4
  elif command -v python3 >/dev/null 2>&1; then
    body="$(API_MODEL="$API_MODEL" PROMPT="$PROMPT" SYSTEM_PROMPT="$SYSTEM_PROMPT" python3 -c '
import json,os
msgs=[]
if os.environ.get("SYSTEM_PROMPT"): msgs.append({"role":"system","content":os.environ["SYSTEM_PROMPT"]})
msgs.append({"role":"user","content":os.environ["PROMPT"]})
print(json.dumps({"model":os.environ["API_MODEL"],"stream":False,"messages":msgs}))')"
  else
    die "need jq or python3 to build the request body" 4
  fi
  resp="$(run_capped "$TIMEOUT_S" curl -fsS -m "$TIMEOUT_S" -X POST "$API_URL/chat/completions" \
            -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d "$body")" \
    || die "HTTP request to $API_URL failed — is the gateway up with HERMES_API_ENABLED=true?" 2
  if command -v jq >/dev/null 2>&1; then
    # `// .` last-resort keeps a raw error body visible instead of printing "null".
    printf '%s' "$resp" | jq -r '.choices[0].message.content // .error.message // .' \
      || die "unexpected response from the API server (not OpenAI-shaped JSON)" 2
  else
    printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("choices",[{}])[0].get("message",{}).get("content") or d)'
  fi
  ;;
*) die "unknown --transport '$TRANSPORT' (docker|http)" 4 ;;
esac
