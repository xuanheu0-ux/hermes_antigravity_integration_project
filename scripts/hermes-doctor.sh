#!/usr/bin/env bash
# hermes-doctor.sh — "is this integration actually working?" in one command.
#
# Scope note: upstream Hermes has its own `hermes doctor` for agent/config problems.
# This script checks the parts upstream cannot see: the container wiring, the drop
# zone, the index, the Ollama context-window trap, and this repo's own footguns.
#
#   ./scripts/hermes-doctor.sh            # full report
#   HERMES_DOCTOR_JSON=1 ...              # one `key=value` line per check (for agents)
#
# Exit: 0 all good (warnings allowed) | 1 at least one FAIL
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; warn=0; fail=0
# NOTE: report() must return 0. Callers use `A && report PASS x || report WARN y`, and a
# non-zero here would fire the || branch too (double-reported checks — seen in the wild).
report() { # report PASS|WARN|FAIL <check> <detail>
  case "$1" in
    PASS) pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %-22s %s\n' "$2" "$3" ;;
    WARN) warn=$((warn + 1)); printf '  \033[33mWARN\033[0m  %-22s %s\n' "$2" "$3" ;;
    *)    fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %-22s %s\n' "$2" "$3" ;;
  esac
  [ "${HERMES_DOCTOR_JSON:-0}" = 1 ] && printf 'RESULT %s %s %s\n' "$1" "$2" "$3"
  return 0
}
# `hermes config get <key>` prints the literal "None" for unset values — normalise it.
clean() { case "$(printf '%s' "${1:-}" | tr -d '[:space:]')" in ""|None|null|undefined) printf '' ;; *) printf '%s' "$(printf '%s' "$1" | tr -d '[:space:]')";; esac; }
get_env() { local l; l="$(grep -E "^[[:space:]]*$1[[:space:]]*=" .env 2>/dev/null | tail -1 || true)"; printf '%s' "${l#*=}"; }

CONTAINER="$(get_env HERMES_CONTAINER)"; CONTAINER="${CONTAINER:-hermes_local}"
DROPZONE="$(get_env HERMES_DROPZONE)";   DROPZONE="${DROPZONE:-./hermes_shared_workspace}"
TRANSPORT="$(get_env HERMES_TRANSPORT)"; TRANSPORT="${TRANSPORT:-docker}"

echo "Hermes x Antigravity doctor"
echo "==========================="

# 1. Docker + Compose v2
if ! command -v docker >/dev/null 2>&1; then
  report FAIL docker "docker not on PATH — install Docker Engine/Desktop first"
else
  report PASS docker "$(docker --version 2>/dev/null | head -1)"
  if docker compose version >/dev/null 2>&1; then
    report PASS compose "v2 ($(docker compose version --short 2>/dev/null | head -1))"
  else
    report FAIL compose "no 'docker compose' v2 plugin; the legacy docker-compose binary is not supported"
  fi
  docker info >/dev/null 2>&1 || report FAIL daemon "daemon unreachable (start Docker; add yourself to the 'docker' group?)"
fi

# 2. container lifecycle — crash loops used to be invisible here (missing `command:`)
state="$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$CONTAINER" 2>/dev/null || true)"
if [ -z "$state" ]; then
  report FAIL container "'$CONTAINER' does not exist — run ./start-hermes.sh"
fi
case "$state" in
  *running*)
    case "$state" in
      *"restarts=0"*) report PASS container "$state" ;;
      *) report WARN container "$state (restarts > 0: check 'docker logs $CONTAINER')" ;;
    esac ;;
  *) [ -n "$state" ] && report FAIL container "$state — docker start $CONTAINER && docker logs $CONTAINER" ;;
esac

# 3. the pre-fix gitlink regression
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  if git ls-files -s hermes-agent 2>/dev/null | grep -q '^160000'; then
    report FAIL gitlink "hermes-agent is still a mode-160000 gitlink with no .gitmodules — commit the fix or re-clone"
  else
    report PASS gitlink "hermes-agent is a real directory"
  fi
fi
if [ -f .env ]; then report PASS env-file ".env present"; else report WARN env-file "no .env — start-hermes.sh will create one from .env.example"; fi
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  report FAIL git-hygiene ".env is TRACKED in git — it may hold API keys. git rm --cached .env"
else
  report PASS git-hygiene ".env untracked"
fi

# 4. drop zone + index (this is what keeps prompts cheap)
if [ ! -d "$DROPZONE" ]; then
  report FAIL dropzone "'$DROPZONE' missing — mkdir it and symlink your projects in"
else
  n="$(find "$DROPZONE" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] && report PASS dropzone "$n project(s) in $DROPZONE" \
                      || report WARN dropzone "empty — Hermes will answer 'not in the indexed workspace'"
  if [ -f "$DROPZONE/INDEX.md" ]; then
    if ./scripts/hermes-index.sh --check --quiet 2>/dev/null; then
      report PASS index "INDEX.md up to date ($(wc -c < "$DROPZONE/INDEX.md" | tr -d ' ') bytes)"
    else
      report WARN index "INDEX.md stale — ./scripts/hermes-index.sh"
    fi
  else
    report WARN index "no INDEX.md — run ./scripts/hermes-index.sh (saves ~10k+ prompt tokens)"
  fi
  if [ -e "$DROPZONE/AGENTS.md" ]; then report PASS agents-md "drop-zone persona present"
  else report WARN agents-md "no $DROPZONE/AGENTS.md — Hermes has no role instructions"; fi
fi

# 5. inside the container: hermes reachable, provider configured, prompt size sane
if docker exec "$CONTAINER" hermes --version >/dev/null 2>&1; then
  report PASS hermes-cli "$(docker exec "$CONTAINER" hermes --version 2>/dev/null | head -1)"
  cwd="$(clean "$(docker exec "$CONTAINER" hermes config get terminal.cwd 2>/dev/null || true)")"
  case "$cwd" in
    ""|".") report WARN terminal.cwd "'${cwd:-<unset>}' — should be /workspace/projects (./start-hermes.sh --local-llm sets it)" ;;
    *) report PASS terminal.cwd "$cwd" ;;
  esac
  base="$(clean "$(docker exec "$CONTAINER" hermes config get model.base_url 2>/dev/null || true)")"
  prov="$(clean "$(docker exec "$CONTAINER" hermes config get model.provider 2>/dev/null || true)")"
  if [ -n "$base" ]; then report PASS provider "${prov:-?} @ $base"
  else report WARN provider "no model.base_url configured — run ./start-hermes.sh --local-llm or 'docker exec -it $CONTAINER hermes model'"; fi
  ps="$(docker exec "$CONTAINER" hermes prompt-size 2>/dev/null | tail -3 | tr '\n' ' ' || true)"
  if [ -n "$ps" ]; then
    case "$ps" in
      *Total*1[0-9][0-9][0-9][0-9]*) report WARN prompt-size "$ps (>10k tokens is heavy for CPU)" ;;
      *) report PASS prompt-size "${ps:-unknown}" ;;
    esac
  fi
else
  [ "${state#*running}" != "$state" ] && report FAIL hermes-cli "container runs but 'hermes' is not exec-able — docker logs $CONTAINER"
fi

# 6. the Ollama trap that made the agent "forget" its instructions
host="$(printf '%s' "${base:-}" | sed -E 's#https?://([^/:]+).*#\1#')"
if [ -n "$host" ] && docker exec "$CONTAINER" hermes --version >/dev/null 2>&1; then
  if docker exec "$CONTAINER" curl -fsS -m 5 "${base%/}/models" >/dev/null 2>&1; then
    report PASS inference-reach "GET ${base%/}/models OK"
  else
    report FAIL inference-reach "cannot reach $base from inside the container.
        'host.docker.internal' + Ollama bound to 127.0.0.1 is the usual cause:
          host:      OLLAMA_HOST=0.0.0.0 systemctl --user restart ollama
          or better: ./start-hermes.sh --local-llm   (sidecar on the same network)"
  fi
fi

# 6b. the sidecar's context window — checked whether or not the provider is wired yet,
#     because an unbounded default truncates the agent silently on the very first turn.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx hermes_ollama; then
  ctx="$(docker exec hermes_ollama printenv OLLAMA_CONTEXT_LENGTH 2>/dev/null | tr -d '[:space:]' || true)"
  case "${ctx:-}" in
    ""|0) report FAIL ollama-ctx "OLLAMA_CONTEXT_LENGTH unset -> Ollama truncates the Hermes system prompt
        at its default window and the agent starts hallucinating a generic chatbot.
        Fix: set OLLAMA_CONTEXT_LENGTH=16384 in .env, then
             docker compose up -d --force-recreate ollama" ;;
    *) if [ "${ctx:-0}" -lt 8192 ] 2>/dev/null; then
         report WARN ollama-ctx "OLLAMA_CONTEXT_LENGTH=$ctx is small for an agent system prompt (use >= 16384)"
       else
         report PASS ollama-ctx "OLLAMA_CONTEXT_LENGTH=$ctx (verify live: docker exec hermes_ollama ollama ps -> CONTEXT column)"
       fi ;;
  esac
  printf '        note: OLLAMA_NUM_CTX is a legacy name — current releases ignore it, and the\n'
  printf '              OpenAI-compatible /v1 endpoint drops num_ctx entirely. Hermes uses /v1.\n'
fi

# 7. transport sanity
case "$TRANSPORT" in
  docker) report PASS transport "docker exec (default; no port, no key)" ;;
  http)
    key="$(get_env HERMES_API_KEY | tr -d '"')"
    if [ -z "$key" ] || [ "$key" = "change-me-local-dev" ]; then
      report FAIL transport "HERMES_TRANSPORT=http but HERMES_API_KEY is empty/placeholder"
    else
      report PASS transport "http + API key set (remember API_SERVER_ENABLED=true in the container env)"
    fi ;;
  *) report FAIL transport "unknown HERMES_TRANSPORT '$TRANSPORT' (docker|http)" ;;
esac

echo
printf 'summary: %d pass, %d warn, %d fail\n' "$pass" "$warn" "$fail"
[ "$fail" -gt 0 ] && exit 1
exit 0
