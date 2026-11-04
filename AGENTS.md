# Istruzioni operative progetto

- Usa sempre `/caveman ultra`; dichiaralo a inizio chat.
- Non eseguire build npm; test npm a cura del proprietario.

## Database: esecuzione esclusivamente manuale del proprietario

- Non eseguire mai operazioni di scrittura su database, in nessun ambiente: locale, test, demo, staging o produzione.
- Il divieto include SQL DML/DDL, migrazioni, seed, bonifiche/backfill, ripristini, RPC/funzioni con effetti collaterali, API REST/SDK e script/comandi eseguiti anche via SSH, container, UI, sottoagenti o automazioni.
- Per modifiche a dati o schema, prepara soltanto SQL revisionabile nei file delle migrazioni del progetto, oppure consegna il SQL. L'esecuzione spetta sempre al proprietario.
- Una richiesta generica di sviluppo, fix, deploy o bonifica, una precedente autorizzazione o la disponibilità di credenziali non autorizzano scritture DB.
- Non avviare test, job o deploy che applichino automaticamente migrazioni, seed o altre scritture su DB. Non aggirare il divieto usando canali o credenziali differenti.
- Sono consentite solo letture sicuramente prive di effetti collaterali. Se una lettura/RPC non è sicuramente innocua, prepara la query per l'esecuzione manuale.
- Non annullare automaticamente scritture già avvenute: anche un rollback dei dati richiede SQL da consegnare al proprietario.
