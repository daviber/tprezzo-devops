#!/usr/bin/env python3
"""Preserve the existing demo by container ID. Never persist Docker Env/secrets."""
import json
import os
from pathlib import Path
import subprocess
import sys

import config


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True,
                                   env={k: os.environ[k] for k in ("PATH", "HOME") if k in os.environ})


def inspect(ids):
    return json.loads(docker("inspect", *ids)) if ids else []


def live():
    ids = docker("ps", "-aq", "--filter", "label=com.docker.compose.project=tprezzo-demo").split()
    return inspect(ids)


def snapshot(directory):
    target = directory / ".state" / "legacy.json"
    if target.exists():
        raise ValueError("Snapshot esiste già; non sovrascrivere lo stato di rollback")
    rows = live()
    by_service = {r["Config"]["Labels"].get("com.docker.compose.service"): r for r in rows}
    for service in ("app", "worker", "nginx"):
        if service not in by_service or not by_service[service]["State"]["Running"]:
            raise ValueError("Container demo non attivo: " + service)
    if len(rows) != len(by_service):
        raise ValueError("Repliche legacy multiple: inventariare prima del cutover")
    runtime = config.read_env(directory / "runtime.env")
    backend = config.read_env(directory / "backend.env")
    for service in ("app", "worker"):
        values = dict(x.split("=", 1) for x in by_service[service]["Config"]["Env"] if "=" in x)
        checks = {
            "TPREZZO_SUPABASE_URL": values.get("NEXT_PUBLIC_SUPABASE_URL", values.get("SUPABASE_URL", "")),
            "PRICE_CENTRIC_S3_BUCKET": values.get("PRICE_CENTRIC_S3_BUCKET", ""),
            "PRICE_CENTRIC_S3_PREFIX": values.get("PRICE_CENTRIC_S3_PREFIX", "price-centric/uploads"),
            "AWS_TEXTRACT_BUCKET": values.get("AWS_TEXTRACT_BUCKET", ""),
        }
        for key, expected in checks.items():
            if not expected or backend.get(key, "").rstrip("/") != expected.rstrip("/"):
                raise ValueError("Config Java diversa dalla demo " + service + ": " + key)
        if values.get("PRICE_CENTRIC_INSTANCE_ID") != runtime["INSTANCE_ID"]:
            raise ValueError("Instance ID diverso: i PDF esistenti devono restare leggibili")
    target.parent.mkdir(mode=0o700, exist_ok=True)
    records = [{"id": r["Id"], "name": r["Name"], "image": r["Image"],
                "service": r["Config"]["Labels"].get("com.docker.compose.service"),
                "running": r["State"]["Running"]} for r in rows]
    target.write_text(json.dumps(records, indent=2) + "\n")
    target.chmod(0o600)
    print("Snapshot legacy salvato; container, immagini e directory conservati")


def saved(directory, service):
    path = directory / ".state" / "legacy.json"
    records = json.loads(path.read_text())
    matches = [r for r in records if r["service"] == service and r["running"]]
    if not matches:
        return []
    current = inspect([r["id"] for r in matches])
    for r, c in zip(matches, current):
        if r["image"] != c["Image"]:
            raise ValueError("Immagine legacy cambiata; interrompere rollback automatico")
    return [r["id"] for r in matches]


def main():
    action, directory, *extra = sys.argv[1:]
    directory = Path(directory)
    if action == "assert-project":
        project = config.read_env(directory / "runtime.env")["COMPOSE_PROJECT_NAME"]
        ids = docker("ps", "-aq", "--filter", "label=com.docker.compose.project=" + project).split()
        for row in inspect(ids):
            working_dir = row["Config"]["Labels"].get("com.docker.compose.project.working_dir", "")
            if not working_dir or Path(working_dir).resolve() != directory.resolve():
                raise ValueError("Progetto Java posseduto da altra release: non aggiornare da questa directory")
    elif action == "snapshot":
        snapshot(directory)
    elif action in ("stop", "start"):
        ids = saved(directory, extra[0])
        if ids:
            args = [action]
            if action == "stop":
                args += ["--time", "330"]
            subprocess.run(["docker", *args, *ids], check=True, stdout=subprocess.DEVNULL,
                           env={k: os.environ[k] for k in ("PATH", "HOME") if k in os.environ})
    elif action == "assert-stopped":
        if any(r["State"]["Running"] for r in inspect(saved(directory, "worker"))):
            raise ValueError("Worker Node ancora attivo")
    else:
        raise ValueError("Comando legacy non riconosciuto")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, config.ConfigError) as exc:
        print("[legacy] " + str(exc), file=sys.stderr)
        sys.exit(1)
