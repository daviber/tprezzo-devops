#!/usr/bin/env python3
"""Prepare private Compose env files; inspect Supabase without mutating RPCs."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

HERE = Path(__file__).resolve().parent
PUBLIC_KEYS = set("COMPOSE_PROJECT_NAME APP_DOMAIN INSTANCE_ID ASYNC_ENABLED STRIPE_RELAY_ENABLED API_IMAGE WORKER_IMAGE FRONTEND_IMAGE NGINX_IMAGE CERTBOT_IMAGE STRIPE_IMAGE CERTBOT_CONF_DIR CERTBOT_WWW_DIR".split())
FRONTEND_KEYS = set("NEXT_PUBLIC_APP_URL NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY NEXT_PUBLIC_BACKEND_API_URL BACKEND_API_URL NEXT_SERVER_ACTIONS_ENCRYPTION_KEY NEXT_PUBLIC_SUPPORT_EMAIL NEXT_PUBLIC_AUTH_EMBEDDED AUTH_FRAME_ANCESTORS".split())
RPCS = set("tprezzo_provision_invited_account claim_price_centric_jobs renew_price_centric_job_lease update_price_centric_job_progress complete_price_centric_job fail_or_retry_price_centric_job recover_expired_price_centric_jobs cancel_expired_pending_price_centric_jobs tprezzo_is_auth_session_active tprezzo_auth_session_matches_assurance tprezzo_acquire_document_processing_lease tprezzo_release_document_processing_lease tprezzo_processing_visible_products".split())
KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


class ConfigError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ConfigError(message)


def read_env(path):
    """Parse single-line dotenv only. Never execute or import shell environment."""
    values, interpolate = {}, {}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, raw = line.partition("=")
        key, raw = key.strip(), raw.strip()
        require(separator and KEY.fullmatch(key) and key not in values,
                f"Dotenv non valido o chiave duplicata: riga {number}.")
        if raw.startswith(("'", '"')):
            quote, index, result = raw[0], 1, []
            while index < len(raw):
                char = raw[index]
                if char == quote:
                    break
                if char == "\\" and index + 1 < len(raw) and raw[index + 1] in (quote, "\\"):
                    index += 1
                    char = raw[index]
                result.append(char)
                index += 1
            require(index < len(raw) and (not raw[index + 1:].strip() or raw[index + 1:].lstrip().startswith("#")),
                    f"Quote/multiline dotenv non valido: riga {number}.")
            value = "".join(result)
        else:
            value = re.split(r"\s+#", raw, maxsplit=1)[0].rstrip()
        require(not any(char in value for char in "\r\n\x00"), f"Valore multiline non ammesso: {key}.")
        values[key] = value
        interpolate[key] = not raw.startswith("'")

    def resolve(key, trail=()):
        require(key in values and key not in trail, f"Riferimento dotenv sconosciuto o ciclico: {key}.")
        if not interpolate[key]:
            return values[key]
        value = REF.sub(lambda match: resolve(match[1], trail + (key,)), values[key])
        require("${" not in value, f"Interpolazione dotenv non supportata: {key}.")
        return value
    return {key: resolve(key) for key in values}


def write_env(path, values):
    """Atomic file replacement, mode 600; Compose single quotes keep dollars literal."""
    path = Path(path)
    data = []
    for key, value in values.items():
        require(KEY.fullmatch(key) and isinstance(value, str), "Assegnazione env non valida.")
        require(not any(char in value for char in "\r\n\x00"), f"Valore multiline non ammesso: {key}.")
        escaped = value.replace("\\", "\\\\").replace("'", "\\'")
        data.append(f"{key}='{escaped}'\n")
    descriptor, temporary = tempfile.mkstemp(prefix=".env-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write("".join(data))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def credential(values, key):
    value = values.get(key, "")
    require(len(value) >= 20 and not re.search(r"replace|changeme|placeholder|your[-_]", value, re.I),
            f"Credenziale assente o placeholder: {key}.")
    return value


def https_url(value):
    parsed = urllib.parse.urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
            and not parsed.query and not parsed.fragment, "URL HTTPS non valido.")
    require(not re.search(r"replace|project-ref|example", parsed.hostname, re.I), "URL progetto placeholder.")
    return value.rstrip("/")


def check_runtime(runtime):
    require(re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}", runtime.get("COMPOSE_PROJECT_NAME", ""))
            and runtime["COMPOSE_PROJECT_NAME"] != "tprezzo-demo", "Progetto Compose deve essere distinto dal legacy.")
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]*", runtime.get("APP_DOMAIN", "")), "APP_DOMAIN non valido.")
    require(re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", runtime.get("INSTANCE_ID", "")), "INSTANCE_ID non valido.")
    for key in ("ASYNC_ENABLED", "STRIPE_RELAY_ENABLED"):
        require(runtime.get(key, "false") in ("true", "false"), f"Booleano non valido: {key}.")
    for key in ("API_IMAGE", "WORKER_IMAGE", "FRONTEND_IMAGE", "NGINX_IMAGE", "CERTBOT_IMAGE", "STRIPE_IMAGE"):
        value = runtime.get(key, "")
        if key in ("API_IMAGE", "WORKER_IMAGE", "FRONTEND_IMAGE") or value:
            require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/:@-]*", value) and "replace" not in value
                    and not value.endswith(":latest"), f"Image release non valida: {key}.")
            require(re.search(r"@sha256:[0-9a-f]{64}$", value) is not None
                    or ("@" not in value and ":" in value.rsplit("/", 1)[-1]
                        and bool(value.rsplit(":", 1)[-1])), f"Image deve avere tag esplicito o digest: {key}.")
    for key in ("CERTBOT_CONF_DIR", "CERTBOT_WWW_DIR"):
        require(runtime.get(key, "").startswith("/") and ".." not in Path(runtime[key]).parts,
                f"Percorso certificati non valido: {key}.")
    for key, expected in (("BACKEND_ENV_FILE", "./backend.env"), ("FRONTEND_ENV_FILE", "./frontend.env"), ("STRIPE_ENV_FILE", "./stripe.env")):
        require(runtime.get(key) == expected, f"Compose deve usare il file env verificato: {key}.")


def check_embedding(frontend):
    embedded = frontend.get("NEXT_PUBLIC_AUTH_EMBEDDED", "false")
    require(embedded in ("true", "false"), "NEXT_PUBLIC_AUTH_EMBEDDED deve essere true oppure false.")
    configured = frontend.get("AUTH_FRAME_ANCESTORS", "").strip()
    origins = configured.split(",") if configured else []
    require(embedded != "true" or origins, "Embedding richiede AUTH_FRAME_ANCESTORS esplicite.")
    require(embedded == "true" or not origins, "Disabilitare embedding rimuovendo AUTH_FRAME_ANCESTORS.")
    for value in origins:
        origin = value.strip()
        parsed = urllib.parse.urlsplit(origin)
        try:
            valid_port = parsed.port is None or 1 <= parsed.port <= 65535
        except ValueError:
            valid_port = False
        require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
                and parsed.path == "" and not parsed.query and not parsed.fragment and valid_port
                and not re.search(r"[\s*;\\\\]", origin)
                and re.fullmatch(r"[a-zA-Z0-9.-]+", parsed.hostname),
                "AUTH_FRAME_ANCESTORS richiede origini HTTPS esatte, senza path o wildcard.")


def check_cors(base, configured):
    origins = configured.split(",")
    require(base in origins and len(origins) == len(set(origins))
            and set(origins) <= {base, "http://localhost:3000"},
            "CORS backend richiede origine pubblica; unica origine aggiuntiva consentita: http://localhost:3000.")


def check_values(runtime, backend, frontend, stripe):
    check_runtime(runtime)
    base = "https://" + runtime["APP_DOMAIN"]
    supabase = https_url(backend.get("TPREZZO_SUPABASE_URL", ""))
    require(urllib.parse.urlsplit(supabase).path in ("", "/"), "Supabase URL deve avere solo origine.")
    for key in ("TPREZZO_SUPABASE_PUBLISHABLE_KEY", "TPREZZO_SUPABASE_SERVICE_ROLE_KEY"):
        credential(backend, key)
    require(backend.get("TPREZZO_DATA_ACCESS_MODE") == "rest", "Backend richiede accesso REST.")
    for key in ("PRICE_CENTRIC_S3_BUCKET", "PRICE_CENTRIC_S3_PREFIX", "AWS_TEXTRACT_BUCKET"):
        require(backend.get(key) and not re.search(r"replace|placeholder", backend[key], re.I), f"Configurazione S3/OCR mancante: {key}.")
    require(backend.get("PRICE_CENTRIC_INSTANCE_ID") == runtime["INSTANCE_ID"], "Instance ID backend/runtime non coerenti.")
    require(backend.get("TPREZZO_FRONTEND_BASE_URL") == base, "Frontend URL backend non coerente.")
    check_cors(base, backend.get("TPREZZO_HTTP_CORS_ALLOWED_ORIGINS", ""))
    expected = {"NEXT_PUBLIC_APP_URL": base, "NEXT_PUBLIC_BACKEND_API_URL": base + "/api/v1",
                "BACKEND_API_URL": "http://api:8080/api/v1", "NEXT_PUBLIC_SUPABASE_URL": supabase}
    require(all(frontend.get(key, "").rstrip("/") == value for key, value in expected.items()), "URL frontend/backend/Supabase non coerenti.")
    credential(frontend, "NEXT_PUBLIC_SUPABASE_ANON_KEY")
    try:
        encryption_key = base64.b64decode(frontend.get("NEXT_SERVER_ACTIONS_ENCRYPTION_KEY", ""), validate=True)
    except (ValueError, base64.binascii.Error):
        encryption_key = b""
    require(len(encryption_key) in (16, 24, 32), "Chiave stabile Next encryption non valida.")
    require(set(frontend) <= FRONTEND_KEYS, "Frontend contiene nomi env non consentiti.")
    check_embedding(frontend)
    for key, token, role in (
        ("TPREZZO_SUPABASE_PUBLISHABLE_KEY", backend["TPREZZO_SUPABASE_PUBLISHABLE_KEY"], "anon"),
        ("TPREZZO_SUPABASE_SERVICE_ROLE_KEY", backend["TPREZZO_SUPABASE_SERVICE_ROLE_KEY"], "service_role"),
        ("NEXT_PUBLIC_SUPABASE_ANON_KEY", frontend["NEXT_PUBLIC_SUPABASE_ANON_KEY"], "anon"),
    ):
        require(role != "anon" or not token.startswith("sb_secret_"), f"Credenziale privilegiata non consentita: {key}.")
        if token.count(".") == 2:
            try:
                payload = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))
            except (ValueError, UnicodeError):
                raise ConfigError(f"JWT configurato non valido: {key}.") from None
            require(isinstance(payload, dict) and payload.get("role") == role, f"Ruolo credenziale non coerente: {key}.")
            require(not payload.get("ref") or payload["ref"] == urllib.parse.urlsplit(supabase).hostname.split(".")[0], "Credenziale Supabase riferita a progetto diverso.")
    require(set(stripe) <= {"STRIPE_API_KEY"}, "Stripe env contiene chiavi non consentite.")
    if runtime.get("STRIPE_RELAY_ENABLED") == "true":
        credential(stripe, "STRIPE_API_KEY")
        credential(backend, "TPREZZO_STRIPE_WEBHOOK_SECRET")


def load(directory):
    directory = Path(directory)
    values = [read_env(directory / filename) for filename in ("runtime.env", "backend.env", "frontend.env", "stripe.env")]
    check_values(*values)
    return values


def migrate_bedrock_models(backend):
    """Set release model IDs and remove tuning from the reverted 5.5 migration."""
    defaults = read_env(HERE / "backend.env.example")
    for key in ("AWS_BEDROCK_PRIMARY_MODEL_ID", "AWS_BEDROCK_FALLBACK_MODEL_ID"):
        require(bool(defaults.get(key)), f"Modello Bedrock della release assente: {key}.")
        backend[key] = defaults[key]
    for key in ("AWS_BEDROCK_EFFORT", "AWS_BEDROCK_API_CALL_TIMEOUT", "AWS_BEDROCK_API_CALL_ATTEMPT_TIMEOUT"):
        backend.pop(key, None)


def prepare(args):
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.release), "Release slug non valido.")
    output = Path(args.output)
    require(not any((output / name).exists() for name in ("runtime.env", "backend.env", "frontend.env", "stripe.env")), "Output contiene già env; preservare chiavi/release esistenti.")
    runtime = read_env(HERE / "runtime.env.example")
    runtime.update(APP_DOMAIN=args.domain, INSTANCE_ID="demo-hetzner-eu1", ASYNC_ENABLED="false",
                   STRIPE_RELAY_ENABLED="false" if args.no_stripe_relay else "true",
                   BACKEND_ENV_FILE="./backend.env", FRONTEND_ENV_FILE="./frontend.env", STRIPE_ENV_FILE="./stripe.env")
    for service in ("api", "worker", "frontend"):
        runtime[service.upper() + "_IMAGE"] = getattr(args, service + "_image") or f"tprezzo-java-{service}:{args.release}"
    canonical = HERE.parents[2] / "tprezzo-backend" / ".env.example"
    require(canonical.is_file(), "Example backend canonico non trovato nel workspace.")
    allowed_backend_keys = read_env(canonical)
    backend = {key: value for key, value in read_env(args.backend_env).items() if key in allowed_backend_keys}
    base = "https://" + args.domain
    cors = base
    configured_cors = backend.get("TPREZZO_HTTP_CORS_ALLOWED_ORIGINS", "")
    if base in configured_cors.split(","):
        check_cors(base, configured_cors)
        cors = configured_cors
    backend.update(TPREZZO_FRONTEND_BASE_URL=base, TPREZZO_HTTP_CORS_ALLOWED_ORIGINS=cors,
                   TPREZZO_DATA_ACCESS_MODE="rest", PRICE_CENTRIC_INSTANCE_ID=runtime["INSTANCE_ID"],
                   AWS_EC2_METADATA_DISABLED="true", AWS_BEDROCK_GLOBAL_CONCURRENCY="2")
    migrate_bedrock_models(backend)
    for key, suffix in (("TPREZZO_SUPABASE_ISSUER", "/auth/v1"), ("TPREZZO_SUPABASE_JWKS_URL", "/auth/v1/.well-known/jwks.json")):
        backend[key] = backend.get(key, "${TPREZZO_SUPABASE_URL}" + suffix).replace("${TPREZZO_SUPABASE_URL}", backend.get("TPREZZO_SUPABASE_URL", "").rstrip("/"))
    frontend = {key: value for key, value in read_env(args.frontend_env).items() if key in FRONTEND_KEYS}
    frontend.update(NEXT_PUBLIC_APP_URL=base, NEXT_PUBLIC_BACKEND_API_URL=base + "/api/v1", BACKEND_API_URL="http://api:8080/api/v1")
    generated = not frontend.get("NEXT_SERVER_ACTIONS_ENCRYPTION_KEY")
    if generated:
        frontend["NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"] = base64.b64encode(secrets.token_bytes(32)).decode()
    stripe = {"STRIPE_API_KEY": backend.get("TPREZZO_STRIPE_SECRET_KEY", "")}
    check_values(runtime, backend, frontend, stripe)
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, values in zip(("runtime", "backend", "frontend", "stripe"), (runtime, backend, frontend, stripe)):
        write_env(output / (name + ".env"), values)
    print("Env preparati; segreti non mostrati.")
    if generated:
        print("Nuova chiave Next generata: conservare frontend.env e riusare questa chiave nei deploy successivi.")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


def supabase_request(backend, path, method="GET", headers=None):
    token = credential(backend, "TPREZZO_SUPABASE_SERVICE_ROLE_KEY")
    request = urllib.request.Request(https_url(backend["TPREZZO_SUPABASE_URL"]) + path, method=method,
                                    headers={"apikey": token, "Authorization": "Bearer " + token, **(headers or {})})
    try:
        return urllib.request.build_opener(NoRedirect).open(request, timeout=15)
    except urllib.error.HTTPError as error:
        raise ConfigError(f"Verifica Supabase rifiutata: HTTP {error.code}.") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ConfigError("Verifica Supabase non disponibile; operazione bloccata.") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preparation = commands.add_parser("prepare")
    for name in ("release", "output", "backend-env", "frontend-env"):
        preparation.add_argument("--" + name, required=True)
    preparation.add_argument("--domain", default="tprezzo.duckdns.org")
    preparation.add_argument("--no-stripe-relay", action="store_true")
    for service in ("api", "worker", "frontend"):
        preparation.add_argument("--" + service + "-image")
    for command in ("get", "check", "check-built", "set-async", "queue", "db-check"):
        child = commands.add_parser(command)
        child.add_argument("directory")
        if command in ("get", "set-async"):
            child.add_argument("value")
    args = parser.parse_args()
    if args.command == "prepare":
        return prepare(args)
    if args.command == "get":
        require(args.value in PUBLIC_KEYS, "Chiave runtime non consentita.")
        runtime = read_env(Path(args.directory) / "runtime.env")
        check_runtime(runtime)
        require(args.value in runtime, "Chiave runtime assente.")
        return print(runtime[args.value])
    runtime, backend, frontend, stripe = load(args.directory)
    if args.command == "check":
        print("Configurazione valida; segreti non mostrati.")
    elif args.command == "check-built":
        directory = Path(args.directory)
        actual = hashlib.sha256((directory / "frontend.env").read_bytes()).hexdigest()
        require(actual == (directory / "frontend.sha256").read_text().strip(),
                "Frontend env modificato dopo build: ricompilare con nuovo release-id.")
        references = set()
        for line in (directory / "images.manifest").read_text().splitlines():
            fields = line.split()
            require(len(fields) == 2 and re.fullmatch(r"sha256:[0-9a-f]{64}", fields[1]), "Manifest immagini non valido.")
            require(fields[0] not in references, "Riferimento immagine duplicato nel manifest.")
            references.add(fields[0])
        expected = {runtime[key] for key in ("API_IMAGE", "WORKER_IMAGE", "FRONTEND_IMAGE", "NGINX_IMAGE", "STRIPE_IMAGE", "CERTBOT_IMAGE")}
        require(references == expected, "Manifest diverso dalle immagini runtime configurate.")
        print("Manifest e configurazione frontend build coerenti.")
    elif args.command == "set-async":
        require(args.value in ("true", "false"), "Usare true oppure false.")
        runtime["ASYNC_ENABLED"] = args.value
        write_env(Path(args.directory) / "runtime.env", runtime)
    elif args.command == "queue":
        query = urllib.parse.urlencode({"select": "id", "instance_id": "eq." + runtime["INSTANCE_ID"], "status": "in.(pending,processing)"})
        with supabase_request(backend, "/rest/v1/price_centric_jobs?" + query, "HEAD", {"Prefer": "count=exact", "Range": "0-0"}) as response:
            count = re.search(r"/(\d+)$", response.headers.get("Content-Range", ""))
            require(count is not None, "Conteggio coda non disponibile; operazione bloccata.")
            print(int(count[1]))
    elif args.command == "db-check":
        with supabase_request(backend, "/rest/v1/", headers={"Accept": "application/openapi+json"}) as response:
            schema = json.loads(response.read(4 * 1024 * 1024))
        require(isinstance(schema, dict) and isinstance(schema.get("paths"), dict), "Schema REST non disponibile; operazione bloccata.")
        missing = RPCS - {path.removeprefix("/rpc/") for path in schema.get("paths", {}) if path.startswith("/rpc/")}
        require(not missing, "RPC mancanti nello schema esposto: " + ", ".join(sorted(missing)))
        print("RPC richieste presenti nello schema; nessuna RPC eseguita.")


if __name__ == "__main__":
    try:
        main()
    except (ConfigError, OSError, ValueError) as error:
        message = str(error) if isinstance(error, ConfigError) else "File o risposta non validi; dettagli e segreti omessi."
        print("[java-config] " + message, file=sys.stderr)
        sys.exit(1)
