# Demo — deploy frontend separato

Per migrare la demo Node attuale ad API/worker Java usare
[il nuovo runbook](java/README.md). Gli script qui sotto sono conservati per il
frontend storico: non eseguirli sulla demo durante il passaggio Java.
Il frontend locale ora risiede in `../Tprezzo_replit`, accanto a questo repository.

Questo branch distribuisce Next.js SSR, Nginx e Certbot. API Java e worker Java hanno deployment/configurazione propri; lo stack frontend non li avvia. Non è stato eseguito alcun deploy durante questa migrazione.

## Preparazione

Configurare `settings.sh` per l'installazione desiderata. I valori esistenti identificano la demo frontend, non un nuovo endpoint Java.

```bash
cp .env.demo.example .env.demo
chmod 600 .env.demo
```

Compilare le sei variabili richieste dal validatore: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_BACKEND_API_URL`, `BACKEND_API_URL`, `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`. Il file è ignorato da Git. Nessun segreto Java/provider appartiene a questo file; il validatore rifiuta le chiavi backend note anche se vuote. Conservare la chiave Next tra deploy successivi.

Il browser deve raggiungere l'URL pubblico Java via HTTPS. SSR deve raggiungere il suo URL Java dal container; non usare `localhost` per un backend esterno al container. Entrambi gli URL includono `/api/v1`. Questo progetto non inventa host/demo Java né aggiunge un proxy Nginx Java: i template Nginx servono il frontend. Gli URL pubblici vengono incorporati durante la build Docker del proprietario.

Java deve consentire l'origine frontend per CORS e mutazioni e verificare il bearer Supabase. Il webhook Stripe deve raggiungere Java `/api/v1/stripe/webhook` attraverso l'infrastruttura backend, indipendentemente da Next.

## Script disponibili al proprietario

- `script/install.sh`: installazione Docker e deploy frontend.
- `script/deploy.sh`: sincronizzazione, build della sola image `app`, avvio `app`/`nginx` e controllo HTTP frontend.
- `script/init-nginx-letsencrypt.sh`: gestione certificati/frontend HTTPS.

Docker mantiene Next per SSR, Auth callback e Server Actions di trasporto. Nessuno stage worker, provider AWS, Stripe SDK, Poppler o Canvas server è richiesto dal frontend.

Prima di sincronizzare o costruire, gli script controllano i container con label del progetto Compose: un vecchio `worker` Node o `stripe-cli` ferma il deploy, anche se arrestato. Non li rimuovono automaticamente e non usano `--remove-orphans`. Coordinare la migrazione manualmente seguendo [ownership e cutover](../../docs/migration/OWNERSHIP_E_CUTOVER.md). Il guard non certifica l'assenza di worker esterni a questo progetto: serve inventario dell'ambiente reale.

Il controllo app verifica Next/Nginx, non Java, DB, provider o coda. Il proprietario esegue build/test applicativi, prove end-to-end e audit di isolamento tenant prima della distribuzione. Stato e contratti mancanti nel [piano](../../docs/migration/PIANO_PULIZIA_FRONTEND_BACKEND_JAVA.md).
