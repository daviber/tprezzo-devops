# AWS bootstrap operativo step-by-step per Tprezzo

Questo documento e una checklist operativa precisa per portare un account AWS appena creato a uno stato pronto per usare:

- Amazon Textract
- Amazon Bedrock
- Terraform
- VPS esterna ad AWS in fase 1
- App Runner in fase 2

Obiettivo pratico: arrivare a un account AWS sicuro e pronto ad agganciare l'applicazione senza fare cose inutili o troppo complesse.

## Risultato finale atteso

Alla fine di questa procedura avrai:

- root user messo in sicurezza e non usato operativamente
- un accesso amministrativo normale via IAM Identity Center
- una AWS Organization attiva con tutte le feature
- una policy di AI opt-out applicata all'organizzazione
- Bedrock pronto con Anthropic FTU completato
- model invocation logging di Bedrock lasciato disabilitato
- stack Terraform applicato per bucket S3 + IAM + ruolo App Runner
- credenziali IAM create solo per la VPS
- base pronta per integrare il codice applicativo

## Standard che useremo

Per evitare ambiguita, in questo documento assumo:

- regione principale: `eu-central-1`
- account AWS nuovo e vuoto
- nessun uso operativo del root user dopo il bootstrap
- approccio security-first: i documenti non devono finire in training/service improvement

## Regole da non violare

1. non creare access key per il root user
2. non usare il root user per Terraform, CLI o lavoro quotidiano
3. non abilitare Bedrock invocation logging se non hai un requisito preciso
4. non salvare access key applicative nel Terraform state
5. non mettere dati sensibili in tag, nomi risorsa o campi free-form

## Fase 0 - Prima verifica dopo la creazione account

### 0.1 Accedi come root una sola volta

1. Vai su [AWS Console](https://console.aws.amazon.com/)
2. Scegli `Root user`
3. Inserisci email dell'account
4. Inserisci password

Esito atteso:

- entri nella console come proprietario account

### 0.2 Verifica metodo di pagamento e contatti principali

Questo e importante per Bedrock, che richiede un metodo di pagamento valido per AWS Marketplace.

1. Apri `Billing and Cost Management`
2. Vai su `Account`
3. Verifica che il metodo di pagamento sia valido
4. Verifica i dati del contatto principale
5. Se possibile usa una mailbox aziendale o una lista distribuzione, non una mail personale

Esito atteso:

- metodo di pagamento valido
- contatto principale sotto controllo aziendale

## Fase 1 - Metti in sicurezza il root user

Fonte AWS principale:

- [Root user best practices for your AWS account](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)

### 1.1 Cambia subito la mentalita sul root

Il root user va tenuto solo per:

- recovery estremo
- gestione iniziale account
- operazioni che AWS richiede esplicitamente come root

Non va usato per:

- CLI
- SDK
- Terraform
- deployment
- attività quotidiane

### 1.2 Attiva MFA sul root

AWS richiede MFA sul root; inoltre AWS raccomanda piu dispositivi MFA per resilienza.

1. In alto a destra, clicca sul nome account
2. Apri `Security credentials`
3. Trova la sezione `Multi-factor authentication (MFA)`
4. Clicca `Assign MFA device`
5. Scegli una delle opzioni:
   - preferita: `Passkey or Security Key`
   - alternativa immediata: `Authenticator app`
6. Completa la registrazione

Scelta consigliata:

- almeno 2 dispositivi MFA per il root
- ideale: 2 chiavi hardware FIDO
- minimo accettabile: 1 app TOTP + 1 backup custodito bene

Esito atteso:

- MFA attivo sul root
- se possibile almeno un secondo fattore di backup registrato

### 1.3 Verifica che il root non abbia access key

1. Sempre in `Security credentials`
2. Cerca `Access keys`
3. Verifica che non ci siano chiavi attive
4. Se ci sono, eliminale subito

Esito atteso:

- zero access key sul root

### 1.4 Aggiungi contatti alternativi

Fonti:

- [Update the alternate contacts for your AWS account](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-update-contact-alternate.html)

1. Vai su `Billing and Cost Management`
2. Apri `Account`
3. Vai alla sezione `Alternate contacts`
4. Inserisci almeno:
   - `Billing`
   - `Operations`
   - `Security`
5. Usa mailbox di team o alias condivisi, non email personali

Esempio utile:

- billing@azienda.tld
- ops@azienda.tld
- security@azienda.tld

Esito atteso:

- contatti alternativi configurati

### 1.5 Conserva le credenziali root in modo controllato

Best practice pratica:

- password root in password manager aziendale
- MFA backup custodito separatamente
- accesso root con approvazione interna, non individuale e casuale

## Fase 2 - Crea la AWS Organization

Fonte AWS:

- [Creating an organization with AWS Organizations](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_org_create.html)

Perche farlo subito anche se oggi hai un solo account:

- ti serve per la policy di AI opt-out organizzativa
- ti prepara alla crescita futura
- e l'approccio consigliato da AWS per gestione centralizzata

### 2.1 Crea l'organizzazione

Da questo punto in poi non usare piu il root se non strettamente necessario. Se non hai ancora un admin non-root, completa velocemente la Fase 3 e poi torna qui.

Se sei ancora nel primissimo bootstrap, puoi fare questo passaggio con il root, ma solo temporaneamente.

1. Apri `AWS Organizations`
2. Se e la prima volta, clicca `Create organization`
3. Se AWS ti chiede il tipo, scegli `All features`
4. Conferma

Esito atteso:

- l'account attuale diventa `management account`
- l'organizzazione e attiva con `All features`

### 2.2 Verifica l'organizzazione

Console:

1. In `AWS Organizations`, apri `AWS accounts`
2. Verifica che il tuo account compaia come management account

CLI di verifica piu avanti:

```bash
aws organizations describe-organization --profile tprezzo-admin --region eu-central-1
```

## Fase 3 - Crea un accesso amministrativo non-root con IAM Identity Center

Fonti AWS:

- [Enable IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/enable-identity-center.html)
- [Organization instances of IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/organization-instances-identity-center.html)
- [Add users to your Identity Center directory](https://docs.aws.amazon.com/singlesignon/latest/userguide/addusers.html)
- [Create a permission set](https://docs.aws.amazon.com/singlesignon/latest/userguide/howtocreatepermissionset.html)
- [Assign user or group access to AWS accounts](https://docs.aws.amazon.com/singlesignon/latest/userguide/assignusers.html)

### 3.1 Abilita IAM Identity Center

1. Apri `IAM Identity Center`
2. Scegli `Enable`
3. Se AWS ti propone il tipo di istanza, scegli `Organization instance (recommended)`
4. Seleziona come regione di home `eu-central-1` se disponibile nel tuo setup
5. Completa l'attivazione

Esito atteso:

- IAM Identity Center attivo come organization instance

### 3.2 Lascia come identity source quella di default

Per il bootstrap iniziale non complicare le cose con Okta, Entra o directory esterne.

1. In `IAM Identity Center`, apri `Settings`
2. Verifica che l'identity source sia `Identity Center directory`

Esito atteso:

- directory interna pronta per creare l'admin

### 3.3 Crea il tuo utente amministrativo

1. In `IAM Identity Center`, vai su `Users`
2. Clicca `Add user`
3. Inserisci:
   - username: ad esempio `davide.admin`
   - email aziendale sotto controllo tuo
   - nome e cognome
4. Per la password, usa l'invito via email oppure one-time password
5. Salva

Esito atteso:

- utente creato
- hai ricevuto l'invito/access portal URL

### 3.4 Crea un permission set amministrativo

1. In `IAM Identity Center`, vai su `Permission sets`
2. Clicca `Create permission set`
3. Scegli `Predefined permission set` o comunque un set basato su policy AWS managed
4. Usa `AdministratorAccess`
5. Nome consigliato: `AdministratorAccess-Bootstrap`
6. Salva

Esito atteso:

- permission set amministrativo creato

### 3.5 Assegna l'utente al management account

1. In `IAM Identity Center`, vai su `AWS accounts`
2. Seleziona il `management account`
3. Clicca `Assign users or groups`
4. Seleziona il tuo utente admin
5. Seleziona il permission set `AdministratorAccess-Bootstrap`
6. Conferma

Esito atteso:

- il tuo utente admin puo entrare nel management account senza usare root

### 3.6 Fai il primo login come admin non-root

1. Apri l'AWS access portal URL ricevuto da IAM Identity Center
2. Entra con il nuovo utente
3. Apri il tile del management account
4. Apri la console come admin

Esito atteso:

- accesso console riuscito senza root

Da qui in avanti usa questo utente admin, non il root.

## Fase 4 - Configura AWS CLI in SSO sul tuo computer

Fonte AWS:

- [Configuring IAM Identity Center authentication with the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)

### 4.1 Installa o aggiorna AWS CLI v2

Verifica:

```bash
aws --version
```

Se non hai AWS CLI v2, installala prima di proseguire.

### 4.2 Crea il profilo SSO

Esegui:

```bash
aws configure sso
```

Valori consigliati:

- `SSO session name`: `tprezzo-sso`
- `SSO start URL`: quello del tuo AWS access portal
- `SSO region`: la regione dove hai abilitato IAM Identity Center
- `Profile name`: `tprezzo-admin`

Poi fai login:

```bash
aws sso login --profile tprezzo-admin
```

Verifica:

```bash
aws sts get-caller-identity --profile tprezzo-admin
```

Esito atteso:

- vedi il tuo `Account` a 12 cifre
- non stai usando root

## Fase 5 - Attiva il guardrail privacy: AI services opt-out

Fonti AWS:

- [AI services opt-out policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ai-opt-out.html)
- [Opt out from all supported AWS AI services](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ai-opt-out_all.html)
- [AI services opt-out policy syntax and examples](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ai-opt-out_syntax.html)

Per Tprezzo questo passaggio e fondamentale. Amazon Textract e incluso nella lista dei servizi supportati da questa policy.

### 5.1 Abilita il policy type se necessario

1. Apri `AWS Organizations`
2. Vai nella sezione `Policies`
3. Cerca `AI services opt-out policies`
4. Se il tipo policy non e abilitato, clicca `Enable`

Esito atteso:

- il policy type `AISERVICES_OPT_OUT_POLICY` risulta abilitato sul root dell'organizzazione

### 5.2 Crea la policy di opt-out totale

Puoi farlo da console o incollando il JSON gia presente nel repo.

File da usare:

- [devops/aws/ai-services-opt-out-all.json](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/ai-services-opt-out-all.json)

Passi console:

1. In `AWS Organizations` apri `AI services opt-out policies`
2. Clicca `Create policy`
3. Nome consigliato: `OptOut-All-AI-Services`
4. Descrizione consigliata: `Organization-wide opt-out for AI service improvement`
5. Incolla il contenuto del file JSON
6. Salva

Esito atteso:

- policy creata correttamente

### 5.3 Attacca la policy al root dell'organizzazione

1. Apri la policy appena creata
2. Vai alla tab `Targets`
3. Clicca `Attach`
4. Seleziona il `Root` dell'organizzazione
5. Conferma

Esito atteso:

- la policy risulta attaccata al root
- le member accounts non possono sovrascriverla

### 5.4 Verifica pratica

Controlla che:

- il target sia il `Root`
- la policy sia `Attached`
- la sintassi sia quella di opt-out totale

Se vuoi verificare via CLI piu avanti:

```bash
aws organizations list-policies --filter AISERVICES_OPT_OUT_POLICY --profile tprezzo-admin
```

## Fase 6 - Verifica Bedrock e lascialo in configurazione privacy-safe

Fonti AWS:

- [Access Amazon Bedrock foundation models](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- [Data protection - Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/data-protection.html)
- [Monitor model invocation using CloudWatch Logs and Amazon S3](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html)

Messaggio chiave per te:

- AWS dichiara che Amazon Bedrock non usa prompt e completions per addestrare i modelli AWS e non li distribuisce a terze parti
- il logging di invocation e disabilitato di default
- Anthropic richiede il First Time Use form

### 6.1 Vai nella regione corretta

1. In console imposta regione `eu-central-1`
2. Apri `Amazon Bedrock`

Esito atteso:

- console Bedrock aperta in `eu-central-1`

### 6.2 Controlla che il model invocation logging sia disabilitato

1. In Bedrock, apri `Settings`
2. Cerca `Model invocation logging`
3. Verifica che sia `Disabled`
4. Se per qualsiasi motivo fosse attivo, disabilitalo

Esito atteso:

- invocation logging disabilitato

### 6.3 Completa il First Time Use per Anthropic

Non cercare vecchi menu di "model access" se non li vedi: oggi il modo piu semplice e passare dal catalogo modelli.

1. In Bedrock apri `Model catalog`
2. Cerca `Anthropic`
3. Apri `Claude Sonnet 4.5`
4. Completa il `First Time Use` form richiesto da Anthropic
5. Ripeti per `Claude Haiku 4.5` se vuoi predisporre anche il fallback

Note importanti:

- AWS dice che l'accesso ai foundation models e abilitato di default nelle region commerciali se hai le corrette autorizzazioni Marketplace
- per Anthropic il FTU resta comunque richiesto
- il metodo di pagamento dell'account deve essere valido

Esito atteso:

- FTU Anthropic completato
- modelli pronti all'uso nell'account

### 6.4 Verifica Bedrock via CLI

Per elencare i modelli disponibili in regione:

```bash
aws bedrock list-foundation-models --profile tprezzo-admin --region eu-central-1
```

Se vuoi controllare solo che Bedrock risponda, questo basta. I model ID esatti li leggerai da output o dal catalogo Bedrock al momento dell'integrazione.

## Fase 7 - Verifica Textract nella stessa regione

Fonti AWS:

- [What is Amazon Textract?](https://docs.aws.amazon.com/textract/latest/dg/what-is.html)
- [Set Quotas in Amazon Textract](https://docs.aws.amazon.com/textract/latest/dg/limits-document.html)
- [Lines and Words of Text](https://docs.aws.amazon.com/textract/latest/dg/how-it-works-lines-words.html)
- [Data Protection in Amazon Textract](https://docs.aws.amazon.com/textract/latest/dg/data-protection.html)

Quello che ti interessa sapere per il tuo caso:

- Textract supporta testo stampato e scritto a mano
- supporta JPEG, PNG, PDF, TIFF
- sincrono: fino a 10 MB e PDF/TIFF a 1 pagina
- asincrono: PDF/TIFF fino a 500 MB e 3000 pagine, passando da S3
- per fatture conviene usare `AnalyzeExpense`

### 7.1 Non serve una "attivazione" manuale separata

Per Textract non devi accettare un FTU come per Anthropic. Ti servono solo:

- account attivo
- billing attivo
- permessi IAM corretti
- regione supportata

### 7.2 Conferma il perimetro privacy

Per il tuo requisito:

- la protezione principale contro l'uso dei dati per service improvement lato AI services e la policy di opt-out organizzativa
- Textract e compreso nella lista dei servizi supportati da AI opt-out policy

## Fase 8 - Esegui Terraform per creare l'ambiente minimo runtime

File coinvolti:

- [devops/aws/terraform/README.md](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/terraform/README.md)
- [devops/aws/terraform/main.tf](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/terraform/main.tf)
- [devops/aws/terraform/terraform.tfvars.example](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/terraform/terraform.tfvars.example)

### 8.1 Installa Terraform sul tuo computer

Verifica:

```bash
terraform version
```

Se manca, installalo prima.

### 8.2 Prepara il file tfvars

```bash
cd /Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/terraform
cp terraform.tfvars.example terraform.tfvars
```

Apri `terraform.tfvars` e imposta almeno:

```hcl
aws_region  = "eu-central-1"
aws_profile = "tprezzo-admin"

project_name = "tprezzo"
environment  = "prod"

textract_documents_expiration_days = 7
create_vps_app_user                = true
```

### 8.3 Applica lo stack

```bash
terraform init
terraform plan
terraform apply
```

Esito atteso:

- bucket S3 temporaneo Textract creato
- bucket S3 temporaneo price-centric creato
- policy IAM document-ai creata
- utente IAM per la VPS creato
- ruolo IAM per App Runner creato

### 8.4 Prendi nota degli output

```bash
terraform output
```

Quelli che ti serviranno subito sono:

- `textract_bucket_name`
- `price_centric_bucket_name`
- `vps_app_user_name`
- `app_runner_document_ai_role_arn`

## Fase 9 - Crea manualmente la access key per la VPS

Questo passaggio lo facciamo a mano apposta, per evitare che la secret key finisca nello state Terraform.

### 9.1 Crea la chiave dell'utente VPS

1. Apri `IAM`
2. Vai su `Users`
3. Apri l'utente creato da Terraform, ad esempio `tprezzo-prod-vps-app`
4. Vai su `Security credentials`
5. In `Access keys`, clicca `Create access key`
6. Quando AWS chiede l'uso previsto, scegli `Application running outside AWS`
7. Conferma e salva subito:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

Esito atteso:

- una sola access key attiva per l'utente VPS
- secret key salvata in un posto sicuro

### 9.2 Non creare altre chiavi inutili

Regola pratica:

- una chiave per ambiente va bene all'inizio
- niente chiavi duplicate "di backup" dimenticate in giro


---------------------- SONO ARRIVATO QUA 

## Fase 10 - Configura la VPS per agganciarsi ad AWS

File di riferimento:

- [.env.aws.example](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/.env.aws.example)

### 10.1 Variabili da impostare sulla VPS

Le minime sono:

```env
AI_PROVIDER=aws
AWS_REGION=eu-central-1
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_RETRY_MODE=standard
AWS_MAX_ATTEMPTS=3
AWS_TEXTRACT_BUCKET=...
PRICE_CENTRIC_S3_BUCKET=...
PRICE_CENTRIC_S3_PREFIX=price-centric/uploads
AWS_BEDROCK_PRIMARY_MODEL_ID=...
AWS_BEDROCK_FALLBACK_MODEL_ID=...
AWS_BEDROCK_ENABLE_STRUCTURED_OUTPUT=true
AWS_BEDROCK_GLOBAL_CONCURRENCY=2
AWS_BEDROCK_PAGE_CONCURRENCY=2
AWS_TEXTRACT_POLL_INTERVAL_MS=2000
AWS_TEXTRACT_MAX_WAIT_MS=180000
```

Quote verificate, baseline VPS e tuning:

- [PRICE_CENTRIC_TUNING_RUNBOOK.md](/Users/davidebertolo/Documents/Git/T_PREZZO/Tprezzo_replit/devops/aws/PRICE_CENTRIC_TUNING_RUNBOOK.md)

Nota sui model ID:

- non inserirli a memoria
- prendi gli ID esatti dal Model Catalog Bedrock o da `aws bedrock list-foundation-models`
- i nomi commerciali e i model ID non coincidono sempre perfettamente

### 10.2 Verifica minima da VPS

Dalla VPS, con quelle credenziali:

```bash
aws sts get-caller-identity --region eu-central-1
```

Se vuoi verificare il bucket:

```bash
aws s3 ls s3://NOME_BUCKET --region eu-central-1
```

Esito atteso:

- la VPS parla con AWS correttamente

## Fase 11 - Cosa NON fare adesso

Per la tua fase 1 non serve ancora:

- spostare l'app su App Runner
- creare VPC privata per questa parte
- creare SNS/SQS per Textract
- creare Lambda solo per polling
- attivare Bedrock invocation logging
- mettere documenti permanenti in S3 AWS se oggi l'origine resta Supabase

## Fase 12 - Come userai tutto questo nel codice

Questa parte non crea ancora l'integrazione software, ma definisce il perimetro corretto.

### 12.1 Accordi

Pipeline prevista:

1. app scarica file da Supabase
2. se PDF/foto passa da Textract
3. ricostruisce testo/tabella/layout
4. passa tutto a Bedrock
5. Bedrock restituisce il JSON che oggi il codice si aspetta

### 12.2 Fatture

Pipeline prevista:

1. app scarica file da Supabase
2. per fatture usa Textract `AnalyzeExpense`
3. Bedrock normalizza nel JSON attuale
4. il matching resta invariato

## Fase 13 - Preparazione ad App Runner piu avanti

Fonte AWS:

- [How App Runner works with IAM](https://docs.aws.amazon.com/apprunner/latest/dg/security_iam_service-with-iam.html)
- [Referencing environment variables](https://docs.aws.amazon.com/apprunner/latest/dg/env-variable.html)

Quando passerai ad App Runner:

1. userai il ruolo creato da Terraform come `Instance role`
2. toglierai `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`
3. lascerai in App Runner solo env vars non sensibili e segreti referenziati da Secrets Manager o SSM

Questo e proprio il motivo per cui il Terraform ha gia creato il ruolo `tasks.apprunner.amazonaws.com`.

## Checklist finale di accettazione

Segna come fatto solo se ogni punto e vero.

### Sicurezza account

- root MFA attivo
- root senza access key
- contatti alternativi configurati
- root non usato per lavoro quotidiano

### Accesso amministrativo

- IAM Identity Center attivo
- admin user creato
- login admin funzionante
- `aws sts get-caller-identity --profile tprezzo-admin` funzionante

### Privacy AI

- AWS Organization creata con `All features`
- AI opt-out policy attaccata al root
- Bedrock invocation logging disabilitato
- niente dati sensibili in tag o nomi risorsa

### Servizi AI

- Anthropic FTU completato in Bedrock
- Bedrock risponde in `eu-central-1`
- Textract pronto all'uso in `eu-central-1`

### Runtime fase 1

- Terraform applicato
- bucket Textract creato
- utente IAM VPS creato
- access key VPS creata manualmente
- VPS configurata con env vars corrette

## Riferimenti ufficiali AWS usati per questo documento

- [Root user best practices for your AWS account](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)
- [Enable a virtual MFA device for the root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/enable-virt-mfa-for-root.html)
- [Enable a passkey or security key for the root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/enable-fido-mfa-for-root.html)
- [Creating an organization with AWS Organizations](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_org_create.html)
- [Enable IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/enable-identity-center.html)
- [Add users to your Identity Center directory](https://docs.aws.amazon.com/singlesignon/latest/userguide/addusers.html)
- [Create a permission set](https://docs.aws.amazon.com/singlesignon/latest/userguide/howtocreatepermissionset.html)
- [Assign user or group access to AWS accounts](https://docs.aws.amazon.com/singlesignon/latest/userguide/assignusers.html)
- [Configuring IAM Identity Center authentication with the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)
- [AI services opt-out policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ai-opt-out.html)
- [Opt out from all supported AWS AI services](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ai-opt-out_all.html)
- [AI services opt-out policy syntax and examples](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ai-opt-out_syntax.html)
- [Access Amazon Bedrock foundation models](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- [Data protection - Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/data-protection.html)
- [Monitor model invocation using CloudWatch Logs and Amazon S3](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html)
- [What is Amazon Textract?](https://docs.aws.amazon.com/textract/latest/dg/what-is.html)
- [Set Quotas in Amazon Textract](https://docs.aws.amazon.com/textract/latest/dg/limits-document.html)
- [Lines and Words of Text](https://docs.aws.amazon.com/textract/latest/dg/how-it-works-lines-words.html)
- [Data Protection in Amazon Textract](https://docs.aws.amazon.com/textract/latest/dg/data-protection.html)
- [How App Runner works with IAM](https://docs.aws.amazon.com/apprunner/latest/dg/security_iam_service-with-iam.html)
- [Referencing environment variables](https://docs.aws.amazon.com/apprunner/latest/dg/env-variable.html)
