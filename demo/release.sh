cd /Users/davidebertolo/Documents/Git/T_PREZZO/tprezzo-devops/demo

RELEASE="java-demo-$(date +%Y%m%d-%H%M%S)"

# 1. Recupera configurazione corrente dalla demo
bash java/update-release.sh prepare "$RELEASE"

# 2. Compila frontend, backend e worker dai sorgenti locali
bash java/build-release.sh "$RELEASE"

# 3. Carica e pubblica sul server
bash java/update-release.sh publish "$RELEASE"
