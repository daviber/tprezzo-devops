#!/usr/bin/env bash
# VPS only. Default inventory is read-only; --apply prunes only aged build cache.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

mode="${1:---inspect}"
if (( $# > 1 )) || [[ "$mode" != --inspect && "$mode" != --apply ]]; then
  printf 'Uso: disk-maintenance.sh [--inspect|--apply]\n' >&2
  exit 2
fi
[[ "$(uname -s)" == Linux && "$EUID" == 0 ]] || {
  printf '[disk-maintenance] Richiesti Linux e root.\n' >&2
  exit 1
}
[[ -d /opt/tprezzo-java/releases && -S /var/run/docker.sock ]] || {
  printf '[disk-maintenance] Layout VPS/socket Docker locale assenti.\n' >&2
  exit 1
}
for command_name in python3 docker flock; do
  command -v "$command_name" >/dev/null || {
    printf '[disk-maintenance] Comando richiesto assente: %s\n' "$command_name" >&2
    exit 1
  }
done
[[ -f /opt/tprezzo-java/.manage.lock ]] || {
  printf '[disk-maintenance] Lock deploy assente; nessun file creato.\n' >&2
  exit 1
}
# Open the existing shared lock read-only: no creation/truncation, even in inspect.
exec 9</opt/tprezzo-java/.manage.lock
if ! flock -n 9; then
  printf '[disk-maintenance] %s skip: deploy/manutenzione in corso.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 0
fi

python3 - "$mode" <<'PY'
import datetime
import hashlib
import json
import os
import pwd
import re
import subprocess
import sys

MODE = sys.argv[1]
SOCKET = "unix:///var/run/docker.sock"
ROOT_HOME = pwd.getpwuid(0).pw_dir
# Ignore DOCKER_HOST/CONTEXT/TLS, BUILDX_BUILDER and BUILDKIT_HOST from callers.
CLEAN_ENV = {"PATH": os.environ["PATH"], "HOME": ROOT_HOME,
             "DOCKER_CONFIG": ROOT_HOME + "/.docker", "LC_ALL": "C"}


class MaintenanceError(Exception):
    pass


def log(event, **metadata):
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print(json.dumps({"utc": timestamp, "event": event, **metadata}, sort_keys=True), flush=True)


def docker(*arguments, timeout=60):
    try:
        result = subprocess.run(["docker", "--host", SOCKET, *arguments],
                                env=CLEAN_ENV, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise MaintenanceError("Docker command timed out") from None
    if result.returncode:
        # Suppress raw stderr/history/command output: metadata only in cron logs.
        raise MaintenanceError("Docker command failed: " + arguments[0] + " (exit " + str(result.returncode) + ")")
    return result.stdout


def verify_builder():
    context = json.loads(docker("context", "inspect", "default", "--format", "{{json .Endpoints}}"))
    if context.get("docker", {}).get("Host") != SOCKET:
        raise MaintenanceError("Default Docker context is not the local Unix socket")
    info = docker("buildx", "inspect", "default")
    driver = re.search(r"(?m)^Driver:\s+(\S+)\s*$", info)
    endpoints = re.findall(r"(?m)^Endpoint:\s+(\S+)\s*$", info)
    if not driver or driver[1] != "docker" or len(endpoints) != 1 or endpoints[0] not in ("default", SOCKET):
        raise MaintenanceError("Default Buildx builder must use driver docker and the local socket")


def snapshot():
    # Inspect whitelisted identity fields only. Never request Config.Env/logs.
    image_rows = [json.loads(line) for line in docker(
        "image", "ls", "--all", "--no-trunc", "--digests", "--format", "{{json .}}").splitlines() if line]
    images = sorted((row["Repository"], row["Tag"], row["Digest"], row["ID"]) for row in image_rows)
    ids = docker("container", "ls", "--all", "--quiet", "--no-trunc").split()
    containers = []
    if ids:
        lines = docker("container", "inspect", "--format", "{{.Id}} {{.Image}} {{.State.Running}}", *ids).splitlines()
        containers = sorted(tuple(line.split()) for line in lines)
        if len(containers) != len(ids) or any(len(row) != 3 for row in containers):
            raise MaintenanceError("Container identity snapshot incomplete")
    space = [json.loads(line) for line in docker("system", "df", "--format", "{{json .}}").splitlines() if line]
    cache = [{key: row.get(key) for key in ("Type", "TotalCount", "Active", "Size", "Reclaimable")}
             for row in space if row.get("Type") == "Build Cache"]
    root = docker("info", "--format", "{{.DockerRootDir}}").strip()
    free = subprocess.run(["df", "-B1", "--output=avail", root], env=CLEAN_ENV,
                          capture_output=True, text=True, check=True, timeout=30).stdout.splitlines()
    return {"images": images, "containers": containers, "cache": cache, "free_bytes": int(free[-1].strip())}


def report(event, state):
    identities = {key: state[key] for key in ("images", "containers")}
    log(event, free_bytes=state["free_bytes"], cache=state["cache"], image_refs=len(state["images"]),
        image_ids=len({row[3] for row in state["images"]}), containers=len(state["containers"]),
        running=sum(row[2] == "true" for row in state["containers"]),
        identities_sha256=hashlib.sha256(json.dumps(identities, sort_keys=True).encode()).hexdigest())


try:
    verify_builder()
    before = snapshot()
    report("before", before)
    if MODE == "--inspect":
        log("inspect_complete", changes=False)
        sys.exit(0)
    log("prune_start", builder="default", filter="until=168h", max_used_space="2gb", cache_only=True)
    prune_error = None
    try:
        # The only mutating operation. Never image/container/volume/system prune.
        docker("buildx", "prune", "--builder", "default", "--all", "--force",
               "--filter", "until=168h", "--max-used-space", "2gb", timeout=1200)
    except MaintenanceError as error:
        prune_error = str(error)
    after = snapshot()
    report("after", after)
    images_preserved = before["images"] == after["images"]
    containers_preserved = before["containers"] == after["containers"]
    log("preservation", images_preserved=images_preserved, containers_preserved=containers_preserved,
        freed_bytes=after["free_bytes"] - before["free_bytes"])
    if not images_preserved or not containers_preserved:
        raise MaintenanceError("Image/container identities or running states changed; manual review required")
    if prune_error:
        raise MaintenanceError(prune_error)
    log("apply_complete", cache_only=True)
except (MaintenanceError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
    message = str(error) if isinstance(error, MaintenanceError) else "Inventory unavailable; raw details suppressed"
    log("failed", reason=message)
    sys.exit(1)
PY
