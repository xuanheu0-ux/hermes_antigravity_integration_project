---
name: hermes
description: Query the local Hermes agent (Docker container) about the developer's other projects - architecture, conventions, reusable code, cross-repo comparisons. Use for /hermes, for any "what do my other repos do / have I solved X before" question, or when repo context is needed beyond this workspace.
---

# Ask Hermes (local knowledge bot)

Hermes is an autonomous agent running in a Docker container (`hermes_local`) with a
**read-only** view of this machine's project drop zone. You reach it through one script;
never call `docker exec` ad hoc, because that script also handles timeouts, exit-code
mapping and a stale-index warning.

## Procedure

1. Ask the question:

   ```bash
   ./scripts/hermes-ask.sh "<one focused question>"
   ```

   - stdout is the answer, stderr is diagnostics. Keep your own prompt under ~2000 chars.
   - Pipe context in with `-` when the question is about a diff or file:
     `git diff HEAD~1 | ./scripts/hermes-ask.sh -`
   - Long CPU inferences are normal (a small local model on a laptop CPU can take
     minutes). The script times out at `$HERMES_TIMEOUT` (default 300 s); pass
     `--timeout 900` if you expect a big answer, and never conclude "it's broken" from a
     slow first token.

2. If it fails, read the exit code before retrying:

   | rc | meaning | action |
   |----|---------|--------|
   | 3  | container not running | `./start-hermes.sh` (then retry once) |
   | 4  | preconditions (empty prompt, missing docker, no API key) | fix the `.env` value it names |
   | 2  | Hermes turn failed/partial, or timed out | `./scripts/hermes-doctor.sh`, then narrow the question |
   | 1  | Hermes answered with nothing | the drop zone probably lacks the project — step 3 |

3. "Hermes doesn't know my project X" is almost always indexing, not the model:

   ```bash
   ./scripts/hermes-index.sh          # rebuild <dropzone>/INDEX.md
   ./start-hermes.sh --check          # container, provider, prompt size, Ollama ctx
   ```

4. Report answers with the `project/path:line` citations Hermes is instructed to give.
   Verify any file path it quotes before pasting it into an edit — Hermes reads a
   read-only mirror, so its paths are relative to `/workspace/projects`.

## Rules

- Do NOT ask Hermes to write, delete, or run anything: its workspace mount is read-only
  by design and its prompt forbids mutation. Reading and comparing is its only job.
- Do NOT send secrets, credentials, or whole files that `.hermesignore` excludes.
- One question per call. A chained question ("refactor X and also check Y") gets a
  half answer from a 3B model.
- If `HERMES_TRANSPORT=http` is set in `.env`, the same script uses the gateway's
  OpenAI-compatible API on `127.0.0.1:8642` instead of `docker exec`; do not add a second
  HTTP call of your own.
- `.hermesignore` is honored by OUR indexer (`scripts/hermes-index.sh`), not by Hermes
  itself — upstream has not implemented it. Do not "fix" a missing file by editing that
  list alone; rerun the indexer.
