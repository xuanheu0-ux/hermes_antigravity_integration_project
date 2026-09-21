# Hermes Agent — derived image for the Antigravity 2.0 drop-zone integration.
#
# Why FROM the official image instead of building Hermes here:
#   upstream's Dockerfile is a multi-stage build (custom pinned SQLite, uv, Node 26,
#   Playwright, s6-overlay) and the runtime treats /opt/hermes as an IMMUTABLE install
#   tree — runtime `pip install`/lazy installs are disabled on purpose. Rebuilding it in
#   this repo would be a fork with zero upside for an indexer bot. This overlay only adds
#   first-boot seeding.
#
# Build (optional — the default ./start-hermes.sh just pulls the upstream image):
#   docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
#
# HARD CONSTRAINT: do not add an ENTRYPOINT or `USER` line. The base image's
# ENTRYPOINT is docker/entrypoint-dispatch.sh -> s6-overlay /init, which runs
# /etc/cont-init.d/*, chowns /opt/data and drops to the `hermes` user for every
# supervised service. Replacing it loses supervision and the zombie reaper.

ARG HERMES_BASE_IMAGE=nousresearch/hermes-agent
ARG HERMES_BASE_TAG=latest
FROM ${HERMES_BASE_IMAGE}:${HERMES_BASE_TAG}

# Drop-zone templates: the instructions Hermes must read to behave as a read-only
# repo indexer, plus the ignore list consumed by scripts/hermes-index.sh.
# (.hermesignore is NOT an upstream Hermes feature — see the note in that file.)
COPY --chown=root:root dropzone/ /opt/hermes-dropzone/

# s6-overlay cont-init.d hooks run as root at container boot, before the gateway
# service starts and before the drop to the hermes user. Numbered >01 so Hermes'
# own setup/seed hook (01-hermes-setup) has already laid down .env/config.yaml.
COPY --chown=root:root docker/cont-init.d/90-hermes-dropzone /etc/cont-init.d/90-hermes-dropzone
RUN chmod 0755 /etc/cont-init.d/90-hermes-dropzone

LABEL org.opencontainers.image.title="hermes-agent-antigravity" \
      org.opencontainers.image.description="Hermes Agent + local drop-zone indexer for Antigravity 2.0" \
      org.opencontainers.image.source="https://github.com/xuanheu0-ux/hermes_antigravity_integration_project"
