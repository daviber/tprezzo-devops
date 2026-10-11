> **Documento storico del monolite Node.** Nel branch `codex/frontend-java-backend` consultare il [piano corrente](../../docs/migration/PIANO_PULIZIA_FRONTEND_BACKEND_JAVA.md). Sorgenti/API/worker e comandi qui descritti possono essere ritirati. Non usare questo documento per avviare consumer Node, applicare SQL o configurare segreti nel frontend. Contenuto storico conservato.

# Migrazione a AWS Textract + Bedrock

Questa guida e il Terraform associato servono a migrare l'estrazione documentale di Tprezzo da Gemini/Claude diretti a una pipeline AWS basata su:

- Amazon Textract per OCR/analisi documentale
- Amazon Bedrock per la strutturazione finale nel JSON che il codice usa gia oggi
- App che continua a girare su VPS in fase 1
- App Runner previsto in fase 2 senza cambiare di nuovo la logica applicativa

Per il bootstrap operativo dettagliato dell'account AWS usa anche:

- [devops/aws/AWS_ACCOUNT_BOOTSTRAP_STEP_BY_STEP.md](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/AWS_ACCOUNT_BOOTSTRAP_STEP_BY_STEP.md)

## Obiettivo

Ridurre al minimo le regressioni mantenendo invariati, per quanto possibile, i contratti interni gia usati dall'app:

- [tprezzo/lib/ai/bedrock.ts](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/tprezzo/lib/ai/bedrock.ts)
- [tprezzo/lib/ai/textract-bedrock.ts](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/tprezzo/lib/ai/textract-bedrock.ts)
- [tprezzo/app/api/agreements/extract/route.ts](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/tprezzo/app/api/agreements/extract/route.ts)
- [tprezzo/app/api/invoices/process/route.ts](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/tprezzo/app/api/invoices/process/route.ts)
- [tprezzo/lib/ai/matching.ts](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/tprezzo/lib/ai/matching.ts)

Il matching resta invariato. Cambia solo il backend di OCR/estrazione.

## Principio non negoziabile: security first

Prima di parlare di costo, performance o comodita, la regola deve essere questa:

- i documenti devono essere trattati come dati sensibili
- i modelli non devono usare i tuoi dati per training o service improvement
- il logging del contenuto deve restare disattivato salvo scelta esplicita e motivata
- la retention deve essere minima
- i permessi devono essere minimi

Per questo la migrazione proposta qui parte da 4 vincoli:

1. Amazon Bedrock va usato con invocation logging lasciato disabilitato
2. Amazon Textract va usato dentro un account messo in opt-out dai servizi AI supportati
3. i documenti temporanei su S3 vanno cifrati e cancellati rapidamente
4. l'app non deve scrivere prompt, OCR grezzo o documenti completi nei log applicativi

## Scelta raccomandata

### Fase 1

- VPS resta dove si trova
- Supabase resta dov'e
- AWS viene usato solo per OCR + LLM
- Regione consigliata: `eu-central-1`
- Modello Bedrock iniziale consigliato per il cutover: `anthropic.claude-sonnet-4-5-20250929-v1:0`
- Ottimizzazione successiva: passare a `eu.anthropic.claude-haiku-4-5-20251001-v1:0` come primario e tenere Sonnet 4.5 come fallback

### Perche questa scelta

- e la strada con meno regressioni, perche i prompt attuali sono gia fortemente ottimizzati per Claude
- Textract copre OCR, PDF, foto e testo scritto a mano meglio di un puro modello vision generalista
- Bedrock permette di restare in AWS senza riscrivere la logica di normalizzazione finale
- nella fase App Runner potrai togliere le access key statiche e usare un ruolo IAM, senza cambiare le API dell'app

## Architettura target consigliata

### Accordi

1. Documento in input
2. Textract estrae testo, tabelle e layout
3. L'app ricostruisce un testo leggibile e stabile per pagina
4. Bedrock converte quel contenuto nel JSON attuale degli accordi
5. Il resto del flusso resta invariato

### Fatture

1. Documento in input
2. Textract `AnalyzeExpense` o `StartExpenseAnalysis`
3. L'app usa il risultato Textract come base robusta per line items e metadati
4. Bedrock normalizza nel JSON attuale delle fatture
5. Matching e report restano invariati

## Strategia minima-regressione

Non consiglio una riscrittura delle route.

Consiglio invece di mantenere gli stessi export e sostituire i provider dietro le interfacce esistenti:

- `extractAgreementData()` resta text -> JSON, ma usa Bedrock al posto di Anthropic diretto
- `extractInvoiceData()` resta text -> JSON, ma usa Bedrock al posto di Anthropic diretto
- `extractAgreementDataFromPDF()` e `extractAgreementDataFromImages()` restano come punto di ingresso OCR/vision, ma usano Textract + Bedrock al posto di Gemini
- `extractInvoiceDataFromPDF()` e `extractInvoiceDataFromImages()` idem

In pratica:

- le route non cambiano quasi per nulla
- il contratto dati verso database e matching resta lo stesso
- il rischio si concentra nei moduli AI, dove e piu facile testare e fare rollback

## Routing raccomandato per tipo documento

### Fatture

- immagine o PDF singola pagina fino a 10 MB: `AnalyzeExpense`
- PDF multipagina o documenti piu pesanti: upload S3 temporaneo + `StartExpenseAnalysis` + polling da VPS
- se la risposta Textract e incompleta o incoerente: retry Bedrock con Sonnet 4.5

### Accordi

- immagine o PDF singola pagina: `AnalyzeDocument` con `TABLES`, `FORMS`, `LAYOUT`
- PDF multipagina: upload S3 temporaneo + `StartDocumentAnalysis` + polling da VPS
- se il documento e poco strutturato ma leggibile: usare anche i blocchi `LINE` come fallback

## Documenti fotografati e scritti a mano

Per i tuoi casi d'uso questa e la combinazione piu solida che rimane pragmatica:

- Textract per OCR e distinzione fra testo stampato e handwritten
- Bedrock per interpretazione finale e normalizzazione
- manual review solo quando falliscono controlli semplici di coerenza

I controlli minimi che consiglio di aggiungere prima del salvataggio sono:

- almeno un item estratto
- JSON valido
- prezzi non negativi
- sulle fatture: presenza di almeno uno tra `invoice_number`, `invoice_date`, `items`
- se Textract trova molte righe ma Bedrock restituisce pochi item, fare un retry con Sonnet 4.5

## Ottimizzazioni consigliate

### 1. Parti con Sonnet, poi ottimizza il costo

Per il primo cutover usa Sonnet 4.5, poi confronta su un dataset reale:

- 20 accordi
- 20 fatture
- almeno 5 casi fotografati
- almeno 5 casi con scrittura a mano o qualita mediocre

Se la differenza rispetto a Haiku 4.5 e trascurabile, sposta Haiku a modello primario e Sonnet a fallback.

### 2. Usa structured output su Bedrock

Quando passi a Bedrock, usa output JSON validato invece del parsing libero. Riduce molto i problemi di JSON troncato o sporco.

### 3. Conserva i documenti Textract poco tempo

I bucket temporanei Terraform scadono di default dopo 7 giorni. Servono per:

- riprocessare errori recenti
- audit tecnico minimo
- non accumulare costi inutili

Bucket separati:

- Textract per oggetti tecnici OCR;
- price-centric per file caricati in attesa/completamento job.

### 4. Non usare SNS/SQS nella prima fase

Per ora non serve. Polling semplice dal VPS e sufficiente, piu facile da capire e da governare.

Il processamento price-centric asincrono usa:

- queue PostgreSQL `price_centric_jobs`;
- worker Docker dedicato sullo stesso VPS;
- claim atomico con lease;
- bucket S3 price-centric dedicato per upload temporanei;
- bucket Textract separato e stessi modelli Bedrock gia configurati.

Entrambi i bucket sono creati da Terraform. App e worker usano stessa identita IAM
del backend AI. `instance_id` separa queue e prefissi oggetto; `worker_id` e lease
gestiscono repliche concorrenti. Il bucket price-centric e' privato, cifrato e ha
lifecycle default 7 giorni.

Replica e concorrenza sono due limiti distinti:

```text
job simultanei = worker replicas * worker concurrency
call Bedrock potenziali =
  min(
    AWS_BEDROCK_GLOBAL_CONCURRENCY,
    job simultanei * AWS_BEDROCK_PAGE_CONCURRENCY
  )
```

Partire con `1 * 1` e aumentare una sola dimensione alla volta dopo verifica quote,
throttling, CPU e RAM.

Tracker implementazione:

- `docs/PRICE_CENTRIC_ASYNC_IMPLEMENTATION_CHECKLIST.md`

Quote account, baseline VPS e tuning operativo:

- `devops/aws/PRICE_CENTRIC_TUNING_RUNBOOK.md`

### 5. Non spostare subito l'app su AWS

La migrazione del backend AI e gia abbastanza sensibile. Tenere la VPS per la prima fase riduce variabili e aiuta a capire dove nascono eventuali regressioni.

### 6. Non loggare contenuti documentali

Nel codice applicativo evita di loggare:

- prompt completi
- output OCR completi
- immagini o PDF in base64
- JSON completi di fatture o accordi se contengono dati sensibili

Logga solo:

- id job
- tipo documento
- numero pagine
- numero item estratti
- eventuali error code

## Passi AWS manuali da fare una sola volta

### 0. Attiva il gate sicurezza/privacy prima di tutto

Questo step viene prima del provisioning applicativo.

1. crea una AWS Organization anche se oggi hai un solo account
2. allega alla root dell'organizzazione una AI services opt-out policy che imposti `default = optOut`
3. verifica che Textract rientri nei servizi coperti dall'opt-out
4. su Bedrock lascia disabilitato il model invocation logging
5. evita di mettere dati sensibili in tag, nomi risorsa o campi free-form

Ho aggiunto un file pronto da usare:

- [devops/aws/ai-services-opt-out-all.json](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/ai-services-opt-out-all.json)

Scelta intenzionale:

- non ho messo questa parte nel Terraform applicativo per non mischiare bootstrap organizzativo e stack runtime
- voglio che questo passaggio sia esplicito, visibile e deciso da te una volta sola

### 1. Metti in sicurezza il root user

Fallo subito prima di qualsiasi altra attivita:

1. abilita MFA sul root
2. non creare access key sul root
3. usa il root solo per operazioni che lo richiedono davvero

### 2. Crea un accesso amministrativo normale

Consiglio:

1. abilita IAM Identity Center
2. crea un utente amministrativo dedicato
3. usa quel profilo per console, AWS CLI e Terraform

Se vuoi la via piu semplice possibile all'inizio, puoi anche creare un utente IAM admin dedicato solo al bootstrap. Non consiglio di restare operativamente col root.

### 3. Configura AWS CLI

Esempio con profilo locale:

```bash
aws configure sso
aws sts get-caller-identity --profile tprezzo-admin
```

### 4. Abilita Bedrock Anthropic

Questo passaggio lo lascio intenzionalmente manuale, per tenerti il controllo:

1. entra nella console Bedrock in `eu-central-1`
2. apri il catalogo modelli
3. seleziona `Claude Sonnet 4.5`
4. completa il First Time Use form Anthropic
5. ripeti per `Claude Haiku 4.5` se vuoi gia predisporre il fallback

Nota importante:

- Textract non richiede una "attivazione" separata: bastano permessi IAM, regione corretta e billing attivo
- Bedrock per i modelli Anthropic richiede FTU / use-case details la prima volta
- Bedrock non va configurato con model invocation logging per default: lascialo disabilitato se non hai un requisito specifico e dati gia redatti

## Terraform

Il Terraform e in [devops/aws/terraform/README.md](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/terraform/README.md).

Questo stack crea solo quello che serve nella fase 1:

- bucket S3 temporaneo per documenti Textract asincroni
- bucket S3 temporaneo per upload price-centric
- utente IAM applicativo per la VPS
- ruolo IAM pronto per App Runner
- policy minima per Textract, Bedrock e due bucket S3 dedicati

Scelta intenzionale:

- non creo access key con Terraform, cosi i segreti non finiscono nello state
- non automatizzo l'accettazione FTU/EULA di Bedrock, cosi hai controllo esplicito su quel passaggio

## Credenziali per la VPS

Dopo `terraform apply`:

1. vai su IAM -> Users -> utente VPS creato da Terraform
2. crea una access key per `Application running outside AWS`
3. salva `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` nel vault / `.env` della VPS
4. usa `textract_bucket_name` per Textract
5. usa `price_centric_bucket_name` per `PRICE_CENTRIC_S3_BUCKET`

Quando passerai ad App Runner:

- rimuovi quelle due variabili
- assegna all'app il ruolo IAM creato da Terraform
- tieni uguali `AWS_REGION`, bucket e model IDs

## Variabili ambiente consigliate per l'app

Un esempio specifico per AWS e in [.env.aws.example](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/.env.aws.example).

## Piano di implementazione software consigliato

### Step 1

Aggiungi un feature flag semplice, ad esempio `AI_PROVIDER=aws|legacy`.

### Step 2

Lascia le route come sono e sostituisci solo l'interno dei moduli AI.

### Step 3

Crea un dataset reale di regressione con output atteso.

### Step 4

Fai shadow mode su alcuni documenti:

- esegui provider legacy e AWS in parallelo
- confronta numero item, campi chiave, prezzi, errori di parsing

### Step 5

Quando il delta e accettabile, switcha la produzione.

## Cosa eviterei adesso

- vector DB
- embeddings per matching
- orchestrazioni a code
- Lambda sparse solo per fare polling
- storage definitivo dei risultati OCR grezzi in database
- migrazione simultanea a App Runner

## Preparazione ad App Runner

Lo stack Terraform crea gia il ruolo IAM che potrai riusare su App Runner. Quando sarai pronto, il passaggio ideale sara:

1. container image dell'app
2. service App Runner
3. instance role = ruolo gia creato
4. env vars non sensibili come oggi
5. secret solo per Supabase/Stripe e altri provider non AWS

Questo ti permette di togliere le credenziali AWS statiche senza riscrivere la logica documentale.
