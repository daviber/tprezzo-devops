# Manutenzione disco demo

VPS `188.245.184.80`, audit **11 ottobre 2026**, manutenzione completata
**13 ottobre 2026**.

Il peso principale era la cache di vecchie build Node: 107 record inutilizzati
da 2–3 mesi, 22,13 GB complessivi e 19,83 GB indicati come recuperabili.
Prima della manutenzione root al 83%, 6358 MiB disponibili.
I valori Docker includono layer condivisi: il recupero effettivo si misura con `df`.

## Risultato verificato

- **11 ottobre**: pulizia cache build, recuperati **17.588.568.064 byte
  (16,4 GiB)**; identità dei 12 riferimenti immagine e 9 container invariate.
- **13 ottobre**: compressi `btmp.1` e `auth.log.1`, recuperati
  **166.257.598 byte (158,6 MiB)**. SHA256 del contenuto decompresso uguale
  all'originale prima di rimuovere le copie raw ridondanti.
- Root al **37%**, **24.376.811.520 byte disponibili (22,7 GiB)** al controllo.
  Cache residua 4,353 GB: il limite configurato è un obiettivo subordinato al
  filtro di età e ai riferimenti ancora protetti da Docker.
- Stesso hash delle identità immagini/container prima e dopo manutenzione;
  5 container Java/frontend/relay attivi e 4 legacy conservati fermi.
- Cron installato il 13 ottobre; eseguito inventario con lo stesso wrapper
  e percorso log del cron. Configurazione logrotate globale validata senza
  forzare rotazioni. Nessun riavvio app o Docker durante l'intervento.

## Politica installata sul VPS

- `/etc/cron.d/tprezzo-build-cache`: domenica **03:40 UTC** (**05:40 in Italia
  con ora legale, 04:40 con ora solare**). Il cron Debian usa
  il fuso del daemon; server verificato `Etc/UTC`. `TZ=UTC` serve ai processi,
  non cambia il calendario del daemon. Rivedere l'orario se cambia fuso VPS.
- Script stabile `/opt/tprezzo-java/maintenance/disk-maintenance.sh`: builder
  Docker locale `default`; solo cache inutilizzata da oltre **168 ore**;
  obiettivo cache **2 GB**. Il filtro temporale prevale: non è un limite rigido
  se molta cache è recente, condivisa o in uso.
- Lock condiviso con deploy `/opt/tprezzo-java/.manage.lock`: salta se occupato.
  Snapshot prima/dopo verifica identità immagini/container e stato running.
  Nessun container viene arrestato o ricreato.
- Log `/var/log/tprezzo-demo-maintenance.log`, `0640 root:adm`; logrotate
  settimanale, 8 archivi compressi, rotazione anticipata sopra 1 MiB.
- Journal: cron **già presente**, ogni giorno 03:23 UTC, retention 14 giorni.
- Log container: **già limitati 10 MB × 5 file**; nessuna modifica manuale.
- `btmp`: aggiunto `compress`; frequenza mensile e `rotate 1` invariate.
  Backup regola originale `/var/lib/tprezzo-demo-maintenance/btmp.logrotate.before`.
  Rotazione `auth.log` invariata: settimanale, 4 archivi, `compress delaycompress`.

`compress-archives.py --apply` effettua una sola compressione dei vecchi
`/var/log/btmp.1` e `/var/log/auth.log.1`: stesso lock di logrotate, verifica
assenza writer, gzip conservando sorgente, confronto SHA256 decompressa,
poi rimozione della sola copia raw ridondante. Tutti i contenuti restano nei
file `.gz`, con permessi/proprietario originali. Nessun log attivo modificato.
La compressione periodica successiva è già compito di logrotate.

## Uso

```bash
# Solo inventario:
bash /opt/tprezzo-java/maintenance/disk-maintenance.sh --inspect

# Pulizia mirata cache, stessa operazione del cron:
bash /opt/tprezzo-java/maintenance/disk-maintenance.sh --apply

# Inventario archivi host / prima compressione:
python3 /opt/tprezzo-java/maintenance/compress-archives.py
python3 /opt/tprezzo-java/maintenance/compress-archives.py --apply
```

I comandi richiedono root sul VPS; non eseguono build o test applicativi.
Cache eliminata è rigenerabile: future build potrebbero essere più lente.
Immagini Java/Node, container legacy fermi, volumi, env, certificati,
documenti e DB rimangono conservati. Non usare `docker system prune` per
questa manutenzione: rimuoverebbe anche container fermi utili al rollback.

## Installazione

Caricare questa directory in `/opt/tprezzo-java/maintenance`; verificare
timezone UTC e script `--inspect`. Validare logrotate con `--debug` sul file
globale `/etc/logrotate.conf` e separatamente sulla nuova regola manutenzione.
La regola `btmp` eredita `su` dalla configurazione globale: non validarla
isolatamente. Non forzare la rotazione per verificare la sintassi.
Installare come root:

```bash
touch /var/log/tprezzo-demo-maintenance.log
chown root:adm /var/log/tprezzo-demo-maintenance.log
chmod 0640 /var/log/tprezzo-demo-maintenance.log
install -m 0644 /opt/tprezzo-java/maintenance/tprezzo-demo-maintenance.logrotate /etc/logrotate.d/tprezzo-demo-maintenance
install -m 0644 /opt/tprezzo-java/maintenance/tprezzo-build-cache /etc/cron.d/tprezzo-build-cache
```

Cron rilegge automaticamente `/etc/cron.d`; nessun restart app/Docker.
Per sospendere solo la pulizia cache, spostare il relativo file cron fuori da
`/etc/cron.d`. Le rotazioni log esistenti continuano indipendentemente.

Fonti: [Buildx prune](https://docs.docker.com/reference/cli/docker/buildx/prune/),
[logging Docker](https://docs.docker.com/engine/logging/drivers/json-file/),
[logrotate 3.21](https://github.com/logrotate/logrotate/blob/3.21.0/logrotate.c).
