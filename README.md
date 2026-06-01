# Hermes + Antigravity Integration Project

This repository serves as the launchpad and integration layer for running **Hermes**, an autonomous AI agent, securely inside a local Docker environment, while allowing **Antigravity** (your AI coding assistant) to communicate with it.

## The Goal
The primary objective of this project is to use Hermes as an isolated, intelligent repository indexer and local knowledge bot. Hermes will:
- Run securely inside a sandboxed Docker container.
- Have specific local VSCode project folders mounted to it via volume mounts.
- "Remember" and compare these various GitHub repositories.
- Act as a localized knowledge base, giving suggestions and retrieving context for Antigravity when reusing code or architecture.

## How It Works
1. **Dockerized Environment**: Instead of installing Hermes directly onto the host machine, we build it into a Docker image (`docker-compose.yml`).
2. **Selective Mounting**: By editing the volume mounts, we grant the Hermes container **read-only** access to specific local directories (like `/home/matt/Documents/vscode`). Hermes can only see what it is explicitly allowed to see.
3. **Gemini Powered**: We power Hermes using Google Gemini (by injecting the `GEMINI_API_KEY` through a `.env` file), ensuring highly capable reasoning without bloatware or lesser models.

## Future Roadmap: The `/hermes` Command
To create a seamless workflow, we plan to implement a `/hermes` slash command. 
When this command is invoked, **Antigravity** will act as the frontend interface and automatically query the local Hermes bot running in the Docker container. This will allow Antigravity to quickly pull insights, code snippets, and comparative analyses from Hermes's persistent memory regarding all your other local projects.

## Setup Instructions
1. Clone this repository.
2. Copy `.env.example` to `.env` and insert your `GEMINI_API_KEY`.
3. Run `./start-hermes.sh` to build the Docker image and start the container.
4. Connect to Hermes via `docker exec -it hermes_local hermes`.
