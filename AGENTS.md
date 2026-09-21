# AGENTS.md

Instructions for any coding agent working in this repository (Antigravity, Hermes, or
anything else that reads `AGENTS.md`).

## What this repo is

The integration layer between **Google Antigravity 2.0** (IDE / CLI) and **Hermes Agent**
(Nous Research) running as a containerised, read-only knowledge base of this machine's other
projects. It contains no application code of its own: it is Docker wiring, a shell bridge,
and the agent-facing instruction files.

## Layout (each file has one job — do not merge them)

| Path | Role |
|---|---|
| `docker-compose.yml` | runtime stack: Hermes container (+ optional Ollama sidecar under the `local-llm` profile) |
| `docker-compose.build.yml` | opt-in overlay that builds the derived image in `hermes-agent/` |
| `hermes-agent/Dockerfile` | thin overlay on the official image (no Hermes rebuild) |
| `hermes-agent/docker/cont-init.d/90-hermes-dropzone` | first-boot seeding, run by s6 as root, must never fail the boot |
| `hermes-agent/dropzone/AGENTS.md` | the **persona** Hermes loads when its cwd is the drop zone |
| `hermes-agent/dropzone/.hermesignore` | the indexer's ignore list (NOT a Hermes feature — see rules) |
| `scripts/hermes-ask.sh` | the bridge: one question in, one answer out |
| `scripts/hermes-index.sh` | builds `<dropzone>/INDEX.md` so prompts stay small |
| `scripts/hermes-doctor.sh` | reads-only health report of the whole chain |
| `.agents/skills/hermes/SKILL.md` | Antigravity 2.0 skill (`/hermes`, and the post-Nov-2026 path) |
| `.agents/workflows/hermes.md` | Antigravity workflow form of the same command (deprecated upstream Nov 1 2026) |
| `.agents/rules/hermes.md` | always-on bridge facts for the IDE agent |
| `start-hermes.sh` | preflight + bootstrap; the only entry point users should need |
| `2026-*/summary.md` | session logs, in date order |

## Working rules

- **Shell is the product.** All three `scripts/*.sh` plus `start-hermes.sh` must pass
  `bash -n`, keep the documented exit-code contract, write answers to stdout and
  diagnostics to stderr, and never `eval`/`source` a user's `.env`.
- **No fake features.** If something here depends on an upstream capability, verify it
  exists in the upstream repo/docs first and cite where. (`.hermesignore` is the standing
  counter-example: documented as unsupported, so a real indexer replaces it.)
- **Do not add an `entrypoint:`/`user:` to the compose service, and do not bind published
  ports to `0.0.0.0`.**
- **Do not commit `.env`**, the drop-zone contents, or `INDEX.md`.
- Test without Docker by putting a fake `docker` on `PATH` that answers `--version`,
  `compose version`, `info`, `inspect -f`, `ps --format`, `exec … hermes config get|set`,
  then run `./start-hermes.sh --local-llm` and `./scripts/hermes-doctor.sh`; both must be
  silent-ish on success and specific on failure.
- Update `README.md` (setup + troubleshooting table) and add a dated `YYYY-MM-DD/summary.md`
  in the same commit as any behavioural change.

## Verification commands

```bash
bash -n start-hermes.sh scripts/*.sh            # syntax
docker compose config >/dev/null                # compose schema/interpolation
./start-hermes.sh --check                       # end-to-end health of the chain
```
