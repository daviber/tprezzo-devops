# Revisione IAM — 14 ottobre 2026

Nessuna policy applicata ad AWS. Il candidato `autopilot-candidate-2026-10-14.json`
è evidenza del generatore AWS Labs 0.3.0, **non una policy da distribuire**:
include permessi condizionali eccessivi (`iam:PassRole`, ACL/retention S3,
guardrail/tool/bearer token) non richiesti dalla configurazione corrente.
Non è stato copiato nella policy applicativa.

La policy Terraform esistente mantiene le azioni di inferenza, elimina le
azioni IAM inesistenti `bedrock:Converse`/`bedrock:ConverseStream` e richiede
`bedrock_inference_resource_arns`: elenco non vuoto di ARN esatti, senza
wildcard. La [API Converse ufficiale](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html)
richiede `bedrock:InvokeModel`. Gli altri permessi S3 erano già limitati ai due
bucket applicativi. Textract mantiene Resource `*` per le API senza scoping
su risorsa; non si devono inventare ARN Textract incompatibili.

Prima del prossimo plan/apply:

1. Controllare `AWS_BEDROCK_PRIMARY_MODEL_ID` e `AWS_BEDROCK_FALLBACK_MODEL_ID`
   nel backend privato, senza incollare altri valori env.
2. Per foundation model diretti, usare l'ARN ufficiale del modello nella regione.
3. Per ciascun inference profile, eseguire il comando di sola lettura:

   ```bash
   aws bedrock get-inference-profile \
     --region eu-central-1 \
     --inference-profile-identifier '<ID effettivamente configurato>' \
     --query '{profile:inferenceProfileArn,models:models[].modelArn}'
   ```

4. Inserire profile ARN e tutti i modelArn restituiti in
   `bedrock_inference_resource_arns` nel proprio `terraform.tfvars` ignorato.
   Non indovinare account o regioni di destinazione cross-region.
5. Eseguire `terraform plan -out=security.tfplan`, leggere la differenza IAM,
   poi applicare esclusivamente il piano verificato. Non eseguito da Codex.
6. Verificare sul deploy entrambe le invocazioni primary/fallback. Un elenco
   incompleto deve negare l'accesso, non ripristinare `Resource = "*"`.

Rigenerazione riproducibile del candidato dal workspace (analisi locale;
nessun `--upload-policies`):

```bash
cd /Users/davidebertolo/Documents/Git/T_PREZZO
DISABLE_IAM_POLICY_AUTOPILOT_TELEMETRY=true uvx iam-policy-autopilot@0.3.0 generate-policies \
  "$PWD/tprezzo-backend/modules/application/src/main/java/it/tprezzo/pricecentric/adapter/out/bedrock/AwsBedrockPriceCentricStructuredOutputExtractor.java" \
  "$PWD/tprezzo-backend/modules/application/src/main/java/it/tprezzo/pricecentric/adapter/out/textract/AwsTextractPriceCentricPdfTextExtractor.java" \
  "$PWD/tprezzo-backend/modules/application/src/main/java/it/tprezzo/pricecentric/adapter/out/textract/AwsTextractPriceCentricImageTextExtractor.java" \
  "$PWD/tprezzo-backend/modules/application/src/main/java/it/tprezzo/pricecentric/adapter/out/s3/AwsS3PriceCentricDocumentStorage.java" \
  --region eu-central-1 --service-hints bedrock textract s3 --pretty
```

L'analisi statica fornisce una baseline da revisionare; non dimostra che ogni
permesso generato sia necessario. Non usare automaticamente il suo output.
