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

`prepare` non ferma servizi: copia sotto lock env, manifest e hash frontend
dalla demo attiva in `.local/releases/<id>` con permessi privati. Preserva
chiave Next Server Actions, credenziali, namespace storage, relay e tuning.
Se la nuova versione richiede variabili backend aggiuntive, inserirle nel
nuovo `backend.env` privato prima della pubblicazione; modifiche al
`frontend.env` richiedono build successiva. Non usare `.env` di sviluppo come
configurazione demo. Una configurazione remota cambiata dopo `prepare`
blocca la pubblicazione prima del fermo: scegliere un nuovo ID e preparare
nuovamente.

`publish` richiede 6 GiB liberi prima del caricamento e 2 GiB dopo, valida
digest immagini e certificato, e usa il lock condiviso con la manutenzione.
Ferma Nginx/relay/frontend/API, drena la coda con il vecchio worker ancora
acceso (max 15 minuti), ferma worker, applica config e ricrea API/frontend/
worker. Riattiva relay e Nginx pubblico dopo health positivi. Non applica SQL.
La configurazione DB deve già essere compatibile con la nuova applicazione.

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

Ripete chiusura ingressi/drain, ripristina le sei configurazioni precedenti
e ricrea i container Java dalle immagini conservate. Il parametro è l'ID
dell'aggiornamento da annullare. Non annulla modifiche DB/documenti; rifiuta
config diverse da package/snapshot per evitare di annullare deploy successivi.
Il vecchio `manage.sh rollback` riguarda invece il ritorno a Node.

Destinazione SSH da `demo/settings.sh`; `JAVA_ACTIVE_DIR` può indicare
un'altra installazione Java esistente sotto `/opt/tprezzo-java/releases/`.
La preparazione scarica la config attiva: fare una nuova preparazione dopo
ogni aggiornamento pubblicato o rollback.
