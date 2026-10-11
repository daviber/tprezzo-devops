# Demo Java: installazione e passaggio da Node

Inventario live **11 ottobre 2026, circa 22:20 CEST**, sola lettura.
Branch `codex/java-demo`. Preparazione iniziale senza modifiche live.
Il proprietario ha poi autorizzato build Docker e installazione con fermo demo;
test funzionali applicativi restano al proprietario.

## Installazione completata

**11 ottobre 2026, circa 22:54 CEST**: release `java-demo-20261011-01`
pubblicata su **https://tprezzo.duckdns.org**.
Directory attiva `/opt/tprezzo-java/releases/java-demo-20261011-01`;
progetto Compose `tprezzo-java-demo`.

- API, worker, frontend e Nginx healthy; relay Stripe attivo verso Java.
- API e worker async abilitati, instance `demo-hetzner-eu1`, una replica worker,
  concurrency price-centric 1. Coda pending/processing 0 al controllo finale.
- HTTPS homepage, healthz e OpenAPI 200; actuator pubblico 404;
  HTTP redirige a HTTPS, dashboard anonima a `/login` sul dominio pubblico.
- Worker health aggregata UP, nessun evento errore polling/recovery/coda nei
  log iniziali. Endpoint del singolo componente health non esposto (404);
  non usarlo come requisito quando i componenti health sono nascosti.
- Signing secret Stripe verificato senza stamparlo; relay con connessione
  TLS stabilita, target `/api/v1/stripe/webhook`, zero riavvii.
- Quattro container Node legacy conservati e fermi, con snapshot ID/image
  in `.state/legacy.json`. Directory, immagini e dati legacy non eliminati.
- RAM disponibile **5273 MiB**, disco libero **6359 MiB** (83% usato);
  container complessivi idle ~871 MiB, zero OOM/restart al controllo.

Build API/worker Java e frontend eseguite in Docker sul computer locale;
nessuna suite di test o job applicativo creato. Al proprietario il collaudo
login, upload/elaborazione async e pagamenti. I valori idle non dimostrano
le prestazioni sotto carico. Migrazioni SQL non applicate da questo deploy.

Sorgenti: backend `a2d9aa99fa83ff06f6cc0fb17ac37cbcec5bf808`, frontend
`d746d9dbf06f8286623dd532fb8d917e44a20317` con working tree locale
(spostamento devops e modifica preesistente allo script bundle worker).
Il frontend viene dalla directory aggiornata indicata dal proprietario.

## Macchina e dimensionamento

VPS `188.245.184.80`, Ubuntu 24.04.3 x86_64, **4 vCPU / 7751 MiB RAM**.
RAM disponibile 5945 MiB, swap assente. Root 38 GiB, **8,5 GiB liberi**, 77% usato.
Docker 29.3.0, Compose 5.1.0. TLS valido fino **10 dicembre 2026**.
Il campione idle non misura picchi o prestazioni sotto carico.

Legacy attivo: app Node ~277 MiB, worker Node ~64 MiB, Nginx ~10 MiB,
relay Stripe ~25 MiB. Nessun limite CPU/RAM attuale, nessun database locale.
Cache build ~22,13 GB, di cui ~19,83 GB recuperabili secondo Docker; valori
con layer condivisi, non sommabili alle image per stimare spazio recuperabile.
Nessuna cache/image eliminata.

| Servizio | Limite RAM | Heap | Quota CPU | CPU shares |
| --- | ---: | ---: | ---: | ---: |
| API Java | 1536 MiB | 768 MiB | 2 | 2048 |
| Worker Java, 1 replica | 2560 MiB | 1408 MiB | 1,5 | 512 |
| Next SSR | 1024 MiB | old-space 640 MiB | 1 | 1024 |
| Nginx | 128 MiB | — | 0,5 | 1024 |
| Relay Stripe, opzionale | 128 MiB | — | 0,25 | 256 |

Totale continuativo con relay **5376 MiB (5,25 GiB)**: circa 2,32 GiB fuori dai
limiti container per host/cache/margine. Certbot è un job temporaneo da 256 MiB.
Heap lascia memoria per thread, classi, buffer, PDF e tmpfs; tmpfs conta nel
limite container. Reservation non prealloca RAM.

Quote CPU sommano 5,25 su 4 vCPU: consentono burst condivisi, non garantiscono
5,25 core. In contesa le shares favoriscono API rispetto worker. G1, heap
espliciti, virtual thread HTTP e keepalive Nginx sono una base da collaudare,
non un ottimo dimostrato da benchmark.

Partire con **1 job async**, Bedrock concurrency 2 per JVM. Dopo misure valutare
concurrency 2 nella stessa replica, controllando RSS, CPU, p95 e throttling;
non duplicare worker da 2,5 GiB su questa macchina. API + worker possono
raggiungere 4 chiamate Bedrock aggregate. Smoke Java del 9 ottobre: ~176 s/job,
con molta attesa provider. Pending nuovi possono essere cancellati dopo
**300 s fissi**: la coda non è un buffer illimitato.

## Architettura e conservazione

```text
HTTPS :443 -> Nginx -> /api/v1/* -> API Java :8080
                   -> altre route -> Next SSR :5000
API + worker -> Supabase REST/Auth/coda, S3, Textract, Bedrock, Stripe
Worker health :9081 solo rete Docker; nessuna porta worker pubblica
```

Next resta necessario per UI/SSR/Auth callback/Server Actions. Nessun DB,
Redis, SQS o worker Node aggiunto al nuovo stack.

Legacy: `/opt/tprezzo/{tprezzo,devops}`, progetto `tprezzo-demo`.
Nuovo: `/opt/tprezzo-java/releases/<id>`, progetto `tprezzo-java-demo`.
Tag per release e manifest image SHA256; env frontend sigillato alla build.
Nessun `rsync --delete`, `down`, `prune` o eliminazione volumi/image legacy.
Guard blocca progetto Java posseduto da altra directory release.
Script dedicati alla **prima migrazione**: aggiornamenti futuri vanno coordinati
dalla release attiva senza avviare una seconda ownership della coda.

Conservare `PRICE_CENTRIC_INSTANCE_ID=demo-hetzner-eu1`, bucket/prefissi demo:
un nuovo instance ID isola coda ma impedisce lettura dei PDF esistenti.
Standby: async disabilitato, worker/relay fermi, Nginx loopback 18080/18443,
API loopback 18000. Non avviare manualmente profilo async durante standby.

## Verifiche prima dello switch

1. Build immagini autorizzata dal proprietario e verifica startup/health;
   collaudo funzionale frontend/backend a carico del proprietario dopo deploy.
2. Eseguire `inspect.sql` nel SQL Editor Supabase: cataloghi/trigger/permessi
   J03/guard worker/coda, senza RPC mutanti. Live presenti provisioning, claim,
   renew, recovery e cancellazione pending; coda demo pending=0/processing=0
   al momento dell'inventario. Questo non certifica definizioni SQL/RLS/tenant.
   Se necessarie, migrazioni J03 in `Tprezzo_replit/migrations/20261005_1_*`
   poi `20261005_2_*`; nessuno script le applica automaticamente.
3. Inventariare consumer/produttori esterni a Compose: processi host, altre
   macchine e API altrove. Mai consumer Node/Java concorrenti sulla stessa coda.
   Il guard controlla il progetto noto, non tutte le altre macchine.
4. Conservare `AWS_TEXTRACT_BUCKET`: senza bucket Java può renderizzare tutte
   le pagine PDF in memoria. Credenziali/modelli devono corrispondere alla demo.
5. Relay Stripe predefinito mantiene modalità demo e inoltra al nuovo
   `/api/v1/stripe/webhook`. Verificare signing secret listener prima dello
   switch. In alternativa endpoint HTTPS Stripe già configurato e opzione
   `prepare --no-stripe-relay`. Mai entrambi i relay attivi.

Health non certifica business/provider. Presenza RPC OpenAPI non certifica
migrazioni. Nessuna rotazione Auth/JWKS o modifica IAM per questo deployment;
Auth remote mantenuto, JWKS valutabile solo con signing asimmetrico verificato.

## Configurazione privata, senza build

Da `tprezzo-devops`:

```bash
python3 demo/java/config.py prepare \
  --release java-demo-20261011-01 \
  --output .local/releases/java-demo-20261011-01 \
  --backend-env ../tprezzo-backend/.env \
  --frontend-env ../Tprezzo_replit/.env.demo
```

Genera env separati `0600` ignorati da Git: backend/provider, frontend, relay
Stripe e runtime Compose. Cambia URL frontend/CORS e namespace demo solo nei
nuovi file; env sorgenti invariati, segreti non stampati. Se manca chiave Next,
ne genera una: conservarla e riusare `frontend.env` come fonte nei deploy futuri.
Rifiuta output esistenti. Verificare credenziali/feature flag generati; `.env`
locale e demo possono puntare ad ambienti diversi, il cutover ne controlla
Supabase e namespace S3 contro container Node live.

## Build e caricamento del proprietario

`build-release.sh` **esegue build Next/npm nel Dockerfile**: eccezione autorizzata
dal proprietario per questa installazione; nessuna suite di test applicativi.
Compila Linux amd64 su computer locale/runner, mai sul VPS. Java copia solo
sorgenti: `.env`/Git esclusi dai layer. Nessun test applicativo automatico.

```bash
bash demo/java/build-release.sh java-demo-20261011-01
bash demo/java/ship.sh java-demo-20261011-01
```

Se solo l'esportazione fallisce dopo build completata, riprendere con
`build-release.sh <id> --export-only`: verifica hash frontend e digest amd64
senza ricompilare o aggiornare le immagini. Export e preflight selezionano
esplicitamente `linux/amd64`, anche con image store containerd.

SSH verifica host key; directory release nuova, archivio compresso direttamente
a `docker load`, senza seconda copia sul VPS. Richiede 6 GiB liberi prima,
2 GiB dopo; dimensione reale image può richiedere più spazio. Nessun prune.
Se insufficiente, ampliare disco o concordare pulizia della sola cache build
inutilizzata, preservando tutte le image/container demo.
SSH configurabile via `demo/settings.sh` o variabili
`DEPLOY_HOST/DEPLOY_USER/DEPLOY_PORT/SSH_IDENTITY_FILE`.

## Standby e switch con fermo servizio

Sul VPS:

```bash
cd /opt/tprezzo-java/releases/java-demo-20261011-01
bash manage.sh stage
bash manage.sh status
# Dopo le verifiche sopra:
bash manage.sh cutover --infrastructure-checked
```

Standby controlla startup/health. Aprire `:18443` non certifica E2E: browser API
puntano ancora al dominio su443 legacy, HTTP18080 redirige al dominio pubblico.
Collaudo completo dopo switch, oppure tunnel/risoluzione locale che preservino
dominio, porta443 e origine.

Switch accetta disservizio: salva ID/image/stato legacy, ferma Nginx/relay/app
Node, attende coda vuota con worker Node acceso, poi ferma worker Node.
Attesa max15 minuti; errori DB interrompono senza trasferire coda. Abilita
async Java, avvia worker/relay Java, pubblica Nginx su80/443. Legacy solo fermato.
Lock impedisce operazioni simultanee; vecchie variabili Compose shell ignorate.

In caso di errore nessun rollback automatico riaccende Node. Stato conservato,
ingressi possono restare chiusi. Leggere `status` e `.state/phase`;
`.state/publishing` indica che Java potrebbe essere già stato raggiungibile
anche se controllo finale fallito.

## Rollback

Verificare compatibilità dei dati scritti da Java prima di riattivare Node.
Rollback infrastrutturale non annulla dati/documenti.

```bash
bash manage.sh rollback --data-compatible
```

Chiude ingressi/produttori Java, lascia worker drenare pending/processing,
poi arresta worker Java. Riavvia soltanto container legacy originariamente
attivi, dagli stessi ID/image; nessuna eliminazione dati/image/config.
Se coda/lease non drenano o DB non verificabile, mantiene ingressi chiusi.
Risolvere lease secondo runbook backend prima di riavviare Node.
Non cancellare snapshot storico per forzare un retry della migrazione.

## Operatività

```bash
bash inspect.sh
bash manage.sh status
docker stats --no-stream
bash manage.sh renew
```

Log Docker: max10 MB × 5 file per servizio. Nessuna schedulazione TLS installata:
dopo switch pianificare `manage.sh renew` sulla release attiva prima della
scadenza. Certificati legacy rimangono riferimento: Nginx monta read-only,
Certbot solo durante rinnovo RW. In rollback usare runbook rinnovo legacy.

Fonti: [Compose](https://docs.docker.com/reference/compose-file/services/),
[virtual threads Spring](https://docs.spring.io/spring-boot/reference/features/spring-application.html),
[Temurin](https://raw.githubusercontent.com/docker-library/docs/master/eclipse-temurin/README.md),
[Nginx](https://raw.githubusercontent.com/docker-library/docs/master/nginx/README.md),
[smoke Java 9 ottobre](../../../tprezzo-backend/docs/infrastructure/ASYNC_UPLOAD_SMOKE_2026-10-09.md).
