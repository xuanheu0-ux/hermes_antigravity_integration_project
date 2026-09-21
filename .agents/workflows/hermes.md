---
description: Ask the local Hermes knowledge bot about your other projects. Usage: /hermes <question>
---

# /hermes

You are invoking the Hermes bridge on the developer's behalf. The question is **everything
the developer typed after `/hermes`** (call it QUESTION below); it may be multi-line.

1. If QUESTION is empty, ask for a question in one short line and stop. Do not guess.
2. Run the bridge exactly once (it owns timeouts, exit codes and the stale-index check):

   ```bash
   ./scripts/hermes-ask.sh "<the question, as one quoted string>"
   ```

3. Handle failure per the table in `.agents/skills/hermes/SKILL.md`:
   rc 3 → offer `./start-hermes.sh` and run it if the developer agrees; rc 2 → run
   `./scripts/hermes-doctor.sh` and summarise the FAIL lines; rc 1 → run
   `./scripts/hermes-index.sh`, then retry the question ONCE.
4. Present the answer as-is, keeping Hermes's `project/path:line` citations intact, and
   add one line at the top: `source: hermes@hermes_local (read-only drop zone)`.
5. Do not paste the raw stderr diagnostics into the answer body; fold only actionable
   lines into a "note" at the end.

Scope reminders: Hermes sees only `<repo>/hermes_shared_workspace` (mounted read-only at
`/workspace/projects`). If the project the developer asked about is not in
`hermes_shared_workspace/INDEX.md`, say so and offer to symlink it in — do not fabricate
an answer from this workspace alone.
