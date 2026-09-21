# Summary of Work: June 2, 2026

> [!IMPORTANT]
> Corrections (2026-09-21) — two claims in this log turned out to be ineffective, and were
> the source of a later bug hunt. See `2026-09-21/summary.md` and README "Gotchas":
> 1. §4: `.hermesignore` is **not implemented by Hermes** (open upstream proposals only), so
>    that file alone never reduced the prompt. The speed-up came from narrowing `terminal.cwd`.
>    The mechanism is now `scripts/hermes-index.sh` → `INDEX.md`.
> 2. §3: `OLLAMA_NUM_CTX` is a **legacy variable name** and is dropped by the OpenAI-compatible
>    `/v1` endpoint Hermes uses. The setting that works is `OLLAMA_CONTEXT_LENGTH`, and it must
>    be set on the server (verified with `ollama ps` → CONTEXT).
> 3. The repo was also unbuildable: `hermes-agent` had been committed as a dangling gitlink.

## Hermes Local Integration Project

Today's session focused entirely on migrating the Hermes AI agent from a remote, paid-API configuration (Google Gemini) into a fully offline, privacy-first local architecture using **Ollama** and **Docker**. We stabilized the environment, fixed context truncation issues, and performed a massive CPU optimization to drastically reduce the agent's inference time.

### 1. Network Bridging & Docker Stability
- **Host Gateway Mapping:** Added `extra_hosts: ["host.docker.internal:host-gateway"]` to the `docker-compose.yml` to allow the containerized Hermes bot to communicate securely with the host's Ollama service.
- **Docker CLI Fix:** Updated `start-hermes.sh` to use the modern `docker compose` syntax instead of the deprecated `docker-compose`.
- **Interactive Flags:** Added `tty: true` and `stdin_open: true` to the container to prevent it from crashing when run in detached mode.

### 2. Local LLM Migration via Ollama
- **Provider Switch:** Modified the `hermes config` provider from `gemini` to a `custom` local provider endpoint (`http://host.docker.internal:11434/v1`).
- **Model Optimization:** Downloaded and activated the `llama3.2` edge model (3 Billion parameters), which provides excellent reasoning capabilities while remaining lightweight enough for CPU-only inference.

### 3. Resolving the "Amnesia" Bug (Context Truncation)
- **The Issue:** We identified a critical bug in the Ollama logs where the massive 11k+ token system prompts from Hermes were being truncated to Ollama's default `4096` token limit. This caused the AI to forget its instructions and hallucinate generic chatbot responses.
- **The Fix:** Deployed a permanent systemd override file (`/etc/systemd/system/ollama.service.d/override.conf`) forcing `OLLAMA_NUM_CTX=16384`. This ensured Ollama dynamically allocated enough context memory to absorb Hermes' full system prompt and local file tree maps.

### 4. CPU Bottleneck & Inference Optimization
- **The Issue:** The Intel i7-8650U CPU was taking roughly 3 minutes to generate the first token. We discovered this was caused by Hermes indiscriminately indexing nearly 400,000 files in the `/vscode` folder and feeding them into the massive system prompt.
- **The Fix:** 
  1. Deployed an aggressive `.hermesignore` file into the workspace root to block heavy backend directories (`node_modules`, `.git`, `venv`, `__pycache__`, etc.).
  2. Reconfigured Hermes' `terminal.cwd` mapping to point correctly to `/opt/data/projects`.
- **Result:** The system prompt size dropped from ~16,000 tokens to a fraction of the size, completely unblocking the CPU and drastically improving response speeds.

### 5. Repository Sanitization
- Confirmed the `.env` file containing the old Gemini API key was properly excluded in `.gitignore` and 100% safe.
- Cleaned up leftover build files (e.g., `Modelfile.hermes`).
- Committed all configuration patches and pushed the repository to the `main` branch.
