#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -f "$DEVOPS_DIR/.env" ]]; then
  cp "$DEVOPS_DIR/.env.example" "$DEVOPS_DIR/.env"
  echo "[devops] creato .env da .env.example"
fi

PROFILE_ARGS=()
if grep -Eq '^STRIPE_API_KEY=.+$' "$DEVOPS_DIR/.env"; then
  PROFILE_ARGS=(--profile stripe)
fi

if (( ${#PROFILE_ARGS[@]} > 0 )); then
  docker compose \
    --env-file "$DEVOPS_DIR/.env" \
    -f "$DEVOPS_DIR/docker-compose.yml" \
    "${PROFILE_ARGS[@]}" \
    up -d
else
  docker compose \
    --env-file "$DEVOPS_DIR/.env" \
    -f "$DEVOPS_DIR/docker-compose.yml" \
    up -d
fi

bash "$SCRIPT_DIR/migrate.sh"

FORWARD_TO="$(grep -E '^STRIPE_WEBHOOK_FORWARD_TO=' "$DEVOPS_DIR/.env" | sed 's/^STRIPE_WEBHOOK_FORWARD_TO=//')"
if grep -Eq '^STRIPE_API_KEY=.+$' "$DEVOPS_DIR/.env" && [[ "$FORWARD_TO" == *"localhost"* ]]; then
  echo "[devops][warning] STRIPE_WEBHOOK_FORWARD_TO punta a localhost."
  echo "[devops][warning] Se Stripe CLI gira in Docker, usa l'endpoint Java raggiungibile dal container (locale: http://host.docker.internal:8080/api/v1/stripe/webhook)."
fi

echo
echo "[devops] Infrastruttura avviata."
echo "- Supabase: http://localhost:54321"
echo "- Postgres: localhost:54322"
if grep -Eq '^STRIPE_API_KEY=.+$' "$DEVOPS_DIR/.env"; then
  echo "- Stripe CLI webhook relay: attivo"
else
  echo "- Stripe CLI webhook relay: non attivo (imposta STRIPE_API_KEY in devops/.env)"
fi
