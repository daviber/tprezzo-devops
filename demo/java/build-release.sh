#!/usr/bin/env bash
# Owner-run build. This script intentionally builds Next inside Docker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RELEASE="${1:?Uso: build-release.sh release-id}"
[[ "$RELEASE" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || exit 2
MODE="${2:-build}"
[[ "$MODE" == build || "$MODE" == --export-only ]] || exit 2
CONFIG="$ROOT/.local/releases/$RELEASE"
BACKEND="${BACKEND_SOURCE:-$(dirname "$ROOT")/tprezzo-backend}"
FRONTEND="${FRONTEND_SOURCE:-$(dirname "$ROOT")/Tprezzo_replit}"
python3 "$HERE/config.py" check "$CONFIG"
get() { python3 "$HERE/config.py" get "$CONFIG" "$1"; }
API_IMAGE="$(get API_IMAGE)"
WORKER_IMAGE="$(get WORKER_IMAGE)"
FRONTEND_IMAGE="$(get FRONTEND_IMAGE)"
NGINX_IMAGE="$(get NGINX_IMAGE)"
STRIPE_IMAGE="$(get STRIPE_IMAGE)"
CERTBOT_IMAGE="$(get CERTBOT_IMAGE)"
ARCHIVE="$ROOT/.local/images-$RELEASE.tar.gz"
[[ ! -e "$ARCHIVE" ]] || { echo "Archivio release già presente: $ARCHIVE" >&2; exit 1; }
if [[ "$MODE" == build ]]; then
for image in "$API_IMAGE" "$WORKER_IMAGE" "$FRONTEND_IMAGE"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "Tag già esistente; usare nuovo release-id: $image" >&2
    exit 1
  fi
done
umask 077
# Dockerfile.demo sources this file with /bin/sh: use POSIX shell quoting,
# keeping Compose dotenv syntax separate and never evaluating input locally.
python3 - "$HERE" "$CONFIG" <<'PY'
import hashlib, pathlib, shlex, sys
sys.path.insert(0, sys.argv[1])
import config
root = pathlib.Path(sys.argv[2])
values = config.read_env(root / 'frontend.env')
(root / 'frontend.sha256').write_text(hashlib.sha256((root / 'frontend.env').read_bytes()).hexdigest() + '\n')
(root / 'frontend-build.env').write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in values.items()))
PY

# Build away from the VPS: it must retain RAM/disk for the existing demo.
# The Java Dockerfile copies only source files; dotenv never enters its layers.
docker buildx build --platform linux/amd64 --load --target api \
  -f "$HERE/Dockerfile.backend" -t "$API_IMAGE" "$BACKEND"
docker buildx build --platform linux/amd64 --load --target worker \
  -f "$HERE/Dockerfile.backend" -t "$WORKER_IMAGE" "$BACKEND"
docker buildx build --platform linux/amd64 --load --target runner \
  --secret "id=demo_env,src=$CONFIG/frontend-build.env" \
  -f "$FRONTEND/Dockerfile.demo" -t "$FRONTEND_IMAGE" "$FRONTEND"
for image in "$NGINX_IMAGE" "$STRIPE_IMAGE" "$CERTBOT_IMAGE"; do
  docker pull --platform linux/amd64 "$image"
done
umask 077
: > "$CONFIG/images.manifest"
for image in "$API_IMAGE" "$WORKER_IMAGE" "$FRONTEND_IMAGE" "$NGINX_IMAGE" "$STRIPE_IMAGE" "$CERTBOT_IMAGE"; do
  printf '%s %s\n' "$image" "$(docker image inspect --platform linux/amd64 --format '{{.Id}}' "$image")" >> "$CONFIG/images.manifest"
done
fi
python3 "$HERE/config.py" check-built "$CONFIG"
while read -r image expected; do
  [[ "$(docker image inspect --platform linux/amd64 --format '{{.Id}}' "$image")" == "$expected" ]] || {
    echo "Immagine amd64 differente dal manifest: $image" >&2; exit 1;
  }
done < "$CONFIG/images.manifest"
docker save --platform linux/amd64 "$API_IMAGE" "$WORKER_IMAGE" "$FRONTEND_IMAGE" \
  "$NGINX_IMAGE" "$STRIPE_IMAGE" "$CERTBOT_IMAGE" | gzip > "$ARCHIVE.partial"
mv "$ARCHIVE.partial" "$ARCHIVE"
echo "Immagini amd64 pronte: $ARCHIVE"
