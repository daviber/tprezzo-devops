#!/usr/bin/env bash
# Run on the VPS before the security SQL migration. No builds, SQL, deletion or restart.
set -euo pipefail
ACTIVE="${1:?Uso: security-maintenance.sh /opt/tprezzo-java/releases/<release-attiva>}"
[[ "$ACTIVE" =~ ^/opt/tprezzo-java/releases/[a-z0-9][a-z0-9._-]{0,63}$ && -d "$ACTIVE" \
   && "$(readlink -f "$ACTIVE")" == "$ACTIVE" ]] || {
  echo 'Directory release Java non valida' >&2; exit 1;
}
cd "$ACTIVE"
exec 9>/opt/tprezzo-java/.manage.lock
flock -n 9 || { echo 'Altra operazione Java in corso' >&2; exit 1; }
docker() { env -i PATH="$PATH" HOME="$HOME" docker --host unix:///var/run/docker.sock "$@"; }
compose() {
  docker compose --env-file "$ACTIVE/runtime.env" -f "$ACTIVE/compose.yml" \
    -f "$ACTIVE/compose.public.yml" --profile async --profile stripe "$@"
}
python3 "$ACTIVE/config.py" check "$ACTIVE"
python3 "$ACTIVE/legacy.py" assert-project "$ACTIVE"
[[ -f .state/public ]] || { echo 'Release Java non pubblicata' >&2; exit 1; }
[[ "$(python3 "$ACTIVE/config.py" get "$ACTIVE" ASYNC_ENABLED)" == true ]] || {
  echo 'La manutenzione richiede release pubblicata con async attivo' >&2; exit 1;
}
compose config --quiet
echo '[security] Chiusura ingressi/produttori; worker resta attivo per drain.'
compose stop nginx stripe-cli frontend api
elapsed=0
while :; do
  active_jobs="$(python3 "$ACTIVE/config.py" queue "$ACTIVE")"
  [[ "$active_jobs" =~ ^[0-9]+$ ]] || { echo 'Coda non verificabile; ingressi restano chiusi' >&2; exit 1; }
  (( active_jobs > 0 )) || break
  (( elapsed < 900 )) || { echo 'Drain oltre 15 minuti; non applicare SQL, risolvere job/lease' >&2; exit 1; }
  echo "[security] Drain: $active_jobs job attivi"
  sleep 5
  elapsed=$((elapsed + 5))
done
compose stop -t 330 worker
mkdir -p .state
printf '%s\n' security-maintenance > .state/phase
echo '[security] App e worker fermi. Applicare SQL e verifiche; poi pubblicare il rilascio nuovo.'
echo '[security] Nessun riavvio automatico. Non riattivare le immagini precedenti con le nuove policy.'
