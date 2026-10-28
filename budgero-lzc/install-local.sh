#!/usr/bin/env bash
# Build + install sul PROPRIO box, con la config locale iniettata.
#
# Il manifest nel repo è generico perché va sullo store. Questo script lo
# sovrascrive con i valori di local.env solo nella copia che viene
# pacchettata, senza sporcare il file versionato.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAS="${NAS:-root@192.168.8.115}"
PKG="$(grep '^package:' package.yml | awk '{print $2}')"
VER="$(grep '^version:' package.yml | awk '{print $2}')"
LPK="$PKG-v$VER.lpk"

[ -f local.env ] || { echo "manca local.env (vedi local.env.example)" >&2; exit 2; }
# shellcheck disable=SC1091
. ./local.env

# Il manifest versionato non va toccato: si lavora su una copia e si
# ripristina in ogni caso, anche se il build fallisce.
cp lzc-manifest.yml .lzc-manifest.orig
trap 'mv -f .lzc-manifest.orig lzc-manifest.yml' EXIT

# Delimitatore | e non #: le righe da sostituire contengono un commento
# shell, e con s#...#...# sed muore con "unknown option to `s'".
if [ -n "${EXTRA_WS_ORIGINS:-}" ]; then
  sed -i "s|^\( *\)- WEBSOCKET_ALLOWED_ORIGINS=\(.*\)|\1- WEBSOCKET_ALLOWED_ORIGINS=\2,$EXTRA_WS_ORIGINS|" lzc-manifest.yml
  grep -q "WEBSOCKET_ALLOWED_ORIGINS=.*$EXTRA_WS_ORIGINS" lzc-manifest.yml \
    || { echo "ERRORE: EXTRA_WS_ORIGINS non iniettata" >&2; exit 1; }
fi
if [ -n "${SELF_HOST_PUBLIC_IP:-}" ]; then
  sed -i "s|^\( *\)# - SELF_HOST_PUBLIC_IP=.*|\1- SELF_HOST_PUBLIC_IP=$SELF_HOST_PUBLIC_IP|" lzc-manifest.yml
  grep -qE "^ +- SELF_HOST_PUBLIC_IP=$SELF_HOST_PUBLIC_IP" lzc-manifest.yml \
    || { echo "ERRORE: SELF_HOST_PUBLIC_IP non iniettata (il bank-sync resterebbe spento in silenzio)" >&2; exit 1; }
fi
python3 -c "import yaml,sys; yaml.safe_load(open('lzc-manifest.yml'))" \
  || { echo "ERRORE: manifest non piu YAML valido dopo l'iniezione" >&2; exit 1; }

echo "--- env che verrà pacchettata ---"
sed -n '/environment:/,/^$/p' lzc-manifest.yml | grep -E '^\s+-' || true
echo

rm -f "$PKG"-v*.lpk
lzc-cli project build >/dev/null
[ -f "$LPK" ] || { echo "ERRORE: $LPK non prodotto" >&2; exit 1; }

# Il DB va messo al sicuro PRIMA: la migrazione di budgero v1.19.0 non
# torna indietro se non da un backup del volume.
ssh "$NAS" "/lzcsys/bin/lpk-manager stop $PKG && mkdir -p /lzcsys/var/backups && \
  tar czf /lzcsys/var/backups/budgero-data-\$(date +%Y%m%d-%H%M%S).tar.gz \
  -C /lzcsys/data/appvar/$PKG data && ls -lh /lzcsys/var/backups/ | tail -3"

scp "$LPK" "$NAS:/tmp/"
ssh "$NAS" "/lzcsys/bin/lpk-manager install /tmp/$LPK && /lzcsys/bin/lpk-manager start $PKG"
sleep 18

echo "--- verifica ---"
ssh "$NAS" "lzc-docker inspect ${PKG//./}-budgero-1 --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E 'WEBSOCKET_ALLOWED_ORIGINS|SELF_HOST_PUBLIC_IP'
  lzc-docker exec ${PKG//./}-budgero-1 wget -qO- http://127.0.0.1:3001/api/v1/health; echo"
