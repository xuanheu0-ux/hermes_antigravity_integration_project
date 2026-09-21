#!/usr/bin/env bash
# start-hermes.sh — preflight + bootstrap for the Hermes container and its drop zone.
#
# It exists because the bare `docker compose up --build -d` this repo used to run could
# not work: the image was built from ./hermes-agent, which was a *dangling gitlink*
# (mode 160000, no .gitmodules, no Dockerfile). This script now:
#   1. verifies Docker + Compose v2 are usable at all,
#   2. creates .env (compose hard-fails on a missing env_file),
#   3. refuses to start against a pre-fix checkout, with the repair command,
#   4. seeds and indexes the drop zone (the real fix for the CPU/prompt-size problem),
#   5. starts the stack, waits for readiness, and wires the model provider,
#   6. tells you exactly what to run next.
#
# Usage:
#   ./start-hermes.sh                 # pull-based start (default)
#   ./start-hermes.sh --local-llm     # + Ollama sidecar on the same network
#   ./start-hermes.sh --build         # build the derived image (hermes-agent/Dockerfile)
#   ./start-hermes.sh --check         # doctor + prompt-size + provider reachability
#   ./start-hermes.sh --reindex       # rebuild drop-zone INDEX.md and exit
#   ./start-hermes.sh --logs | --down
set -eu

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_RED=""; C_YEL=""; C_GRN=""; C_OFF=""; }
usage() {
  cat <<'EOF'
usage: ./start-hermes.sh [flag]

  (no flag)        pull the official image, seed + index the drop zone, start the stack
  --local-llm      also run an Ollama sidecar (compose profile), pull the model,
                   and point Hermes at http://ollama:11434/v1
  --build          build the derived image from hermes-agent/Dockerfile first
  --no-pull        with --local-llm: skip `ollama pull`
  --reindex        rebuild hermes_shared_workspace/INDEX.md and exit
  --check          run scripts/hermes-doctor.sh against the running container
  --logs           docker compose logs -f
  --down           docker compose down
EOF
}

err() { printf '%s\n' "${C_RED}error:${C_OFF} $*" >&2; }
warn() { printf '%s\n' "${C_YEL}warn:${C_OFF}  $*" >&2; }
ok()   { printf '%s\n' "${C_GRN}ok:${C_OFF}    $*"; }
die()  { err "$1"; exit "${2:-1}"; }

BUILD=0; LOCAL_LLM=0; MODE=start; PULL=1; BUILD_FLAG=""
for a in "$@"; do
  case "$a" in
    --build)       BUILD=1; BUILD_FLAG="--build" ;;
    --local-llm)   LOCAL_LLM=1 ;;
    --no-pull)     PULL=0 ;;
    --check)       MODE=check ;;
    --reindex)     MODE=reindex ;;
    --logs)        MODE=logs ;;
    --down)        MODE=down ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown flag: $a (see --help)" ;;
  esac
done

# ---------------------------------------------------------------- env + compose plumbing
if [ ! -f .env ] && [ "$MODE" = start ]; then
  cp .env.example .env
  warn "created .env from .env.example — review HERMES_DROPZONE and the provider settings"
fi
# Values we need before Docker is even touched. Parsed, not sourced: .env is data.
read_env() {   # read one KEY from .env as plain data (no sourcing, no eval)
  local line val
  [ -f .env ] || return 0
  line="$(grep -E "^[[:space:]]*$1[[:space:]]*=" .env | tail -1 || true)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"          # ltrim
  val="${val%"${val##*[![:space:]]}"}"          # rtrim
  val="${val%\"}"; val="${val#\"}"                    # strip a matched double-quote pair
  printf '%s' "$val"
}

# Precedence: process env > .env > built-in default (so a caller can override per run).
pick() {   # pick <KEY> <default>
  local name="$1" def="$2" v
  v="${!name:-}"; [ -n "$v" ] || v="$(read_env "$name")"; [ -n "$v" ] || v="$def"
  printf '%s' "$v"
}
CONTAINER="$(pick HERMES_CONTAINER hermes_local)"
DROPZONE="$(pick HERMES_DROPZONE ./hermes_shared_workspace)"
case "$DROPZONE" in /*) : ;; *) DROPZONE="./${DROPZONE#./}" ;; esac
OLLAMA_MODEL="$(pick OLLAMA_MODEL llama3.2:3b)"
compose_args=()
[ "$BUILD" = 1 ] && compose_args+=( -f docker-compose.yml -f docker-compose.build.yml )
[ "$LOCAL_LLM" = 1 ] && compose_args+=( --profile local-llm )
compose() {   # docker compose [overlay flags] <subcommand...>
  docker compose ${compose_args[@]+"${compose_args[@]}"} "$@"
}

# ------------------------------------------------------------------- mode: quick actions
case "$MODE" in
  reindex) exec ./scripts/hermes-index.sh ;;
  logs)    exec compose logs -f "$CONTAINER" ;;
  down)    exec compose down ;;
esac

# ---------------------------------------------------------------------- 1. preflight
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH.
  Install Docker Engine (Linux): https://docs.docker.com/engine/install/
  On macOS/Windows use Docker Desktop, and make sure its VM is running."
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable (is Docker running? are you in the 'docker' group?)
  try: sudo usermod -aG docker \$USER  → then re-login"
docker compose version >/dev/null 2>&1 || die "the 'docker compose' (v2) plugin is missing.
  This project deliberately does not support the legacy 'docker-compose' binary:
  the June 2026 session log already migrated to the v2 syntax (2026-06-02/summary.md §1)."
ok "docker + compose v2 ready ($(docker compose version --short 2>/dev/null | head -1))"

# ------------------------------------------------- 2. guard against the pre-fix checkout
# The bug: `git ls-files -s hermes-agent` reported mode 160000 (a submodule pointer with
# no .gitmodules) => every fresh clone got an EMPTY hermes-agent/ => no Dockerfile =>
# `docker compose build` failed before doing anything useful.
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  if git ls-files -s hermes-agent 2>/dev/null | grep -q '^160000'; then
    die "your checkout still has the broken 'hermes-agent' gitlink (this was fixed on
  branch arena/01a0c325 — see README 'Recovering an old clone'). Repair with:
      git rm --cached hermes-agent && git checkout -- hermes-agent"
  fi
fi
if [ "$BUILD" = 1 ] && [ ! -f hermes-agent/Dockerfile ]; then
  die "--build asked for a local image but hermes-agent/Dockerfile is missing.
  Run without --build to use the official upstream image instead."
fi

# ------------------------------------------------------------- 3. read-only diagnostics
if [ "$MODE" = check ]; then
  exec ./scripts/hermes-doctor.sh
fi

# ------------------------------------------------------------ 4. drop zone (the "vault")
if [ ! -d "$DROPZONE" ]; then
  mkdir -p "$DROPZONE" && ok "created drop zone $DROPZONE"
fi
for f in AGENTS.md .hermesignore; do
  if [ ! -e "$DROPZONE/$f" ] && [ -e "hermes-agent/dropzone/$f" ]; then
    cp "hermes-agent/dropzone/$f" "$DROPZONE/$f" && ok "seeded $DROPZONE/$f"
  fi
done
n_projects="$(find "$DROPZONE" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null | wc -l | tr -d ' ')"
if [ "${n_projects:-0}" = 0 ]; then
  warn "drop zone is empty — Hermes will know nothing about your projects.
  Add the repos you want indexed as SYMLINKS (never the whole ~/Documents/vscode:
  that is what made first-token latency ~3 min on your CPU):
      ln -s ~/Documents/vscode/my-project '$DROPZONE/'"
fi
ok "rebuilding drop-zone index (keeps the system prompt small)"
./scripts/hermes-index.sh --quiet || warn "indexer failed — Hermes will walk files itself (non-fatal, but slow)"

# ---------------------------------------------------------------------- 5. bring it up
printf '%s\n' "→ compose ${compose_args[*]:-up} ..."
compose config -q 2>/dev/null || die "docker-compose.yml does not validate — run: docker compose config"
compose up -d ${BUILD_FLAG:+$BUILD_FLAG}
ok "stack started (container: $CONTAINER)"

# --------------------------------------------- 6. wait for hermes to be exec-able + seed
# s6's stage2 hook seeds .env/config.yaml on first boot; exec too early and you write a
# config that the hook then ignores. Poll the binary instead of sleeping a fixed time.
i=0
until docker exec "$CONTAINER" hermes --version >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { warn "hermes not answering inside $CONTAINER yet — check: compose logs $CONTAINER"; break; }
  sleep 2
done

if [ "$LOCAL_LLM" = 1 ]; then
  # The model must exist in Ollama before Hermes can use it.
  if [ "$PULL" = 1 ] && docker ps --format '{{.Names}}' | grep -qx hermes_ollama; then
    if ! docker exec hermes_ollama sh -c "ollama list | grep -q '^${OLLAMA_MODEL%%:*}'" 2>/dev/null; then
      printf '%s\n' "→ pulling $OLLAMA_MODEL into the ollama sidecar (one time; ~2 GB is slow on wifi)..."
      docker exec hermes_ollama ollama pull "$OLLAMA_MODEL" || warn "ollama pull failed — retry: docker exec hermes_ollama ollama pull $OLLAMA_MODEL"
    else
      ok "ollama already has $OLLAMA_MODEL"
    fi
  fi
  # Point Hermes at the SIDECAR by container name. 127.0.0.1 would be the Hermes
  # container itself and host.docker.internal only works if host Ollama listens on
  # 0.0.0.0 — both are classic "connection refused" traps.
  printf '%s\n' "→ wiring Hermes to http://ollama:11434/v1 ($OLLAMA_MODEL)"
  docker exec "$CONTAINER" hermes config set model.provider custom >/dev/null 2>&1 || true
  docker exec "$CONTAINER" hermes config set model.base_url "http://ollama:11434/v1" >/dev/null 2>&1 || true
  docker exec "$CONTAINER" hermes config set model.default "$OLLAMA_MODEL" >/dev/null 2>&1 || true
  docker exec "$CONTAINER" hermes config set model.api_key none >/dev/null 2>&1 || true
fi

# ------------------------------- 6b. prompt-size guardrails (any provider, idempotent) --
# Same two settings the derived image seeds, applied here too so the default
# pull-based path gets the benefit: scope the session to the drop zone, and cap how much
# of an injected context file can land in the prompt. Audit with `hermes prompt-size`.
if docker exec "$CONTAINER" hermes --version >/dev/null 2>&1; then
  if [ "$(docker exec "$CONTAINER" hermes config get terminal.cwd 2>/dev/null | tr -d '[:space:]')" = "/workspace/projects" ]; then
    ok "terminal.cwd already scoped to /workspace/projects"
  else
    docker exec "$CONTAINER" hermes config set terminal.cwd /workspace/projects >/dev/null 2>&1 \
      && ok "terminal.cwd -> /workspace/projects (this, not .hermesignore, is what shrinks the prompt)" \
      || warn "could not set terminal.cwd; run: docker exec $CONTAINER hermes config set terminal.cwd /workspace/projects"
  fi
  case "$(docker exec "$CONTAINER" hermes config get context_file_max_chars 2>/dev/null | tr -d '[:space:]')" in
    ""|None|null|0) docker exec "$CONTAINER" hermes config set context_file_max_chars 6000 >/dev/null 2>&1 \
                      && ok "context_file_max_chars -> 6000 (one giant AGENTS.md can no longer eat the context window)" ;;
    *) : ;;
  esac
fi

cat <<NEXT

${C_GRN}Hermes is up.${C_OFF}  Next steps
  chat interactively   docker exec -it $CONTAINER hermes
  first-run wizard     docker exec -it $CONTAINER hermes setup
                       (provider 'Custom endpoint' → http://host.docker.internal:11434/v1
                        or http://ollama:11434/v1 with --local-llm; model = a tag 'ollama list' shows)
  index + doctor       ./start-hermes.sh --reindex && ./start-hermes.sh --check
  from Antigravity 2.0 type   /hermes <question>   (see .agents/skills/hermes/SKILL.md)
  test the bridge now  ./scripts/hermes-ask.sh "list the projects you can see"

Projects are mounted READ-ONLY at /workspace/projects inside $CONTAINER.
Answers may take a while on CPU-only inference — that is the model, not a hang.
NEXT
