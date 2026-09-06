#!/usr/bin/env bash
# configure-docker.sh - Portainer kurulum ekranini yeniden acar.
#   sudo ./configure-docker.sh
#
# Portainer, konteyner ayaga kalktiktan birkac dakika icinde yonetici hesabi
# olusturulmazsa guvenlik geregi kurulumu kilitler ("the Portainer instance
# timed out for security purposes"). Kilidi acmanin yolu konteyneri yeniden
# baslatmaktir; her baslangicta YENI bir setup_token uretilir.
#
# Bu script konteyneri yeniden baslatir, yeni token'i loglardan okur ve
# gidilecek adresle birlikte yazar. Alt domain ve proxy kurulumda zaten
# olusturuldugu icin burada tekrar olusturulmaz.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
require_root

command -v docker >/dev/null 2>&1 || { err "Docker kurulu degil."; exit 1; }
docker ps -a --format '{{.Names}}' | grep -qx portainer || {
  err "'portainer' konteyneri yok. Once: sudo ./install.sh"
  exit 1
}

# Adres: config.env varsa oradan, yoksa sistem hostname'inin ana domaininden.
SITE=""
if [ -f "$ROOT_DIR/config.env" ]; then
  # shellcheck source=/dev/null
  source "$ROOT_DIR/config.env"
  [ -n "${MAIN_DOMAIN:-}" ] && SITE="${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}"
fi
if [ -z "$SITE" ]; then
  H="$(hostname -f 2>/dev/null || hostname)"
  SITE="${DOCKER_PREFIX:-docker}.${H#*.}"
fi

log "Portainer yeniden baslatiliyor (yeni setup_token uretilecek)..."
docker restart portainer >/dev/null

# Token log'a dusene kadar kisa bir sure bekle.
TOKEN=""
for _ in $(seq 1 15); do
  sleep 2
  TOKEN="$(docker logs portainer 2>&1 | grep -oE 'setup_token=[0-9a-f]+' | tail -1 | cut -d= -f2 || true)"
  [ -n "$TOKEN" ] && break
done

echo
if [ -n "$TOKEN" ]; then
  ok "Portainer hazir. Kurulumu SIMDI tamamlayin - token kisa omurludur."
  echo
  echo "  Adres       : https://${SITE}/"
  echo "  setup_token : $TOKEN"
  echo
  log "Sureyi kacirirsaniz bu script'i tekrar calistirin."
else
  warn "setup_token loglarda bulunamadi."
  warn "Yonetici hesabi daha once olusturulmus olabilir - once adrese bakin:"
  warn "  https://${SITE}/"
  warn "Loglari elle incelemek icin: docker logs portainer"
fi
