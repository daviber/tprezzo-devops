# Tprezzo Devops

Repository infrastruttura, separato da `../Tprezzo_replit` (frontend Next.js)
e `../tprezzo-backend` (API e worker Java 25 / Spring Boot).

Deploy Java demo e rollback: [demo/java/README.md](demo/java/README.md).
Stack nuovo: Next SSR + API Java + worker Java + Nginx; DB/coda/provider remoti.

Demo Node esistente conservata in `/opt/tprezzo`, progetto `tprezzo-demo`.
Nuovo stack in `/opt/tprezzo-java/releases/<release-id>`, progetto
`tprezzo-java-demo`. Nessuna sincronizzazione o pulizia del percorso legacy.

`demo/script/`, `docker-compose.demo.yml`, `scripts/`, `sql/` e `aws/`
conservano strumenti storici. I percorsi frontend sono corretti per il repository
separato, ma gli script storici **non eseguono la migrazione Java**.
Non usare `scripts/reset.sh` sulla demo: elimina volumi.

Build/test applicativi restano al proprietario. Il deploy Java usa immagini già
compilate; `demo/java/build-release.sh` è un comando esplicito da eseguire solo
quando si vuole compilare anche il frontend Next.
