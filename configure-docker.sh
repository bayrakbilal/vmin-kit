#!/usr/bin/env bash
# configure-docker.sh - Portainer kurulum ekranini yeniden acar.
#   sudo ./configure-docker.sh
#
# Portainer, konteyner ayaga kalktiktan birkac dakika icinde yonetici hesabi
# olusturulmazsa guvenlik geregi kurulumu kilitler ("the Portainer instance
# timed out for security purposes"). Kilidi acmanin yolu konteyneri yeniden
# baslatmaktir; her baslangicta YENI bir setup_token uretilir.
#
# Alt domain ve proxy kurulumda olusturuldugu icin burada tekrar olusturulmaz.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/steps.sh"
require_root

command -v docker >/dev/null 2>&1 || { err "Docker kurulu degil."; exit 1; }
docker ps -a --format '{{.Names}}' | grep -qx portainer || {
  err "'portainer' konteyneri yok. Once: sudo ./install.sh"
  exit 1
}

# Ana domain sistem hostname'inden gelir (kurulum onu HOST_PREFIX.MAIN_DOMAIN
# yapiyor). config.env yalnizca onek ve Portainer ayarlari icin okunur.
if [ -f "$ROOT_DIR/config.env" ]; then
  # shellcheck source=/dev/null
  source "$ROOT_DIR/config.env"
fi
if [ -z "${MAIN_DOMAIN:-}" ]; then
  H="$(hostname -f 2>/dev/null || hostname)"
  MAIN_DOMAIN="${H#*.}"
fi
SITE="${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}"

if portainer_configured; then
  ok "Portainer'da yonetici hesabi zaten olusturulmus - token gerekmiyor."
  log "Adres: https://${SITE}/"
  exit 0
fi

log "Portainer yeniden baslatiliyor (yeni setup_token uretilecek)..."
TOKEN="$(portainer_restart_for_token || true)"

echo
if [ -n "$TOKEN" ]; then
  ok "Portainer hazir. Kurulumu SIMDI tamamlayin - token kisa omurludur."
  echo
  echo "    Adres       : https://${SITE}/"
  echo "    setup_token : $TOKEN"
  echo
  log "Sureyi kacirirsaniz bu script'i tekrar calistirin."
else
  warn "setup_token loglarda bulunamadi."
  warn "Adrese bakin: https://${SITE}/"
  warn "Loglari elle incelemek icin: docker logs portainer"
fi
