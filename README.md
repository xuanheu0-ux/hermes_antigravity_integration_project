# Hermes + Antigravity 2.0 integration project

Launchpad for running **Hermes** ([Nous Research's agent](https://hermes-agent.nousresearch.com/docs/),
`nousresearch/hermes-agent`) inside a sandboxed Docker container as this machine's
read-only repository indexer and local knowledge bot, and for querying it from
**Antigravity 2.0** with a single `/hermes` command.

```
Antigravity 2.0 (IDE / `agy` CLI)
   │  /hermes <question>              .agents/workflows/hermes.md  (+ .agents/skills/hermes/SKILL.md)
   ▼
scripts/hermes-ask.sh ────────────────┐
   │ docker exec (default)           │ optional: HTTP POST 127.0.0.1:8642/v1/chat/completions
   ▼                                 ▼
┌── container: hermes_local ─────────────────────────────────────────┐
│ s6-overlay /init  →  hermes gateway run   (HERMES_HOME=/opt/data)  │
│ hermes -z "<question>"  →  agent reads /workspace/projects         │
└───────────────┬───────────────────────────────┬────────────────────┘
                │ read-only                     │ OpenAI-compatible /v1
                ▼                               ▼
   ./hermes_shared_workspace/            Ollama (sidecar container
   ├── AGENTS.md      ← persona         --profile local-llm-- or host)
   ├── INDEX.md       ← cheap map       OLLAMA_CONTEXT_LENGTH=16384
   └── my-project → symlink
```

## Why this exists

You keep many small projects (`vscode/*`, PLC/CAD/hydro-power repos, agent experiments).
An IDE agent only sees the current workspace. Hermes sees **all** of them at once and
answers cross-repo questions — "which of my repos already parses an EVN hourly meter
frame?", "what convention do I use for config in Dien-sc?", "compare the architecture of
X and Y" — with citations. Everything stays local: an optional Ollama model, no cloud key,
read-only mounts, no source leaves the machine.

## Quick start

```bash
cp .env.example .env            # 1. set HERMES_DROPZONE and (optionally) OLLAMA_MODEL
mkdir -p hermes_shared_workspace
ln -s ~/Documents/vscode/Dien-sc hermes_shared_workspace/   # 2. symlink ONLY what Hermes needs
ln -s ~/Documents/vscode/EVN_BaoCaoVanHanhThuyDien hermes_shared_workspace/

./start-hermes.sh --local-llm   # 3. preflight, index, build/pull, start, wire provider
./start-hermes.sh --check       # 4. health report of the whole chain
./scripts/hermes-ask.sh "what do my indexed projects have in common?"
```

Then in Antigravity 2.0's chat (this folder opened as the workspace):

```
/hermes which of my projects has reusable Modbus parsing?
```

If this is the first boot, Hermes still needs its provider chosen interactively:

```bash
docker exec -it hermes_local hermes setup     # Custom endpoint → http://ollama:11434/v1
                                              # (or http://host.docker.internal:11434/v1)
```

`--local-llm` writes that endpoint for you; the wizard remains the way to add a cloud key.

## Flags

| Command | Effect |
|---|---|
| `./start-hermes.sh` | pull-based start (no local build), seeds + indexes the drop zone |
| `./start-hermes.sh --local-llm` | + Ollama sidecar on the same Docker network, pulls `OLLAMA_MODEL`, points Hermes at `http://ollama:11434/v1` |
| `./start-hermes.sh --build` | build the derived image from `hermes-agent/Dockerfile` |
| `./start-hermes.sh --reindex` | rebuild `hermes_shared_workspace/INDEX.md` and exit |
| `./start-hermes.sh --check` | `scripts/hermes-doctor.sh` (read-only) |
| `./start-hermes.sh --logs` / `--down` | compose logs / compose down |

## Configuration (`.env`)

| Key | Default | Notes |
|---|---|---|
| `HERMES_DROPZONE` | `./hermes_shared_workspace` | host dir mounted read-only at `/workspace/projects`. **Keep it small and symlink-based.** |
| `HERMES_CONTAINER` | `hermes_local` | used by every script |
| `HERMES_IMAGE` / `HERMES_IMAGE_TAG` | `nousresearch/hermes-agent` / `latest` | pin a tag once it works |
| `HERMES_TRANSPORT` | `docker` | `docker` (no port, no key) or `http` (gateway API server) |
| `HERMES_WORKSPACE` | `/workspace/projects` | cwd passed to `hermes --in` |
| `HERMES_TIMEOUT` | `300` | seconds; CPU inference is slow — raise before assuming a hang |
| `HERMES_API_ENABLED` / `HERMES_API_KEY` / `HERMES_API_PORT` | `false` / — / `8642` | only for `http`; key must be ≥ 8 chars (`openssl rand -hex 32`) |
| `OLLAMA_MODEL` | `llama3.2:3b` | edge model that fits the CPU box in the session log |
| `OLLAMA_CONTEXT_LENGTH` | `16384` | **not** `OLLAMA_NUM_CTX` (see gotchas) |
| `HERMES_DASHBOARD` | `0` | `1` → web UI on `127.0.0.1:9119` |
| `HERMES_UID` / `HERMES_GID` | `10000` | set to `id -u`/`id -g` only when `/opt/data` is a host bind mount |
| `GEMINI_API_KEY` | empty | optional cloud escape hatch; not used by the local path |

## Gotchas this repo has actually hit

1. **`hermes-agent` was a dangling gitlink** (index mode `160000`, no `.gitmodules`, the
   pointed-at commit did not exist). A fresh clone therefore produced an *empty*
   `hermes-agent/`, so `docker compose build` failed with
   `failed to read dockerfile` and `git submodule update --init` died with
   `no submodule mapping found in .gitmodules`. Fixed by committing a real
   `hermes-agent/` directory and defaulting to the official image.
2. **`.hermesignore` does nothing on its own.** It was never implemented upstream
   (`NousResearch/hermes-agent` issues #502 / #681 / #50165 are open proposals; a code
   search for *hermesignore* in that repo returns 0 hits). The prompt-size fix in
   `2026-06-02/summary.md` §4 worked because `terminal.cwd` was narrowed, not because the
   file was read. Here the real mechanism is `scripts/hermes-index.sh` → one small
   `INDEX.md` instead of a ~400 k-file walk.
3. **`OLLAMA_NUM_CTX` is a legacy name** and is ignored by current releases; the
   OpenAI-compatible `/v1` endpoint that Hermes talks to drops `num_ctx` entirely. Set
   `OLLAMA_CONTEXT_LENGTH` server-side (done in `docker-compose.yml`) and confirm with
   `docker exec hermes_ollama ollama ps` → `CONTEXT` column. Too small = the agent's system
   prompt is truncated and it "forgets" who it is.
4. **Ollama on the host listens on `127.0.0.1`**, which a container cannot reach →
   `connection refused`. Either run Ollama with `OLLAMA_HOST=0.0.0.0`, or use
   `--local-llm` and let Hermes address the sidecar by name (`http://ollama:11434/v1`).
5. **No `command:` + `restart: unless-stopped`** ⇒ the container exit-loops. The compose
   file now runs the supervised `gateway run`.
6. **Overriding `entrypoint:`** removes s6 supervision and the zombie reaper. Don't.
7. **Hard-coded `/home/matt/…`** meant a non-matt user silently got an empty root-owned
   directory instead of their projects. The drop zone is now a `.env` variable that
   defaults inside the repo.

## Recovery: an old clone (before this fix)

```bash
git rm --cached hermes-agent           # drop the stale gitlink entry
git fetch && git reset --hard origin/main
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no submodule mapping found in .gitmodules for path 'hermes-agent'` | pre-fix checkout | section above |
| `failed to read dockerfile: … hermes-agent/Dockerfile` | same, and `--build` without the overlay file | drop `--build`, or pull this branch |
| `env file … ./.env not found` | `.env` missing | `cp .env.example .env` (or run `./start-hermes.sh`) |
| container restarts constantly, `docker logs` shows an exit | old compose without `command:` | keep `command: ["gateway","run"]` |
| `Permission denied` on `/opt/data` | UID mismatch on a bind mount | set `HERMES_UID`/`HERMES_GID` to `id -u`/`id -g` |
| `connection refused` to `:11434` | Ollama bound to loopback / not on the network | `--local-llm`, or `OLLAMA_HOST=0.0.0.0` on the host |
| agent answers generically, ignores instructions | context truncation | raise `OLLAMA_CONTEXT_LENGTH`, restart `ollama` |
| first token takes minutes | CPU model + huge prompt | `hermes prompt-size`, shrink the drop zone, keep `INDEX.md` fresh |
| "I don't know that project" | index stale/missing | `./start-hermes.sh --reindex` |
| `hermes-ask.sh: container … not found` (rc 3) | stack down | `./start-hermes.sh` |
| `/hermes` absent from Antigravity's `/` menu | workspace root not opened, or pre-2.0 path | open this folder as the workspace; older builds read `.agent/workflows/` instead of `.agents/workflows/` |

Diagnostics in one line: `./start-hermes.sh --check` (exit 1 = at least one FAIL).

## Notes on the Antigravity side

- Workflows (`.agents/workflows/*.md`) are being deprecated in favour of **Agent Skills**
  (`.agents/skills/<name>/SKILL.md`) around **1 Nov 2026**, so this repo ships both and they
  run the same script. Keep the skill as the source of truth if you edit one.
- Older Antigravity builds look for `.agent/` (singular). If your `/hermes` menu is empty,
  copy the two directories across — the file format is identical.
- Global scope instead of per-workspace: symlink `.agents/workflows/hermes.md` (or the
  skill directory) into `~/.gemini/…` and the command works in every project.

## Khắc phục sự cố (tiếng Việt)

- **Clone cũ không build được:** lỗi do `hermes-agent` từng được commit dưới dạng
  gitlink (`160000`) mà không có `.gitmodules` → thư mục rỗng, không có `Dockerfile`.
  Đã sửa: commit thư mục `hermes-agent/` thật + mặc định dùng image chính thức.
  Clone cũ thì chạy `git rm --cached hermes-agent` rồi `git reset --hard origin/main`.
- **Hermes "quên" chỉ dẫn / trả lời lan man:** hệ ngữ cảnh của Ollama bị cắt. Đặt
  `OLLAMA_CONTEXT_LENGTH=16384` (không dùng `OLLAMA_NUM_CTX` — biến này đã bị bỏ),
  sau đó `docker compose up -d --force-recreate ollama`, kiểm chứng bằng
  `docker exec hermes_ollama ollama ps` (cột `CONTEXT`).
- **`connection refused`:** Ollama trên máy chỉ nghe ở `127.0.0.1`. Dùng
  `./start-hermes.sh --local-llm` để chạy Ollama cùng mạng Docker với Hermes.
- **Một token đầu tiên mất hàng phút:** prompt phình do index cả thư mục lớn.
  Giữ `hermes_shared_workspace` chỉ gồm symlink tới vài repo, chạy
  `./scripts/hermes-index.sh` (file `.hermesignore` chỉ được script này đọc — Hermes
  chưa hỗ trợ nó), và audit bằng `docker exec hermes_local hermes prompt-size`.
- **Gọi Hermes:** `./scripts/hermes-ask.sh "câu hỏi"` hoặc trong Antigravity gõ
  `/hermes "câu hỏi"`. Mã lỗi: 3 = container chưa chạy, 2 = lượt chạy thất bại/hết giờ,
  1 = không có câu trả lời, 4 = thiếu cấu hình.

## References

- Hermes in Docker (official image contract, `/opt/data`, s6 supervision, UID remap):
  <https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/docker.md>
- CLI one-shot (`hermes -z`) and `hermes config`:
  <https://hermes-agent.nousresearch.com/docs/reference/cli-commands>
- Context files (`AGENTS.md`, `context_file_max_chars`):
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/context-files>
- OpenAI-compatible API server (port 8642):
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server>
- Antigravity skills/workflows/rules: <https://antigravity.google/docs/ide/workflows/>
- `.hermesignore` status upstream: issues [#502](https://github.com/NousResearch/hermes-agent/issues/502),
  [#681](https://github.com/NousResearch/hermes-agent/issues/681),
  [#50165](https://github.com/NousResearch/hermes-agent/issues/50165)
