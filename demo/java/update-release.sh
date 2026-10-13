#!/usr/bin/env bash
# Prepare/publish updates to the existing Java demo. Builds remain explicit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../settings.sh"
export DEPLOY_HOST DEPLOY_USER DEPLOY_PORT SSH_IDENTITY_FILE
exec python3 "$HERE/update_release.py" "$@"
