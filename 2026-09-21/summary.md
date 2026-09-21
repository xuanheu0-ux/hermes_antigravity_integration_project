# Summary of Work: September 21, 2026

## "kiểm tra và sửa lỗi: tạo Hermes với Antigravity 2.0"

Full audit of the launchpad, then a rewrite of the parts that could never have worked.
Every claim below was verified against the upstream `NousResearch/hermes-agent` repo/docs
and against Ollama's current variable names, not from memory.

### 1. Blocker: the project could not be built at all

`hermes-agent` was committed as a **gitlink** (`git ls-files -s` → mode `160000`, pointing
at commit `1ffa22ee`, which does not exist in this repo) with **no `.gitmodules`**. Typical
cause: `git init` was run inside `hermes-agent/` and the nested repo got committed instead
of its files.

Consequences, all reproduced locally:

- `git submodule status` → `fatal: no submodule mapping found in .gitmodules for path 'hermes-agent'`
- `git clone` → `hermes-agent/` empty → `docker-compose.yml`'s `build.context` had no `Dockerfile`
- therefore `./start-hermes.sh` (`docker compose up --build -d`) failed before starting anything

Fix: `git rm --cached hermes-agent`, then committed a real `hermes-agent/` directory. The
default runtime path is now the **official image** (`nousresearch/hermes-agent`) — upstream's
own Dockerfile is a multi-stage build with an immutable `/opt/hermes` tree, so rebuilding it
here has no upside — and `docker-compose.build.yml` + `hermes-agent/Dockerfile` remain as the
explicit opt-in for a derived image (seeding only).

### 2. Compose rewrite (each change maps to a failure mode)

| Was | Now | Why |
|---|---|---|
| `version: '3.8'` | removed | obsolete key, warns under Compose v2 |
| no `command:` | `command: ["gateway","run"]` | the image's default CMD exits instantly → `restart: unless-stopped` crash-loop; `gateway run` is the s6-supervised heartbeat pattern from upstream docs |
| `build:` only | `image:` + optional overlay | buildable out of the box, customisable on request |
| `8080:8080`, `8000:8000` | `127.0.0.1:8642`, `127.0.0.1:9119` | the old ports served nothing and were world-published; 8642 is the real OpenAI-compatible API, 9119 the dashboard, both loopback-only because `/opt/data` holds keys |
| `/home/matt/Documents/vscode/…` | `${HERMES_DROPZONE:-./hermes_shared_workspace}` | for any other user Docker silently created an empty root-owned dir — the "Hermes remembers nothing" symptom |
| projects mounted under `/opt/data` | `/workspace/projects:ro` | `HERMES_HOME` is size-checked and must stay lean; `:ro` enforces the "read-only librarian" promise made in the README |
| no `HERMES_UID/GID` | set (defaults 10000) | upstream's stage2 hook chowns `/opt/data`; bind mounts need the host UID or you get `Permission denied` |
| no `healthcheck`, no limits | healthcheck + `deploy.resources.limits` | matches the upstream Docker sizing table (2 GB / 2 CPU minimum for this use) |
| host Ollama assumed | optional `ollama` service under `--profile local-llm` | host Ollama binds `127.0.0.1`, unreachable from a container → the "connection refused" trap |

### 3. The `.hermesignore` myth (real bug, not a typo)

`2026-06-02/summary.md` §4 credits an aggressive `.hermesignore` with the CPU fix. It does
nothing: `.hermesignore` exists only as an unimplemented proposal upstream
(issues #502, #681, #50165; a code search for `hermesignore` in `NousResearch/hermes-agent`
returns **0 hits**). The file is now honestly scoped: it is the input to
`scripts/hermes-index.sh`, which produces one small `INDEX.md` per drop zone (project list,
file counts, detected stack, git head, key files) so the agent reads a few KB instead of
walking hundreds of thousands of paths. `.hermesignore` is a symlink to the single canonical
copy in `hermes-agent/dropzone/` so the repo and the container can never diverge.

### 4. The Ollama truncation fix was also a no-op

The systemd override used `OLLAMA_NUM_CTX`. That variable name is legacy, and — the part that
matters here — Hermes talks to Ollama's OpenAI-compatible `/v1`, which drops the request's
`num_ctx` entirely, so only a **server-side** value wins. The compose sidecar therefore sets
`OLLAMA_CONTEXT_LENGTH` (default 16384) and `hermes-doctor.sh` FAILs if it is unset, with the
`ollama ps` → `CONTEXT` verification command printed.

### 5. Antigravity 2.0 `/hermes` slash command — implemented, not just promised

The previous commit message announced a "slash command protocol" that had no files behind it.
Now: `.agents/skills/hermes/SKILL.md` (Skills are the path forward; workflows are deprecated
around 2026-11-01), `.agents/workflows/hermes.md` (`/hermes <question>` for current builds),
`.agents/rules/hermes.md` (always-on bridge facts), root `AGENTS.md`, and the actual bridge
`scripts/hermes-ask.sh`. Both entry points call one script so behaviour, timeouts and exit
codes cannot drift apart. Transport defaults to `docker exec … hermes -z` (pure one-shot: no
banner, no port, no key) with an opt-in HTTP transport against the gateway API server.

### 6. Scripts (and how they were tested without Docker)

`start-hermes.sh` (preflight → `.env` → gitlink regression guard → drop-zone seeding →
indexing → `compose config` validation → up → readiness poll → provider wiring),
`scripts/hermes-index.sh`, `scripts/hermes-ask.sh`, `scripts/hermes-doctor.sh`.

A mock `docker` on `PATH` exercised all four end to end and caught four real bugs in the new
code: a `compose()` helper that lost the literal word `compose`; `${BUILD:+--build}` firing
for `BUILD=0`; `report()` returning non-zero and double-reporting every doctor check; and
`.env` values overriding the caller's environment instead of the reverse. The indexer was
verified against a synthetic drop zone (symlinked projects, `node_modules` with 120 files,
`.git`, `venv`, `.env`/`.env.production`, a git repo) — ignored paths excluded, stack
detection (node/python/embedded) correct, `--check` transitions fresh→stale as expected,
re-runs are idempotent, and the `.env` parser was proven inert against `$(...)` injection.

### 7. Docs

README rewritten around how it actually works (diagram, flags, `.env` table, "Gotchas this
repo has actually hit", troubleshooting table, Vietnamese section). `Useful commands` (a
space-named, extension-less file) became `COMMANDS.md` with the raw `docker` equivalents.
A corrections block was prepended to the June log rather than rewriting history.
`.env.example` was still Gemini-only; it now leads with the local path the project actually
migrated to, and documents the transport/API keys.

### 8. Still open / honest limits

- First boot still needs `docker exec -it hermes_local hermes setup` unless `--local-llm`
  wired the endpoint; a 3B CPU model answers slowly and shallowly by nature.
- `hermes serve`/dashboard auth: loopback only, deliberately not exposed. A LAN dashboard
  would need an auth provider per upstream's June-2026 hardening.
- If upstream ships `.hermesignore` for real, `scripts/hermes-index.sh` becomes optional and
  `INDEX.md` should shrink to a project list — noted in the file header.
- `.agents/` vs `.agent/`: shipped under `.agents/` (2.0 layout); README documents the copy
  needed for older builds. Not auto-symlinked to avoid loading every rule twice.
