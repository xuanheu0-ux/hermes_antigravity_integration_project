---
description: How this workspace talks to the local Hermes agent (Docker). Always-on project context.
trigger: always_on
---

# Hermes bridge — permanent context for this workspace

## What this repo is

Launchpad + integration layer for **Hermes Agent** (Nous Research, `nousresearch/hermes-agent`)
running in Docker as a read-only index of this machine's projects, queried from
Antigravity via `/hermes`.

```
Antigravity 2.0  --/hermes-->  .agents/workflows/hermes.md
                       |              |
                       |              v
                       |      scripts/hermes-ask.sh  --docker exec-->  [container hermes_local]
                       |              |                                      |
                       |              +----HTTP 127.0.0.1:8642 (optional)   v
                       v                                            /workspace/projects  (READ-ONLY)
              .agents/skills/hermes/SKILL.md                        = ./hermes_shared_workspace/
                                                                    /opt/data = HERMES_HOME (volume)
                                                                    provider -> Ollama /v1
```

## Hard facts about the container (do not re-derive them)

- Hermes runs in the **official image**, not a locally built one. `hermes-agent/` is a thin
  overlay (`FROM nousresearch/hermes-agent`) used only to seed first-boot config and the
  drop-zone templates; `docker-compose.build.yml` opts into it.
- **Never set `entrypoint:`** on the service. The image's entrypoint is
  `entrypoint-dispatch.sh -> s6-overlay /init`; bypassing it removes the supervisor and the
  zombie reaper and breaks the gateway.
- `HERMES_HOME=/opt/data`, backed by the `hermes_data` volume. Do not put the project tree
  inside it: Hermes size-checks its own home, and a bind-mounted repo collection there is a
  known failure mode. Projects live at `/workspace/projects`.
- The container is interactive-only by design: `command: ["gateway","run"]` keeps it alive;
  `docker exec <ctr> hermes -z "<prompt>"` is the one-shot entry point (pure answer on
  stdout, exit 0/1/2/130).
- Ports are published on `127.0.0.1` ONLY (8642 API, 9119 dashboard). Never change that to
  `0.0.0.0` — the container holds API keys and the dashboard has no auth on loopback.

## Two bugs that will bite you if you forget them

1. **`.hermesignore` is not a Hermes feature.** Upstream never implemented it (proposed in
   issues #502/#681/#50165). It is consumed only by `scripts/hermes-index.sh`. Editing it
   without rerunning the indexer does nothing. Real prompt-size knobs are the drop-zone
   scope, `INDEX.md`, `context_file_max_chars`, and `hermes prompt-size`.
2. **`OLLAMA_NUM_CTX` is dead.** Current Ollama reads `OLLAMA_CONTEXT_LENGTH`, and Hermes
   talks to the OpenAI-compatible `/v1` endpoint which drops `num_ctx` anyway. A too-small
   context silently truncates Hermes's system prompt — which is exactly the "amnesia"
   symptom this project already debugged once. Verify with `ollama ps` (CONTEXT column).

## House rules for you (the agent)

- Edit scripts under `scripts/` and `start-hermes.sh` with `bash -n` + a run against the
  documented flags; they are the whole product surface of this repo.
- Never commit `.env`, `hermes_shared_workspace/` contents, or `INDEX.md`.
- Keep `hermes_shared_workspace/` a collection of **symlinks**; do not copy repos into it
  (they drift, and the index will mislead Hermes).
- When you change anything in `docker-compose.yml`, run `docker compose config` to validate,
  and update README.md's troubleshooting table in the same commit.
