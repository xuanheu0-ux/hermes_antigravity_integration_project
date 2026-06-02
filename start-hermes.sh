#!/bin/bash
set -e

# Build and start the container in detached mode
echo "Building and starting the Hermes Docker container..."
docker compose up --build -d

echo "Hermes container is running!"
echo "Projects from /home/matt/Documents/vscode are mounted inside the container at /opt/data/projects"
echo ""
echo "To jump into the Hermes container to run the setup or interact via CLI, run:"
echo "  docker exec -it hermes_local hermes"
echo ""
echo "Or drop straight into the setup wizard:"
echo "  docker exec -it hermes_local hermes setup"
