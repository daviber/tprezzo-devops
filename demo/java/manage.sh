#!/usr/bin/env bash
# Run on the VPS from an uploaded release. No builds, SQL writes, prune or down.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
ACTION="${1:-help}"
get() { python3 "$HERE/config.py" get "$HERE" "$1"; }
# Saved release env wins over variables exported by historical runbooks.
docker() { env -i PATH="$PATH" HOME="$HOME" docker "$@"; }
compose() { docker compose --env-file "$HERE/runtime.env" -f "$HERE/compose.yml" "$@"; }
public() { docker compose --env-file "$HERE/runtime.env" -f "$HERE/compose.yml" -f "$HERE/compose.public.yml" "$@"; }
legacy() { python3 "$HERE/legacy.py" "$1" "$HERE" "${2:-}"; }
fail() { echo "[java] $*" >&2; exit 1; }
require_async_off() { [[ "$(get ASYNC_ENABLED)" == false ]] || fail 'ASYNC_ENABLED deve essere false in standby'; }
if [[ "$ACTION" != help ]]; then
  [[ "$HERE" == /opt/tprezzo-java/releases/* ]] || fail 'Eseguire dal rilascio installato su VPS /opt/tprezzo-java/releases/'
  exec 9>/opt/tprezzo-java/.manage.lock
  flock -n 9 || fail 'Altra operazione Java in corso'
  legacy assert-project
fi
trap 'code=$?; echo "[java] operazione interrotta (exit $code). Stato conservato; nessun riavvio automatico Node. Consultare README e manage.sh status; rollback richiede verifica dati." >&2; exit "$code"' ERR

preflight() {
  python3 "$HERE/config.py" check "$HERE"
  docker compose version >/dev/null
  # Parsing !override validates the installed Compose version; never print env.
  public --profile async --profile stripe config --quiet
  [[ "$(uname -m)" == x86_64 ]] || fail 'Release compilata per linux/amd64'
  local available
  available="$(df -Pm "$HERE" | awk 'NR==2 {print $4}')"
  (( available >= 2048 )) || fail 'Meno di 2 GiB liberi: interrompo senza eliminare nulla'
  python3 "$HERE/config.py" check-built "$HERE"
  while read -r image expected; do
    [[ -n "$image" && -n "$expected" ]] || fail 'Manifest immagini invalido'
    [[ "$(docker image inspect --platform linux/amd64 --format '{{.Id}}' "$image")" == "$expected" ]] || fail "Immagine differente dal rilascio: $image"
  done < "$HERE/images.manifest"
  openssl x509 -in "$(get CERTBOT_CONF_DIR)/live/$(get APP_DOMAIN)/fullchain.pem" -noout -checkend 604800 >/dev/null || fail 'TLS assente o scadenza entro 7 giorni: rinnovare prima dello switch'
}

drain() {
  local elapsed=0 active
  while :; do
    active="$(python3 "$HERE/config.py" queue "$HERE")" || fail 'Coda non verificabile: nessun consumer viene cambiato'
    [[ "$active" =~ ^[0-9]+$ ]] || fail 'Conteggio coda invalido'
    (( active > 0 )) || return 0
    (( elapsed < 900 )) || fail 'Drain oltre 15 minuti; ingressi restano chiusi. Ripristinare legacy oppure risolvere job/lease'
    echo "[java] attendo drain: $active job pending/processing"
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

case "$ACTION" in
  preflight) preflight ;;
  stage)
    preflight
    require_async_off
    [[ ! -e .state/public ]] || fail 'Release già pubblicata: usare status'
    compose up -d --no-build --pull never --wait --wait-timeout 180 api frontend nginx
    echo '[java] standby pronto: tunnel SSH 18080/18443/18000; async fermo'
    ;;
  cutover)
    preflight
    require_async_off
    [[ "${2:-}" == --infrastructure-checked ]] || fail 'Prima verifiche DB/coda, configurazione provider e inventario consumer; poi cutover --infrastructure-checked'
    python3 "$HERE/config.py" db-check "$HERE"
    compose up -d --no-build --pull never --wait --wait-timeout 180 api frontend nginx
    # Capture by ID before stopping anything; includes image IDs for rollback.
    legacy snapshot
    echo drain-node > .state/phase
    echo '[java] inizio finestra: chiudo ingressi Node/relay, dreno coda'
    legacy stop nginx
    legacy stop stripe-cli
    legacy stop app
    drain
    legacy stop worker
    legacy assert-stopped
    echo start-java > .state/phase
    python3 "$HERE/config.py" set-async "$HERE" true
    compose --profile async up -d --no-build --pull never --wait --wait-timeout 180 api frontend worker
    if [[ "$(get STRIPE_RELAY_ENABLED)" == true ]]; then
      compose --profile stripe up -d --no-build --pull never stripe-cli
    fi
    # Replace only the new release's nginx; legacy containers remain stopped.
    touch .state/publishing
    public up -d --no-build --pull never --force-recreate --no-deps --wait --wait-timeout 90 nginx
    touch .state/public
    echo public > .state/phase
    echo '[java] switch completato. Verificare browser/job/webhook. Legacy conservato fermo.'
    ;;
  rollback)
    [[ "${2:-}" == --data-compatible ]] || fail 'Rollback richiede verifica compatibilità dati scritti da Java; usare rollback --data-compatible'
    [[ -f .state/legacy.json ]] || fail 'Snapshot legacy assente'
    # Close ingress/producer, drain Java with worker still running, then stop it.
    public --profile async --profile stripe stop nginx stripe-cli frontend api
    if [[ "$(get ASYNC_ENABLED)" == true ]]; then drain; fi
    compose --profile async stop -t 330 worker
    python3 "$HERE/config.py" set-async "$HERE" false
    legacy start app
    legacy start worker
    legacy start stripe-cli
    legacy start nginx
    [[ ! -e .state/public ]] || mv .state/public .state/rolled-back
    [[ ! -e .state/publishing ]] || mv .state/publishing .state/published-before-rollback
    echo rolled-back > .state/phase
    echo '[java] legacy riavviato dagli stessi container. Java conservato fermo.'
    ;;
  renew)
    compose --profile maintenance run --rm --no-deps certbot
    if [[ -e .state/public ]]; then
      public exec -T nginx nginx -t
      public exec -T nginx nginx -s reload
    else
      compose exec -T nginx nginx -t
      compose exec -T nginx nginx -s reload
    fi
    ;;
  status)
    if [[ -e .state/public ]]; then public --profile async --profile stripe ps -a;
    else compose --profile async --profile stripe ps -a; fi
    ;;
  *)
    echo 'Uso: manage.sh preflight|stage|cutover --infrastructure-checked|rollback --data-compatible|renew|status'
    ;;
esac
