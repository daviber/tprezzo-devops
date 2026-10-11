#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/../settings.sh"

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "[demo] file non trovato: $SETTINGS_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$SETTINGS_FILE"

REMOTE="${DEPLOY_USER}@${DEPLOY_HOST}"

build_ssh_args() {
  local args=(
    -p "$DEPLOY_PORT"
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=5
  )

  if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
    args+=(-i "$SSH_IDENTITY_FILE")
  fi

  printf '%s\n' "${args[@]}"
}

run_remote() {
  local ssh_args=()
  while IFS= read -r arg; do
    ssh_args+=("$arg")
  done < <(build_ssh_args)

  ssh "${ssh_args[@]}" "$REMOTE" "$@"
}

run_remote_script() {
  local ssh_args=()
  while IFS= read -r arg; do
    ssh_args+=("$arg")
  done < <(build_ssh_args)

  ssh "${ssh_args[@]}" "$REMOTE" "bash -s"
}

build_rsync_ssh_command() {
  local cmd=(ssh)
  while IFS= read -r arg; do
    cmd+=("$arg")
  done < <(build_ssh_args)

  printf '%q ' "${cmd[@]}"
}

build_remote_compose_env() {
  local project_q app_domain_q app_context_q env_file_q
  local loopback_host_q loopback_port_q http_port_q https_port_q
  local app_image_q certbot_www_q certbot_conf_q
  printf -v project_q '%q' "$COMPOSE_PROJECT_NAME"
  printf -v app_domain_q '%q' "$APP_DOMAIN"
  printf -v app_context_q '%q' "$REMOTE_APP_CONTEXT_REL"
  printf -v env_file_q '%q' "$REMOTE_ENV_FILE_REL"
  printf -v loopback_host_q '%q' "$APP_LOOPBACK_HOST"
  printf -v loopback_port_q '%q' "$APP_LOOPBACK_PORT"
  printf -v http_port_q '%q' "$HTTP_PORT"
  printf -v https_port_q '%q' "$HTTPS_PORT"
  printf -v app_image_q '%q' "$APP_IMAGE"
  printf -v certbot_www_q '%q' "$CERTBOT_WWW_DIR"
  printf -v certbot_conf_q '%q' "$CERTBOT_CONF_DIR"

  printf 'COMPOSE_PROJECT_NAME=%s APP_DOMAIN=%s APP_ROOT_REL=%s APP_ENV_FILE=%s APP_LOOPBACK_HOST=%s APP_LOOPBACK_PORT=%s HTTP_PORT=%s HTTPS_PORT=%s APP_IMAGE=%s CERTBOT_WWW_DIR=%s CERTBOT_CONF_DIR=%s' \
    "$project_q" \
    "$app_domain_q" \
    "$app_context_q" \
    "$env_file_q" \
    "$loopback_host_q" \
    "$loopback_port_q" \
    "$http_port_q" \
    "$https_port_q" \
    "$app_image_q" \
    "$certbot_www_q" \
    "$certbot_conf_q"
}

require_local_tools() {
  local required=(ssh rsync)
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[demo] comando richiesto non trovato: $cmd" >&2
      exit 1
    fi
  done
}

require_integer_in_range() {
  local key="$1"
  local value="$2"
  local min="$3"
  local max="$4"

  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "[demo] $key deve essere un intero tra $min e $max" >&2
    exit 1
  fi

  local number=$((10#$value))
  if (( number < min || number > max )); then
    echo "[demo] $key deve essere un intero tra $min e $max" >&2
    exit 1
  fi
}

require_stack_settings() {
  if [[ ! "$DEPLOY_HOST" =~ ^[a-zA-Z0-9.-]+$ || ! "$DEPLOY_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[demo] DEPLOY_HOST o DEPLOY_USER non validi" >&2
    exit 1
  fi
  require_integer_in_range "DEPLOY_PORT" "$DEPLOY_PORT" 1 65535

  if [[ ! "$REMOTE_BASE_DIR" =~ ^/[a-zA-Z0-9._/-]+$ || "$REMOTE_BASE_DIR" == *..* ]]; then
    echo "[demo] REMOTE_BASE_DIR deve essere un percorso assoluto semplice, senza '..'" >&2
    exit 1
  fi

  if [[ ! "$APP_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "[demo] APP_DOMAIN non valido" >&2
    exit 1
  fi

  if [[ ! "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || (( ${#COMPOSE_PROJECT_NAME} > 63 )); then
    echo "[demo] COMPOSE_PROJECT_NAME non valido: usa 1-63 caratteri [a-z0-9_-], iniziando con lettera/numero" >&2
    exit 1
  fi

  if [[ "$APP_LOOPBACK_HOST" != "127.0.0.1" ]]; then
    echo "[demo] APP_LOOPBACK_HOST deve restare 127.0.0.1 per non esporre direttamente Next.js" >&2
    exit 1
  fi

  require_integer_in_range "APP_LOOPBACK_PORT" "$APP_LOOPBACK_PORT" 1 65535
  require_integer_in_range "HTTP_PORT" "$HTTP_PORT" 1 65535
  require_integer_in_range "HTTPS_PORT" "$HTTPS_PORT" 1 65535

  if (
    [[ "$HTTP_PORT" == "$HTTPS_PORT" ]] ||
    [[ "$APP_LOOPBACK_PORT" == "$HTTP_PORT" ]] ||
    [[ "$APP_LOOPBACK_PORT" == "$HTTPS_PORT" ]]
  ); then
    echo "[demo] APP_LOOPBACK_PORT, HTTP_PORT e HTTPS_PORT devono essere distinti" >&2
    exit 1
  fi

  if [[ -z "$APP_IMAGE" ]]; then
    echo "[demo] APP_IMAGE obbligatoria" >&2
    exit 1
  fi
}

require_local_files() {
  local files=(
    "$LOCAL_COMPOSE_FILE"
    "$LOCAL_ENV_FILE"
    "$LOCAL_DOCKERFILE"
    "$LOCAL_NGINX_TEMPLATE_DIR/site-http.conf.template"
    "$LOCAL_NGINX_TEMPLATE_DIR/site-https.conf.template"
  )
  for file in "${files[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "[demo] file richiesto non trovato: $file" >&2
      exit 1
    fi
  done

  require_stack_settings
  require_local_frontend_env
}

env_var_from_file() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      separator = index(line, "=")
      if (!separator) next
      name = substr(line, 1, separator - 1)
      sub(/[[:space:]]*$/, "", name)
      if (name != key) next
      value = substr(line, separator + 1)
      sub(/\r$/, "", value)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      quote = substr(value, 1, 1)
      if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(value, length(value), 1) == quote) {
        value = substr(value, 2, length(value) - 2)
      }
      found = 1
    }
    END { if (found) print value }
  ' "$file"
}

env_file_has_key() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      separator = index(line, "=")
      if (!separator) next
      name = substr(line, 1, separator - 1)
      sub(/[[:space:]]*$/, "", name)
      if (name == key) found = 1
    }
    END { exit !found }
  ' "$file"
}

is_missing_or_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == __*__ ]]
}

require_local_frontend_env() {
  local forbidden=(
    SUPABASE_SERVICE_ROLE_KEY
    STRIPE_API_KEY
    STRIPE_SECRET_KEY
    STRIPE_WEBHOOK_SECRET
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
  )
  local key value
  for key in "${forbidden[@]}"; do
    if env_file_has_key "$key" "$LOCAL_ENV_FILE"; then
      echo "[demo] chiave backend vietata nel file frontend $LOCAL_ENV_FILE: $key" >&2
      echo "[demo] prepara un file env dedicato al frontend; il backend si configura separatamente" >&2
      exit 1
    fi
  done

  local required=(
    NEXT_PUBLIC_SUPABASE_URL
    NEXT_PUBLIC_SUPABASE_ANON_KEY
    NEXT_PUBLIC_APP_URL
    NEXT_PUBLIC_BACKEND_API_URL
    BACKEND_API_URL
    NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
  )
  for key in "${required[@]}"; do
    value="$(env_var_from_file "$key" "$LOCAL_ENV_FILE")"
    if is_missing_or_placeholder "$value"; then
      echo "[demo] variabile frontend mancante in $LOCAL_ENV_FILE: $key" >&2
      exit 1
    fi
  done
}

require_remote_frontend_only_stack() {
  local project_q
  printf -v project_q '%q' "$COMPOSE_PROJECT_NAME"

  run_remote "set -euo pipefail
legacy_worker_ids=\"\$(docker ps -aq --filter label=com.docker.compose.project=$project_q --filter label=com.docker.compose.service=worker)\"
if [ -n \"\$legacy_worker_ids\" ]; then
  echo '[demo] migrazione necessaria: esiste un container worker Node nel progetto Compose frontend.' >&2
  echo '[demo] deploy interrotto. Coordina manualmente il ritiro del worker Node prima del passaggio a Java; nessun worker viene arrestato o rimosso automaticamente.' >&2
  exit 1
fi
legacy_stripe_ids=\"\$(docker ps -aq --filter label=com.docker.compose.project=$project_q --filter label=com.docker.compose.service=stripe-cli)\"
if [ -n \"\$legacy_stripe_ids\" ]; then
  echo '[demo] deploy interrotto: esiste il vecchio relay Stripe diretto a Next. Coordina manualmente il nuovo webhook Java; nessun container viene arrestato o rimosso automaticamente.' >&2
  exit 1
fi
"
}

sync_project_to_remote() {
  require_remote_frontend_only_stack

  local ssh_cmd
  ssh_cmd="$(build_rsync_ssh_command)"

  run_remote "mkdir -p \
    '$REMOTE_BASE_DIR' \
    '$REMOTE_APP_DIR' \
    '$REMOTE_DEVOPS_DIR' \
    '$REMOTE_DEVOPS_DIR/demo/nginx/templates' \
    '$REMOTE_DEVOPS_DIR/demo/certbot/www' \
    '$REMOTE_DEVOPS_DIR/demo/certbot/conf'"

  rsync -az --no-owner --no-group --delete \
    -e "$ssh_cmd" \
    --exclude '.git/' \
    --exclude '.env*' \
    --exclude '.playwright-cli/' \
    --exclude '.playwright-mcp/' \
    --exclude '.terraform/' \
    --exclude '*.tfstate' \
    --exclude '*.tfstate.*' \
    --exclude '*.tfplan' \
    --exclude 'node_modules/' \
    --exclude '.next/' \
    --exclude '.DS_Store' \
    --exclude 'tsconfig.tsbuildinfo' \
    --exclude 'android/' \
    --exclude 'ios/' \
    --exclude '*.log' \
    "$LOCAL_APP_DIR/" \
    "$REMOTE:$REMOTE_APP_DIR/"

  rsync -az --no-owner --no-group \
    -e "$ssh_cmd" \
    "$LOCAL_ENV_FILE" \
    "$REMOTE:$REMOTE_APP_DIR/.env.demo"
  run_remote "chmod 600 '$REMOTE_APP_DIR/.env.demo'"

  rsync -az --no-owner --no-group \
    -e "$ssh_cmd" \
    "$LOCAL_COMPOSE_FILE" \
    "$REMOTE:$REMOTE_COMPOSE_FILE"

  rsync -az --no-owner --no-group --delete \
    -e "$ssh_cmd" \
    "$LOCAL_NGINX_TEMPLATE_DIR/" \
    "$REMOTE:$REMOTE_DEVOPS_DIR/demo/nginx/templates/"
}

deploy_remote_stack() {
  require_remote_frontend_only_stack

  local compose_env project_q
  compose_env="$(build_remote_compose_env)"
  printf -v project_q '%q' "$COMPOSE_PROJECT_NAME"

  run_remote "set -euo pipefail
cd '$REMOTE_DEVOPS_DIR'
$compose_env docker compose -p $project_q -f '$REMOTE_COMPOSE_FILE' build --pull app
$compose_env docker compose -p $project_q -f '$REMOTE_COMPOSE_FILE' up -d --no-deps app
$compose_env docker compose -p $project_q -f '$REMOTE_COMPOSE_FILE' up -d --no-deps nginx
$compose_env docker compose -p $project_q -f '$REMOTE_COMPOSE_FILE' ps
"
}

check_remote_app() {
  local compose_env project_q loopback_port_q
  compose_env="$(build_remote_compose_env)"
  printf -v project_q '%q' "$COMPOSE_PROJECT_NAME"
  printf -v loopback_port_q '%q' "$APP_LOOPBACK_PORT"

  run_remote "set -euo pipefail
cd '$REMOTE_DEVOPS_DIR'

app_ready=0
for attempt in \$(seq 1 30); do
  if curl -fsS \"http://127.0.0.1:$loopback_port_q\" >/dev/null; then
    app_ready=1
    break
  fi
  sleep 2
done

if [ \"\$app_ready\" -ne 1 ]; then
  echo '[demo] healthcheck app fallita, ultimi log:' >&2
  $compose_env docker compose -p $project_q -f '$REMOTE_COMPOSE_FILE' logs --tail 120 app >&2
  exit 1
fi
echo '[demo] app raggiungibile internamente su http://127.0.0.1:$APP_LOOPBACK_PORT'
$compose_env docker compose -p $project_q -f '$REMOTE_COMPOSE_FILE' exec -T nginx nginx -t >/dev/null
$compose_env docker compose -p $project_q -f '$REMOTE_COMPOSE_FILE' exec -T nginx nginx -s reload
echo '[demo] nginx ricaricato senza restart'
"

  echo "[demo] status: cd '$REMOTE_DEVOPS_DIR' && $compose_env docker compose -p '$COMPOSE_PROJECT_NAME' -f '$REMOTE_COMPOSE_FILE' ps"
  echo "[demo] log app: cd '$REMOTE_DEVOPS_DIR' && $compose_env docker compose -p '$COMPOSE_PROJECT_NAME' -f '$REMOTE_COMPOSE_FILE' logs -f app"
}
