#!/usr/bin/env bash
# renew-ssl.sh - hostname sanal sunucusu icin Lets Encrypt sertifikasi al/yenile.
#   sudo ./renew-ssl.sh            -> hostname'i sistemden alir
#   sudo ./renew-ssl.sh s.ornek.com
#
# Ne zaman lazim:
#   Kurulum sirasinda domain henuz cozumlemiyorsa (ornegin NS'ler bu sunucuya
#   delege edilmeden once) Virtualmin sertifika alamaz ve self-signed ile devam
#   eder. DNS oturduktan sonra bu script gercek sertifikayi aldirir.
#
# Ana domain icin ayri bir sey gerekmez: ./install.sh tekrar calistirildiginda
# sertifikasi olmayan ana domain icin zaten istekte bulunur.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
require_root

command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin kurulu degil."; exit 1; }

# ---- hangi hostname ----
# Parametre verilmediyse sistemin kendi hostname'i. Kurulum hostname'i zaten
# HOST_PREFIX.MAIN_DOMAIN olarak ayarliyor, dolayisiyla dogru ad burasi.
HOST="${1:-}"
[ -n "$HOST" ] || HOST="$(hostname -f 2>/dev/null || hostname)"

log "Hedef: $HOST"

# ---- Virtualmin sanal sunucusu mu ----
if ! virtualmin list-domains --name-only 2>/dev/null | grep -qxF "$HOST"; then
  err "$HOST bir Virtualmin sanal sunucusu degil."
  err "Mevcut sunucular:"
  virtualmin list-domains --name-only 2>/dev/null | sed 's/^/    /'
  exit 1
fi

# ---- DNS gercekten bu sunucuya mi geliyor ----
if ! is_truthy "${SKIP_DNS_CHECK:-0}"; then
  ensure_pkg dig bind9-dnsutils dnsutils || { err "dig kurulamadi."; exit 1; }
  SRV_IP="$(detect_ip)"
  mapfile -t IPS < <(resolve_a "$HOST")
  log "$HOST -> ${IPS[*]:-(cozumlemiyor)}   (sunucu: ${SRV_IP:-?})"
  if [ ${#IPS[@]} -eq 0 ] || ! ip_in_list "$SRV_IP" "${IPS[@]}"; then
    err "$HOST bu sunucuya cozumlemiyor; Lets Encrypt dogrulamasi basarisiz olur."
    err "A kaydini $SRV_IP yapin ve yayilmasini bekleyin."
    err "Kontrolu atlamak icin: SKIP_DNS_CHECK=1 ./renew-ssl.sh"
    exit 1
  fi
fi

# ---- sertifikayi al / yenile ----
log "Sertifika isteniyor (otomatik yenileme de acilir)..."
if virtualmin generate-letsencrypt-cert --domain "$HOST" --renew; then
  ok "Bitti. Panel: https://${HOST}:10000"
else
  err "Sertifika alinamadi. 80 ve 443 portlarina disaridan erisildigini dogrulayin."
  exit 1
fi
