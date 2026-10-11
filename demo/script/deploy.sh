#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_local_tools
require_local_files

echo "[demo][deploy] verifico Docker sul VPS..."
run_remote "docker compose version >/dev/null"

echo "[demo][deploy] sync file aggiornati..."
sync_project_to_remote

echo "[demo][deploy] rebuild frontend e aggiorno stack..."
deploy_remote_stack
check_remote_app

echo "[demo][deploy] completato."
