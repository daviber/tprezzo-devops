# Terraform AWS - Textract + Bedrock

Stack Terraform minimale per la fase 1 della migrazione.

## Cosa crea

- 1 bucket S3 per documenti temporanei Textract
- 1 bucket S3 per upload price-centric temporanei
- 1 policy IAM condivisa per Bedrock + Textract + bucket dedicati
- 1 utente IAM per la VPS
- 1 ruolo IAM pronto per App Runner

## Cosa non crea volutamente

- access key IAM applicative
- risorse App Runner
- SNS/SQS
- output bucket Textract dedicato
- CloudWatch dashboard o budget avanzati
- policy Organizations di AI opt-out

Queste scelte servono a tenere lo stack semplice e controllabile.

## Worker asincrono price-centric

Il worker Docker usa le risorse Terraform AWS:

- resta sullo stesso VPS dell'app;
- usa queue PostgreSQL, non SQS;
- legge upload dal bucket price-centric temporaneo;
- usa bucket Textract, policy IAM e modelli Bedrock creati da questo stack;
- usa stessa access key VPS dell'app;
- puo essere replicato senza creare nuovi utenti IAM.

Con piu worker, verificare quote Textract/Bedrock prima di aumentare concorrenza.
I lifecycle configurati da Terraform puliscono upload price-centric e oggetti
Textract temporanei rimasti dopo crash del worker.

Dettaglio:

- `docs/PRICE_CENTRIC_ASYNC_IMPLEMENTATION_CHECKLIST.md`
- `devops/aws/PRICE_CENTRIC_TUNING_RUNBOOK.md`

## Security-first prima dell'apply

Prima di eseguire questo stack:

1. attiva MFA sul root
2. lavora con un profilo admin non-root
3. allega una AI services opt-out policy all'organizzazione
4. lascia disabilitato Bedrock invocation logging

Per l'opt-out trovi un file pronto qui:

- [devops/aws/ai-services-opt-out-all.json](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/ai-services-opt-out-all.json)

## Prerequisiti

- AWS CLI configurata con un profilo admin non-root
- Bedrock Anthropic FTU completato a mano in console
- Terraform installato localmente

## Uso

```bash
cd devops/aws/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

## Variabili principali

- `aws_region`: consigliata `eu-central-1`
- `aws_profile`: profilo AWS CLI locale usato da Terraform
- `project_name`: default `tprezzo`
- `environment`: ad esempio `prod` o `staging`
- `textract_documents_expiration_days`: default `7`
- `textract_bucket_force_destroy`: default `false` (mettilo `true` solo per cleanup/migrazioni)
- `price_centric_documents_expiration_days`: default `7`
- `price_centric_bucket_force_destroy`: default `false`
- `create_vps_app_user`: se `false`, crea solo il ruolo per App Runner

## Dopo l'apply

Prendi i valori dagli output e poi:

1. crea manualmente una access key per l'utente VPS
2. configura app/worker con entrambi i bucket, regione e model ids
3. non salvare mai la secret key nello state Terraform

Mappatura output/env:

- `textract_bucket_name` -> `AWS_TEXTRACT_BUCKET`;
- `price_centric_bucket_name` -> `PRICE_CENTRIC_S3_BUCKET`;
- prefix applicativo default: `PRICE_CENTRIC_S3_PREFIX=price-centric/uploads`.

## Migrazione completa da `eu-south-1` a `eu-central-1`

Se hai gia applicato lo stack in `eu-south-1`, fai una migrazione pulita:

1. metti in `terraform.tfvars`:
   - `aws_region = "eu-south-1"`
   - `textract_bucket_force_destroy = true`
2. esegui:
   - `terraform destroy`
3. cambia `terraform.tfvars` a:
   - `aws_region = "eu-central-1"`
   - `textract_bucket_force_destroy = false`
4. esegui:
   - `terraform apply`
5. ricrea la access key dell'utente IAM VPS e aggiorna `.env` sulla VPS.

## App Runner piu avanti

Il ruolo `app_runner_document_ai_role_arn` e gia pronto per essere assegnato come instance role di App Runner.
