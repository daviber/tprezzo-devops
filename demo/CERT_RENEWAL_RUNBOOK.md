# Cert Renewal Runbook

Data intervento: `2026-06-10`
Host: `188.245.184.80`
Dominio: `tprezzo.duckdns.org`

Configurazione Compose corrente usata nei comandi:

```bash
export COMPOSE_PROJECT_NAME=tprezzo-demo
export APP_DOMAIN=tprezzo.duckdns.org
export APP_ROOT_REL=../tprezzo
export APP_ENV_FILE=../tprezzo/.env.demo
```

## Obiettivo

Fix cert TLS scaduto su `https://tprezzo.duckdns.org`.

Errore browser:

```text
NET::ERR_CERT_DATE_INVALID
```

## 1. Entrata VPS

SSH usato:

```bash
ssh -p 22 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=5 root@188.245.184.80
```

## 2. Check stato stack + cert installato

Cmd:

```bash
cd /opt/tprezzo/devops
docker compose -p "$COMPOSE_PROJECT_NAME" -f docker-compose.demo.yml ps
ls -la ./demo/certbot/conf/live
ls -la ./demo/certbot/conf/live/tprezzo.duckdns.org
openssl x509 -in ./demo/certbot/conf/live/tprezzo.duckdns.org/fullchain.pem -noout -dates -issuer -subject
docker compose -p "$COMPOSE_PROJECT_NAME" -f docker-compose.demo.yml \
  logs --tail 80 nginx
```

Esito:

```text
notBefore=Mar 11 21:56:16 2026 GMT
notAfter=Jun  9 21:56:15 2026 GMT
issuer=C = US, O = Let's Encrypt, CN = E8
subject=CN = tprezzo.duckdns.org
```

Conclusione: cert scaduto.

## 3. Check preflight ACME

Scopo: confermare che nginx serva challenge HTTP, che VPS esca verso Let's Encrypt.

Cmd:

```bash
cd /opt/tprezzo/devops
mkdir -p ./demo/certbot/www/.well-known/acme-challenge
echo ok > ./demo/certbot/www/.well-known/acme-challenge/preflight
curl -fsS -H 'Host: tprezzo.duckdns.org' http://127.0.0.1/.well-known/acme-challenge/preflight
wget -qO- https://acme-v02.api.letsencrypt.org/directory | head -c 200
docker compose -p "$COMPOSE_PROJECT_NAME" -f docker-compose.demo.yml \
  exec -T nginx nginx -T | sed -n '1,220p'
```

Esito:

- preflight locale OK
- reachability ACME OK
- conf nginx OK

## 4. Renew cert

Cmd eseguito:

```bash
cd /opt/tprezzo/devops
docker compose -p "$COMPOSE_PROJECT_NAME" --profile certbot \
  -f docker-compose.demo.yml run --rm --no-deps certbot \
  renew --webroot -w /var/www/certbot
```

Esito:

```text
Congratulations, all renewals succeeded:
  /etc/letsencrypt/live/tprezzo.duckdns.org/fullchain.pem (success)
```

## 5. Reload nginx con nuovo cert

Cmd:

```bash
cd /opt/tprezzo/devops
docker compose -p "$COMPOSE_PROJECT_NAME" -f docker-compose.demo.yml \
  exec -T nginx nginx -t
docker compose -p "$COMPOSE_PROJECT_NAME" -f docker-compose.demo.yml \
  exec -T nginx nginx -s reload
```

## 6. Verify cert nuovo

Cmd:

```bash
cd /opt/tprezzo/devops
openssl x509 -in ./demo/certbot/conf/live/tprezzo.duckdns.org/fullchain.pem -noout -dates -issuer -subject
```

Esito:

```text
notBefore=Jun 10 08:35:49 2026 GMT
notAfter=Sep  8 08:35:48 2026 GMT
issuer=C = US, O = Let's Encrypt, CN = YE2
subject=CN = tprezzo.duckdns.org
```

Conclusione: renew OK. nginx ricaricato senza restart.

## 7. Cmd unico rapido per prossima volta

```bash
ssh -p 22 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=5 root@188.245.184.80 "
  set -euo pipefail
  cd /opt/tprezzo/devops
  export COMPOSE_PROJECT_NAME=tprezzo-demo
  export APP_DOMAIN=tprezzo.duckdns.org
  export APP_ROOT_REL=../tprezzo
  export APP_ENV_FILE=../tprezzo/.env.demo
  docker compose -p \"\$COMPOSE_PROJECT_NAME\" --profile certbot -f docker-compose.demo.yml run --rm --no-deps certbot renew --webroot -w /var/www/certbot
  docker compose -p \"\$COMPOSE_PROJECT_NAME\" -f docker-compose.demo.yml exec -T nginx nginx -t
  docker compose -p \"\$COMPOSE_PROJECT_NAME\" -f docker-compose.demo.yml exec -T nginx nginx -s reload
  openssl x509 -in ./demo/certbot/conf/live/tprezzo.duckdns.org/fullchain.pem -noout -dates -issuer -subject
"
```

## 8. Nota deploy app

Deploy app post-renew non eseguito in stesso giro. Cmd previsto:

```bash
bash devops/demo/script/deploy.sh
```
