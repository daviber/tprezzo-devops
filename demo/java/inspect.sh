#!/usr/bin/env bash
set -euo pipefail

# Read-only VPS inventory. Run directly or via: ssh <host> 'bash -s' < inspect.sh
# No settings/env files are sourced. Never print container Env, process commands,
# Docker history, Compose config, application logs or certificate private keys.
APP_DOMAIN="${APP_DOMAIN:-tprezzo.duckdns.org}"
CERTIFICATE_FILE="${CERTIFICATE_FILE:-/opt/tprezzo/devops/demo/certbot/conf/live/$APP_DOMAIN/fullchain.pem}"

if [[ ! "$APP_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
  printf '[inspect] APP_DOMAIN non valido.\n' >&2
  exit 1
fi

section() {
  printf '\n[inspect] %s\n' "$1"
}

optional() {
  local command_name="$1"
  shift
  if command -v "$command_name" >/dev/null 2>&1; then
    "$command_name" "$@" || printf '[inspect] %s non disponibile.\n' "$command_name" >&2
  else
    printf '[inspect] %s non installato.\n' "$command_name"
  fi
}

section 'Sistema e CPU'
date -u '+UTC %Y-%m-%d %H:%M:%S'
uname -srm
optional uptime
printf 'CPU disponibili: '
optional nproc
if command -v lscpu >/dev/null 2>&1; then
  LC_ALL=C lscpu | awk '/^(Architecture|CPU\(s\)|On-line CPU\(s\) list|Model name|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|CPU max MHz|CPU min MHz|Virtualization type):/'
fi

section 'RAM e swap'
optional free -h
if [[ -r /proc/meminfo ]]; then
  awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree|CommitLimit|Committed_AS):/' /proc/meminfo
fi
optional vmstat 1 2
for pressure in cpu memory io; do
  if [[ -r "/proc/pressure/$pressure" ]]; then
    printf '%s pressure: ' "$pressure"
    tr '\n' ';' < "/proc/pressure/$pressure"
    printf '\n'
  fi
done

section 'Disco e inode'
optional df -hT / /opt /var/lib/docker
optional df -i / /opt /var/lib/docker

section 'Porte TCP in ascolto (senza processi o argomenti)'
optional ss -lnt

section 'Docker: motore, container e limiti'
if command -v docker >/dev/null 2>&1 && docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  docker info --format 'Version={{.ServerVersion}} Driver={{.Driver}} CgroupDriver={{.CgroupDriver}} CgroupVersion={{.CgroupVersion}} CPUs={{.NCPU}} MemoryBytes={{.MemTotal}} Root={{.DockerRootDir}}'
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    docker inspect --format 'Name={{.Name}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}} Restarts={{.RestartCount}} MemoryBytes={{.HostConfig.Memory}} ReservationBytes={{.HostConfig.MemoryReservation}} MemorySwapBytes={{.HostConfig.MemorySwap}} NanoCPUs={{.HostConfig.NanoCpus}} CPUQuota={{.HostConfig.CpuQuota}} CPUPeriod={{.HostConfig.CpuPeriod}} CPUShares={{.HostConfig.CpuShares}} CPUSet={{.HostConfig.CpusetCpus}} PidsLimit={{.HostConfig.PidsLimit}} ReadOnly={{.HostConfig.ReadonlyRootfs}}' "$container_id" \
      || printf '[inspect] Container terminato durante inventario.\n' >&2
  done < <(docker ps -aq)

  section 'Docker: utilizzo istantaneo'
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}\t{{.NetIO}}\t{{.BlockIO}}' \
    || printf '[inspect] Stats non disponibili.\n' >&2

  section 'Docker: immagini e cache aggregate (nessun prune)'
  docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'
  # system df reports Build Cache totals without exposing build commands/history.
  docker system df || printf '[inspect] Spazio Docker non disponibile.\n' >&2
else
  printf '[inspect] Docker non installato o daemon non accessibile.\n'
fi

section 'Certificato pubblico legacy'
if [[ -r "$CERTIFICATE_FILE" ]] && command -v openssl >/dev/null 2>&1; then
  openssl x509 -in "$CERTIFICATE_FILE" -noout -subject -issuer -dates -serial -fingerprint -sha256 -ext subjectAltName
else
  printf '[inspect] Certificato pubblico non leggibile o openssl non installato.\n'
fi

section 'Completato: nessuna modifica a servizi, immagini, dati o credenziali'
