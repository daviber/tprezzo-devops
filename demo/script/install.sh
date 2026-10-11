#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_local_tools
require_local_files

echo "[demo][install] installo prerequisiti sul VPS $REMOTE..."

run_remote_script <<'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release rsync

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
DOCKER_LINE="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable"
if [[ ! -f "$DOCKER_LIST" ]] || ! grep -Fq "$DOCKER_LINE" "$DOCKER_LIST"; then
  echo "$DOCKER_LINE" > "$DOCKER_LIST"
fi

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
REMOTE_SCRIPT

echo "[demo][install] sync file progetto su remoto..."
sync_project_to_remote

echo "[demo][install] build frontend e avvio stack Docker..."
deploy_remote_stack
check_remote_app

echo "[demo][install] completato."
