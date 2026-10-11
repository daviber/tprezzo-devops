> **Documento storico del monolite Node.** Nel branch `codex/frontend-java-backend` consultare il [piano corrente](../../docs/migration/PIANO_PULIZIA_FRONTEND_BACKEND_JAVA.md). Sorgenti/API/worker e comandi qui descritti possono essere ritirati. Non usare questo documento per avviare consumer Node, applicare SQL o configurare segreti nel frontend. Contenuto storico conservato.

# Price-centric async - AWS e tuning

Baseline verificata il `2026-07-02`, dopo pulizia sicura della cache build e dei
journal archiviati.

## Architettura operativa

- queue e stato job: PostgreSQL/Supabase;
- nessuna SQS;
- app e worker sullo stesso VPS;
- app e worker usano stessa configurazione AWS e stessa policy IAM;
- upload price-centric: bucket S3 temporaneo dedicato;
- input tecnico Textract: bucket S3 temporaneo separato;
- `PRICE_CENTRIC_INSTANCE_ID` separa installazioni, queue e prefissi S3;
- notifiche push restano fuori scope.

## Risorse AWS verificate

Account: `549136075610`. Regione: `eu-central-1`.

Bucket price-centric:

- `tprezzo-prod-549136075610-eu-central-1-price-centric`;
- blocco accesso pubblico completo;
- cifratura server-side `AES256`;
- versioning abilitato;
- oggetti correnti eliminati dopo 7 giorni;
- versioni non correnti eliminate dopo 1 giorno;
- upload multipart incompleti eliminati dopo 1 giorno.

Bucket Textract:

- `tprezzo-prod-549136075610-eu-central-1-textract`;
- oggetti correnti eliminati dopo 7 giorni;
- versioni non correnti eliminate dopo 1 giorno;
- upload multipart incompleti eliminati dopo 1 giorno.

Entrambe le lifecycle sono abilitate e gestite da Terraform. Non modificare bucket,
lifecycle o IAM manualmente.

## IAM app e worker

Policy live:

```text
arn:aws:iam::549136075610:policy/tprezzo-prod-document-ai
versione default: v2
```

La policy consente:

- API sincrone e asincrone Textract usate dall'app;
- `Converse`, `ConverseStream`, `InvokeModel` e
  `InvokeModelWithResponseStream` Bedrock;
- list/location sui due bucket;
- get/put/delete/abort multipart sugli oggetti dei due bucket.

La stessa policy e' allegata a:

- utente VPS `tprezzo-prod-vps-app`;
- ruolo futuro `tprezzo-prod-app-runner-document-ai`.

Sul VPS usare `AWS_CREDENTIALS_MODE=static`. Per un futuro runtime AWS:

1. impostare `AWS_CREDENTIALS_MODE=instance-role`;
2. rimuovere `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`;
3. assegnare il ruolo IAM al runtime;
4. mantenere regione, bucket e model ID invariati.

## Quote account rilevate

Valori letti da Service Quotas in `eu-central-1`.

### Textract

| Operazione | Quota |
|---|---:|
| `AnalyzeDocument` | 1 TPS |
| `AnalyzeExpense` | 1 TPS |
| `StartDocumentAnalysis` | 5 TPS |
| `GetDocumentAnalysis` | 5 TPS |
| `StartExpenseAnalysis` | 1 TPS |
| `GetExpenseAnalysis` | 5 TPS |
| job async `DocumentAnalysis` concorrenti | 100 |
| job async `ExpenseAnalysis` concorrenti | 100 |
| job async `DocumentTextDetection` concorrenti | 100 |

### Bedrock

Quote cross-region esposte per i modelli configurati:

| Modello | RPM | TPM |
|---|---:|---:|
| Claude Sonnet 4.5 V1 | 10.000 | 5.000.000 |
| Claude Haiku 4.5 | 10.000 | 5.000.000 |

Le quote sono limiti account/regione, non obiettivi applicativi. Capacita reale,
token per documento e throttling vanno misurati con documenti reali. Le quote
possono cambiare: rileggere Service Quotas prima di aumentare parallelismo.

Riferimenti AWS:

- https://docs.aws.amazon.com/general/latest/gr/textract.html
- https://docs.aws.amazon.com/textract/latest/dg/limits-quotas-explained.html
- https://docs.aws.amazon.com/general/latest/gr/bedrock.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-runtime.html

## Retry AWS

Configurazione iniziale:

```dotenv
AWS_RETRY_MODE=standard
AWS_MAX_ATTEMPTS=3
```

I client AWS SDK JavaScript v3 ereditano queste variabili. `standard` usa backoff
esponenziale con jitter per errori transitori e throttling. Sono tre tentativi
totali: richiesta iniziale e massimo due retry.

Questo retry e' distinto dal retry job:

```dotenv
PRICE_CENTRIC_WORKER_MAX_ATTEMPTS=3
PRICE_CENTRIC_WORKER_BACKOFF_BASE_SECONDS=5
```

Riferimento:

- https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html

## Configurazione iniziale

```dotenv
PRICE_CENTRIC_WORKER_REPLICAS=1
PRICE_CENTRIC_WORKER_CONCURRENCY=1
AWS_BEDROCK_PAGE_CONCURRENCY=2
AWS_BEDROCK_GLOBAL_CONCURRENCY=2
PRICE_CENTRIC_WORKER_JOB_TIMEOUT_SECONDS=300
PRICE_CENTRIC_WORKER_LEASE_SECONDS=600
```

Capacita massima applicativa:

```text
job simultanei =
  PRICE_CENTRIC_WORKER_REPLICAS
  * PRICE_CENTRIC_WORKER_CONCURRENCY

call Bedrock potenziali =
  min(
    AWS_BEDROCK_GLOBAL_CONCURRENCY,
    job simultanei * AWS_BEDROCK_PAGE_CONCURRENCY
  )
```

Con i valori iniziali:

```text
job simultanei = 1
call Bedrock simultanee massime = 2
```

La concorrenza pagine non crea altri job Textract. Con la configurazione iniziale un
container gestisce un solo job e fino a due pagine Bedrock simultanee.

## Baseline VPS

Misura read-only del `2026-07-02`:

```text
CPU: 4 vCPU
RAM: 7,6 GiB totali, 6,8 GiB disponibili
swap: assente
load average: 0,00 / 0,00 / 0,00
app: circa 241 MiB
nginx: circa 13 MiB
stripe-cli: circa 40 MiB
worker async: circa 21 MiB con `1 x 1`
disco root post-rollout: 38 GiB, 31 GiB liberi, 16% usato
image Docker: circa 2,4 GiB; image inutilizzate conservate per certbot/rollback
build cache: 0 B
journal systemd: circa 336 MiB
```

RAM, CPU e disco consentono il punto di partenza `1 x 1`. Sono stati rimossi solo i
21,56 GiB di cache build inutilizzata; container e image sono stati conservati. Gli
script non eseguono prune automatico.

Retention host:

- cron giornaliero `/etc/cron.d/tprezzo-log-retention`: journal archiviati 14 giorni;
- `logrotate.timer`: attivo;
- log Docker nel Compose: `json-file`, massimo `10 MB x 5 file` per container,
  effettivo alla successiva creazione/ricreazione dei container.

## Monitoraggio collaudo

VPS:

```bash
free -h
df -h /
docker stats --no-stream
docker system df
docker compose -p tprezzo-demo -f /opt/tprezzo/devops/docker-compose.demo.yml ps
docker compose -p tprezzo-demo -f /opt/tprezzo/devops/docker-compose.demo.yml \
  logs --since 30m worker
```

Job completati per minuto:

```sql
SELECT
  date_trunc('minute', completed_at) AS minute,
  count(*) AS completed_jobs
FROM public.price_centric_jobs
WHERE instance_id = 'demo-hetzner-eu1'
  AND status = 'completed'
  AND completed_at >= now() - interval '1 hour'
GROUP BY 1
ORDER BY 1;
```

Durata job:

```sql
SELECT
  count(*) AS jobs,
  round(avg(extract(epoch FROM completed_at - started_at))::numeric, 2) AS avg_s,
  round(percentile_cont(0.50) WITHIN GROUP (
    ORDER BY extract(epoch FROM completed_at - started_at)
  )::numeric, 2) AS p50_s,
  round(percentile_cont(0.95) WITHIN GROUP (
    ORDER BY extract(epoch FROM completed_at - started_at)
  )::numeric, 2) AS p95_s
FROM public.price_centric_jobs
WHERE instance_id = 'demo-hetzner-eu1'
  AND status = 'completed'
  AND started_at IS NOT NULL
  AND completed_at >= now() - interval '24 hours';
```

`price_centric_processing_steps.step_name = 'read_document'` misura oggi il blocco
AWS complessivo Textract + Bedrock. La separazione precisa dei due tempi richiede
telemetria runtime aggiuntiva e va valutata dopo il primo collaudo.

CloudWatch:

- Textract namespace `AWS/Textract`: `ThrottledCount`, `ResponseTime`,
  `ServerErrorCount`, `UserErrorCount`;
- Bedrock runtime: `InvocationThrottles`, `InvocationLatency`,
  `InputTokenCount`, `OutputTokenCount`, `EstimatedTPMQuotaUsage`.

`EstimatedTPMQuotaUsage` e' indicativo e non deve essere l'unica base per capacity
planning.

Riferimenti:

- https://docs.aws.amazon.com/textract/latest/dg/cloudwatch-metricsdim.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-runtime-metrics.html

## Regola di tuning

1. partire con `replicas=1`, `concurrency=1`, `page concurrency=2`;
2. collaudare almeno 10 documenti rappresentativi, uno alla volta;
3. registrare job/minuto, p50/p95, errori, CPU, RAM, disco e throttle;
4. aumentare una sola dimensione;
5. preferire `replicas 1 -> 2` prima di aumentare concorrenza interna;
6. mantenere almeno 2 GiB RAM disponibile e CPU sostenuta sotto il 70%;
7. fermare incremento se appare qualsiasi throttling Textract/Bedrock;
8. dopo ogni modifica ripetere lo stesso dataset.

Non aumentare contemporaneamente repliche, concorrenza worker e concorrenza pagine.
