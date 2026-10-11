#!/usr/bin/env bash
# Upload immutable release; never sync, build or delete the legacy installation.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/../settings.sh"
RELEASE="${1:?Uso: ship.sh release-id}"
[[ "$RELEASE" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || exit 2
JAVA_REMOTE_BASE="${JAVA_REMOTE_BASE:-/opt/tprezzo-java}"
[[ "$JAVA_REMOTE_BASE" == /opt/tprezzo-java ]] || { echo 'Base Java deve essere /opt/tprezzo-java' >&2; exit 2; }
[[ "$DEPLOY_HOST" =~ ^[a-zA-Z0-9.-]+$ && "$DEPLOY_USER" =~ ^[a-zA-Z0-9._-]+$ && "$DEPLOY_PORT" =~ ^[0-9]+$ ]] || exit 2
CONFIG="$ROOT/.local/releases/$RELEASE"
ARCHIVE="$ROOT/.local/images-$RELEASE.tar.gz"
TARGET="$JAVA_REMOTE_BASE/releases/$RELEASE"
python3 "$HERE/config.py" check "$CONFIG"
[[ -f "$ARCHIVE" && -f "$CONFIG/images.manifest" ]] || { echo 'Prima eseguire build-release.sh' >&2; exit 1; }
python3 "$HERE/config.py" check-built "$CONFIG"
SSH_ARGS=(-p "$DEPLOY_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)
[[ -z "${SSH_IDENTITY_FILE:-}" ]] || SSH_ARGS+=(-i "$SSH_IDENTITY_FILE")
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"
printf -v RSYNC_SSH '%q ' ssh "${SSH_ARGS[@]}"
ssh "${SSH_ARGS[@]}" "$REMOTE" "set -eu
docker compose version >/dev/null
available=\$(df -Pm /opt | awk 'NR==2 {print \$4}')
[ \"\$available\" -ge 6144 ] || { echo 'Servono almeno 6 GiB liberi prima del caricamento. Nessun prune automatico.' >&2; exit 1; }
test ! -e '$TARGET' || { echo 'Release remota già esistente: usare nuovo ID' >&2; exit 1; }
umask 077
mkdir -p '$TARGET'
"
rsync -az --no-owner --no-group -e "$RSYNC_SSH" \
  "$HERE/compose.yml" "$HERE/compose.public.yml" "$HERE/manage.sh" \
  "$HERE/config.py" "$HERE/legacy.py" "$HERE/inspect.sh" "$HERE/inspect.sql" \
  "$HERE/README.md" "$HERE/nginx" "$REMOTE:$TARGET/"
rsync -az --no-owner --no-group -e "$RSYNC_SSH" \
  "$CONFIG/runtime.env" "$CONFIG/backend.env" "$CONFIG/frontend.env" \
  "$CONFIG/stripe.env" "$CONFIG/images.manifest" "$CONFIG/frontend.sha256" "$REMOTE:$TARGET/"
# Docker accepts gzip archives directly: no second archive occupies VPS disk.
ssh "${SSH_ARGS[@]}" "$REMOTE" 'docker load --platform linux/amd64' < "$ARCHIVE"
ssh "${SSH_ARGS[@]}" "$REMOTE" "chmod 700 '$TARGET'; chmod 600 '$TARGET/'*.env; bash '$TARGET/manage.sh' preflight"
echo "Release caricata. Standby: ssh $REMOTE bash '$TARGET/manage.sh' stage"
