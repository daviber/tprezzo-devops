#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

DOMAIN="${1:-${APP_DOMAIN:-}}"
EMAIL="${2:-${LETSENCRYPT_EMAIL:-}}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

if [[ -z "$DOMAIN" ]]; then
  cat >&2 <<'EOF'
[demo][tls-init] dominio mancante.
Uso: bash script/init-nginx-letsencrypt.sh <dominio> <email_letsencrypt>
EOF
  exit 1
fi

if [[ -z "$EMAIL" ]]; then
  cat >&2 <<'EOF'
[demo][tls-init] email Let's Encrypt mancante.
Passa l'email come secondo parametro oppure valorizza LETSENCRYPT_EMAIL in settings.sh.
EOF
  exit 1
fi

APP_DOMAIN="$DOMAIN"
require_local_tools
require_local_files

compose_env="$(build_remote_compose_env)"
preflight_path="${CERTBOT_WWW_DIR:-./demo/certbot/www}/.well-known/acme-challenge/preflight"

printf -v email_q '%q' "$EMAIL"
printf -v domain_q '%q' "$DOMAIN"
printf -v http_port_q '%q' "$HTTP_PORT"
printf -v https_port_q '%q' "$HTTPS_PORT"
printf -v compose_project_q '%q' "${COMPOSE_PROJECT_NAME:-tprezzo-demo}"
printf -v preflight_path_q '%q' "$preflight_path"

echo "[demo][tls-init] sync file progetto su remoto..."
sync_project_to_remote

echo "[demo][tls-init] avvio app + nginx (HTTP challenge)..."
run_remote "set -euo pipefail
cd '$REMOTE_DEVOPS_DIR'
$compose_env docker compose -p $compose_project_q -f '$REMOTE_COMPOSE_FILE' up -d app
$compose_env docker compose -p $compose_project_q -f '$REMOTE_COMPOSE_FILE' up -d --force-recreate nginx
$compose_env docker compose -p $compose_project_q -f '$REMOTE_COMPOSE_FILE' ps
"

echo "[demo][tls-init] preflight challenge HTTP..."
run_remote "set -euo pipefail
cd '$REMOTE_DEVOPS_DIR'
preflight=$preflight_path_q
mkdir -p \"\$(dirname \"\$preflight\")\"
trap 'rm -f \"\$preflight\"' EXIT
echo 'ok' > \"\$preflight\"
curl -fsS -H 'Host: $domain_q' \
  'http://127.0.0.1:$http_port_q/.well-known/acme-challenge/preflight' >/dev/null
"

echo "[demo][tls-init] richiedo certificato Let's Encrypt per $DOMAIN..."
run_remote "set -euo pipefail
cd '$REMOTE_DEVOPS_DIR'
$compose_env docker compose -p $compose_project_q --profile certbot -f '$REMOTE_COMPOSE_FILE' run --rm --no-deps certbot certonly \
  --webroot \
  -w /var/www/certbot \
  -d $domain_q \
  --email $email_q \
  --agree-tos \
  --no-eff-email \
  --rsa-key-size 4096 \
  --keep-until-expiring
"

echo "[demo][tls-init] riavvio nginx in modalita HTTPS..."
run_remote "set -euo pipefail
cd '$REMOTE_DEVOPS_DIR'
$compose_env docker compose -p $compose_project_q -f '$REMOTE_COMPOSE_FILE' up -d --force-recreate nginx
"

echo "[demo][tls-init] verifica endpoint HTTPS..."
run_remote "curl -fsS -I \
  --resolve '$domain_q:$https_port_q:127.0.0.1' \
  'https://$domain_q:$https_port_q' >/dev/null"

if [[ "$HTTPS_PORT" == "443" ]]; then
  public_url="https://$DOMAIN"
else
  public_url="https://$DOMAIN:$HTTPS_PORT"
fi

echo "[demo][tls-init] completato: $public_url"
echo "[demo][tls-init] rinnovo manuale:"
echo "  cd '$REMOTE_DEVOPS_DIR'"
echo "  $compose_env docker compose -p $compose_project_q --profile certbot -f '$REMOTE_COMPOSE_FILE' run --rm --no-deps certbot renew --webroot -w /var/www/certbot"
echo "  $compose_env docker compose -p $compose_project_q -f '$REMOTE_COMPOSE_FILE' up -d --force-recreate nginx"
