#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE="${1:-}"

if [[ -n "$SERVICE" ]]; then
  docker compose --env-file "$DEVOPS_DIR/.env" -f "$DEVOPS_DIR/docker-compose.yml" logs -f "$SERVICE"
else
  docker compose --env-file "$DEVOPS_DIR/.env" -f "$DEVOPS_DIR/docker-compose.yml" logs -f
fi
