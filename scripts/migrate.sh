#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$DEVOPS_DIR/.env"
COMPOSE_FILE="$DEVOPS_DIR/docker-compose.yml"
SQL_DIR="$DEVOPS_DIR/sql"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$DEVOPS_DIR/.env.example" "$ENV_FILE"
  echo "[devops] creato .env da .env.example"
fi

if [[ ! -d "$SQL_DIR" ]]; then
  echo "[devops] cartella sql non trovata: $SQL_DIR"
  exit 1
fi

POSTGRES_PASSWORD="$(awk -F= '/^POSTGRES_PASSWORD=/{print substr($0, index($0, "=") + 1); exit}' "$ENV_FILE")"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD%$'\r'}"

if [[ -z "$POSTGRES_PASSWORD" ]]; then
  echo "[devops] POSTGRES_PASSWORD non trovato in $ENV_FILE"
  exit 1
fi

if [[ "${POSTGRES_PASSWORD:0:1}" == '"' && "${POSTGRES_PASSWORD: -1}" == '"' ]]; then
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:1:${#POSTGRES_PASSWORD}-2}"
fi
if [[ "${POSTGRES_PASSWORD:0:1}" == "'" && "${POSTGRES_PASSWORD: -1}" == "'" ]]; then
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:1:${#POSTGRES_PASSWORD}-2}"
fi

docker compose \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_FILE" \
  exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
  psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres <<'SQL'
CREATE TABLE IF NOT EXISTS public.devops_schema_migrations (
  filename TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL

while IFS= read -r migration_file; do
  filename="$(basename "$migration_file")"

  if [[ "$filename" == "01_schema.sql" ]]; then
    continue
  fi

  sql_filename="${filename//\'/\'\'}"

  already_applied="$(docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -tA -U supabase_admin -d postgres \
    -c "SELECT 1 FROM public.devops_schema_migrations WHERE filename = '$sql_filename' LIMIT 1;" </dev/null)"

  if [[ "$already_applied" == "1" ]]; then
    echo "[devops][migrate] skip $filename (already applied)"
    continue
  fi

  echo "[devops][migrate] apply $filename"

  docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < "$migration_file"

  docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
    -c "INSERT INTO public.devops_schema_migrations (filename) VALUES ('$sql_filename') ON CONFLICT (filename) DO NOTHING;" </dev/null

done < <(find "$SQL_DIR" -maxdepth 1 -type f -name '*.sql' -print | sort)

docker compose \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_FILE" \
  exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
  psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "NOTIFY pgrst, 'reload schema';" </dev/null

echo "[devops][migrate] notified PostgREST schema reload"

echo "[devops][migrate] done"
