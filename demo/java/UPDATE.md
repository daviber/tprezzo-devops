# Pubblicare una nuova versione frontend e backend Java

Da Mac, con Docker Desktop avviato e accesso SSH alla demo, eseguire in ordine:

```bash
cd /Users/davidebertolo/Documents/Git/T_PREZZO/tprezzo-devops
RELEASE="java-demo-$(date +%Y%m%d-%H%M%S)"

# 1. Copia configurazione corrente dalla demo; nuovi tag immagine.
bash demo/java/update-release.sh prepare "$RELEASE"

# 2. Compila frontend, API e worker locali in immagini Linux amd64.
bash demo/java/build-release.sh "$RELEASE"

# 3. Carica immagini e pubblica con fermo demo e drain worker.
bash demo/java/update-release.sh publish "$RELEASE"
```

La build usa le directory locali aggiornate:

- Frontend: `/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit`.
- API e worker: `/Users/davidebertolo/Documents/Git/T_PREZZO/tprezzo-backend`.

Include modifiche locali non committate; non esegue automaticamente `git pull`.
Il Dockerfile frontend esegue `npm run build`. Nessuna suite di test
applicativi viene eseguita dagli script: collaudo a carico del proprietario.

`prepare` non ferma servizi: copia sotto lock env, manifest, hash frontend e
supporto installato dalla demo attiva in `.local/releases/<id>` con permessi privati.
Congela anche il nuovo supporto locale in `support/`: Compose, config/manage,
script manutenzione e Nginx, conservando le sottodirectory. Runner e hash
SHA-256 vengono fissati nello stesso package. Preserva
chiave Next Server Actions, credenziali, namespace storage, relay e tuning.
Se la nuova versione richiede variabili backend aggiuntive, inserirle nel
nuovo `backend.env` privato prima della pubblicazione; modifiche al
`frontend.env` richiedono build successiva. Non usare `.env` di sviluppo come
configurazione demo. Una configurazione o un file di supporto remoto cambiati dopo `prepare`
bloccano la pubblicazione prima del fermo: scegliere un nuovo ID e preparare
nuovamente.

Modifiche successive al supporto locale richiedono un nuovo `prepare` con
nuovo ID; la pubblicazione usa lo snapshot congelato. Package creati con
il vecchio flusso senza `support_schema` sono rifiutati: prepararli di nuovo,
senza aggiungere manualmente hash o file al vecchio package.

Embedding disabilitato normalmente: `NEXT_PUBLIC_AUTH_EMBEDDED=false` e
`AUTH_FRAME_ANCESTORS=`. Per iframe autorizzato configurare **prima della build**
`NEXT_PUBLIC_AUTH_EMBEDDED=true` e `AUTH_FRAME_ANCESTORS=https://portal.dominio-controllato.it`.
Più origini HTTPS esatte separate da virgola; niente path, wildcard, credenziali
o schemi HTTP. L'operatore deve verificare proprietà e controllo di ogni origine.

`publish` richiede 6 GiB liberi prima del caricamento e 2 GiB dopo, valida
digest immagini, hash del supporto e certificato, e usa il lock condiviso con la manutenzione.
Verifica le RPC DB richieste in sola lettura prima di fermare altri servizi;
non avvia immagini nuove se queste RPC mancano. La presenza RPC non sostituisce
la query di verifica delle policy/ACL della migrazione.
Ferma Nginx/relay/frontend/API, drena la coda con il vecchio worker ancora
acceso (max 15 minuti), ferma worker, applica env e supporto verificati e ricrea API/frontend/
worker. Riattiva relay e Nginx pubblico dopo health positivi. Non applica SQL.
La configurazione DB deve già essere compatibile con la nuova applicazione.

## Prima pubblicazione delle correzioni sicurezza

Preparare immagini e backup prima del fermo. Poi, dalla stessa shell con `RELEASE`:

```bash
ssh root@188.245.184.80 \
  'bash -s -- /opt/tprezzo-java/releases/java-demo-20261011-01' \
  < demo/java/security-maintenance.sh
```

Lo script chiude ingressi/produttori, drena la coda e ferma il worker. Se il
drain fallisce, non applicare SQL. Dopo fermo riuscito applicare migrazione
sicurezza 1, migrazione default ACL 2 tramite owner autorizzato, poi query
verifica seguendo `SECURITY_REMEDIATION_2026-10-14.md` nel workspace e
`Tprezzo_replit/migrations/SECURITY_2026-10-14.md`. L'eventuale limite managed
su default ACL va gestito come descritto nel runbook; non ignorare errori
della migrazione 1 o delle verifiche sui controlli obbligatori.

Solo dopo SQL e verifiche pubblicare con `update-release.sh publish "$RELEASE"`.
La manutenzione lascia volutamente servizi fermi fra SQL e pubblicazione.
Non usare `manage.sh stage/cutover/rollback` e non riavviare immagini vecchie
per colmare questa finestra. La pubblicazione installa Compose/Nginx aggiornati
prima di avviare API/frontend/worker; non modifica dati o policy SQL.

La directory attiva resta
`/opt/tprezzo-java/releases/java-demo-20261011-01`; contiene ora config
aggiornabile e snapshot storici in `.state/updates/<id>/before`.
I tag immagine restano immutabili per release. Package caricati in
`/opt/tprezzo-java/updates/<id>`, versione applicativa in
`.state/deployed-version`. Questo aggiornamento Java → Java mantiene
l'ownership Compose; non usare `ship.sh`/`stage`/`cutover` per questo flusso.
Container Node legacy, immagini precedenti, certificati e dati sono conservati.

## Stato dopo pubblicazione

```bash
ssh root@188.245.184.80 \
  'bash /opt/tprezzo-java/releases/java-demo-20261011-01/manage.sh status'
```

Aprire https://tprezzo.duckdns.org ed eseguire il collaudo applicativo.
Gli script di update sono stati verificati per sintassi e CLI; la prima
pubblicazione con questo nuovo flusso resta da collaudare sul server.

## Errori e rollback Java

Nessun rollback automatico: in caso di errore servizi possono restare fermi.
Snapshot e fase sono conservati in `.state/update-phase` e
`.state/updates/<id>`. Errori di drain interrompono senza cambiare consumer.
Un upload interrotto conserva il package remoto; usare un nuovo ID anziché
sovrascrivere una release esistente.

Dopo verifica della compatibilità dei dati scritti dalla nuova versione:

```bash
bash demo/java/update-release.sh rollback "$RELEASE" --data-compatible
```

Ripete chiusura ingressi/drain, ripristina le sei configurazioni e il supporto precedenti
e ricrea i container Java dalle immagini conservate. Il parametro è l'ID
dell'aggiornamento da annullare. Non annulla modifiche DB/documenti; rifiuta
config o supporto diversi da package/snapshot per evitare di annullare deploy successivi.
In un update interrotto durante installazione accetta singoli file solo se
corrispondono a uno dei due snapshot verificati, senza accettare modifiche terze.
File opzionali assenti prima dell'update vengono rimossi nel ripristino.
Snapshot incompleto, file alterati o config non coerente bloccano il rollback:
conservare il fermo e analizzare `.state/update-phase` e gli snapshot; non
aggirare gli hash e non riaprire gli ingressi su un'installazione parziale.
Con le nuove policy sicurezza il precedente backend può essere incompatibile:
`--data-compatible` richiede verifica sia dei dati sia dello schema/policy DB.
Non ripristina DB, grant pubblici o policy vulnerabili.
Il vecchio `manage.sh rollback` riguarda invece il ritorno a Node.

Destinazione SSH da `demo/settings.sh`; `JAVA_ACTIVE_DIR` può indicare
un'altra installazione Java esistente sotto `/opt/tprezzo-java/releases/`.
La preparazione scarica la config attiva: fare una nuova preparazione dopo
ogni aggiornamento pubblicato o rollback.
