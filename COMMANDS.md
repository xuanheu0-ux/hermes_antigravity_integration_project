# Commands

Step-by-step installation (Vietnamese): [`docs/INSTALL-vi.md`](docs/INSTALL-vi.md).

Everything goes through `./start-hermes.sh` (preflight + bootstrap) and the three
`scripts/*.sh`. The raw `docker` forms are listed too, because they are what the scripts
run under the hood and you will need them when debugging.

## Lifecycle

```bash
./start-hermes.sh                      # pull-based start; seeds + indexes the drop zone
./start-hermes.sh --local-llm          # + Ollama sidecar, model pull, provider wiring
./start-hermes.sh --build              # build hermes-agent/Dockerfile (derived image)
./start-hermes.sh --logs               # docker compose logs -f hermes_local
./start-hermes.sh --down
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build   # raw equivalent of --build
```

## Ask Hermes

```bash
./scripts/hermes-ask.sh "compare the config conventions in my indexed projects"
git diff | ./scripts/hermes-ask.sh -                       # stdin prompt
./scripts/hermes-ask.sh --timeout 900 "big question"
HERMES_TRANSPORT=http ./scripts/hermes-ask.sh "via the gateway API"
docker exec -i hermes_local hermes --in /workspace/projects -z "same thing, raw"
docker exec -it hermes_local hermes                        # interactive session
```

## Diagnose

```bash
./start-hermes.sh --check              # = scripts/hermes-doctor.sh
./scripts/hermes-index.sh              # rebuild <dropzone>/INDEX.md
./scripts/hermes-index.sh --check       # exit 1 = stale
docker exec hermes_local hermes doctor                     # upstream: config + deps
docker exec hermes_local hermes prompt-size                 # where the tokens go
docker exec hermes_local hermes config get terminal.cwd
docker exec hermes_local curl -s http://ollama:11434/v1/models
docker exec hermes_ollama ollama ps                         # CONTEXT column = real window
docker exec hermes_ollama ollama list
docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' hermes_local
docker compose config                    # validate interpolation/volumes before `up`
```

## Fix a stuck container

```bash
docker exec -it hermes_local hermes model                   # re-pick provider/endpoint
docker exec hermes_local hermes gateway status
docker compose restart hermes
docker compose down -v                                     # LAST RESORT: deletes hermes_data
```

Exit codes from `hermes-ask.sh`: `0` answer on stdout · `1` empty answer · `2` failed or
timed-out turn · `3` container not running · `4` missing precondition · `130` interrupted.
