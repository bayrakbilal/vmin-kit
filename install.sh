#!/usr/bin/env bash
# install.sh - vmin-kit tek giris noktasi.
#   sudo ./install.sh
#
# Amac: bu araci calistiran kisinin kurulum adimlarini HATIRLAMAK zorunda
# kalmamasi. Tek zorunlu soru ana domaindir; gerisi ya varsayilan ya tespit.
#
# Akis:
#   1) Sistem durumu
#   2) Cevaplar   : config.env varsa oku (gozetimsiz), yoksa domaini sor
#   3) DNS kontrol: domain ve hostname bu sunucuya cozumluyor mu + DNS modu
#   4) Ozet + dogrulama (sorun varsa HICBIR SEY calistirilmaz)
#   5) Adimlar    : acik sirayla
#   6) Rapor      : ne yapildi + ikinci sunucu icin config.env
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/steps.sh"
require_root

echo "==================== vmin-kit ===================="

# ---- 0) isletim sistemi ----
OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then . /etc/os-release; OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"; fi
if [ "$OS_ID" != debian ] || [ "$OS_VER" != 12 ]; then
  if is_truthy "${ALLOW_ANY_OS:-0}"; then
    warn "Debian 12 degil ($OS_ID $OS_VER) - ALLOW_ANY_OS=1 ile devam ediliyor."
  else
    err "Bu arac Debian 12 icin yazildi (bulunan: ${OS_ID:-?} ${OS_VER:-?})."
    err "Yine de denemek icin: ALLOW_ANY_OS=1 ./install.sh"
    exit 1
  fi
fi

# ---- 1) sistem durumu ----
VM=no;        if command -v virtualmin >/dev/null 2>&1; then VM=yes; fi
DOCKER=no;    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then DOCKER=yes; fi
PORTAINER=no; if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx portainer; then PORTAINER=yes; fi
CUR_HOST="$(hostname -f 2>/dev/null || hostname)"
SRV_IP="$(detect_ip)"

log "Sistem durumu:"
log "  Hostname  : $CUR_HOST"
log "  IP        : ${SRV_IP:-bilinmiyor}"
log "  Virtualmin: $VM"
log "  Docker    : $DOCKER"
log "  Portainer : $PORTAINER"
echo

[ -n "$SRV_IP" ] || { err "Sunucu IP'si tespit edilemedi. config.env icinde SERVER_IP= verin."; exit 1; }

# ---- 2) cevaplar ----
if [ -f "$ROOT_DIR/config.env" ]; then
  MODE=config
  # shellcheck source=/dev/null
  source "$ROOT_DIR/config.env"
  log "config.env bulundu -> gozetimsiz mod."
else
  MODE=interactive
  log "Once sunu dogrulayin: ana domain ve hostname icin A kayitlari"
  log "bu sunucunun IP'sine (${SRV_IP}) isaret etmeli. Kontrol edecegim."
  echo
  while :; do
    MAIN_DOMAIN="$(ask "Ana domain (or: ornek.com)" "")"
    [ -n "$MAIN_DOMAIN" ] && break
    warn "Bos olamaz."
  done
fi

MAIN_DOMAIN="${MAIN_DOMAIN:-}"
[ -n "$MAIN_DOMAIN" ] || { err "MAIN_DOMAIN bos (zorunlu)."; exit 1; }
HOST_PREFIX="${HOST_PREFIX:-s}"
HOSTNAME_FQDN="${HOSTNAME_FQDN:-${HOST_PREFIX}.${MAIN_DOMAIN}}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
POSTGRES="${POSTGRES:-1}"
# Docker ve Portainer tek bayrak: Portainer, Docker olmadan anlamsiz ve
# Docker'i Portainer'siz kurmak istemedigimiz icin ikisi birlikte gider.
docker="${docker:-1}"
portainer="$docker"

# ---- 3) DNS kontrolu + mod tespiti ----
ensure_pkg dig bind9-dnsutils dnsutils || { err "dig kurulamadi (bind9-dnsutils)."; exit 1; }

log "DNS kontrol ediliyor (disaridan bakan resolver: $DNS_RESOLVER)"
mapfile -t MAIN_IPS < <(resolve_a "$MAIN_DOMAIN")
mapfile -t HOST_IPS < <(resolve_a "$HOSTNAME_FQDN")
mapfile -t NS_NAMES < <(resolve_ns "$MAIN_DOMAIN")

log "  $MAIN_DOMAIN -> ${MAIN_IPS[*]:-(cozumlemiyor)}"
log "  $HOSTNAME_FQDN -> ${HOST_IPS[*]:-(cozumlemiyor)}"
log "  NS: ${NS_NAMES[*]:-(yok)}"

DNS_MODE=bilinmiyor
if [ ${#NS_NAMES[@]} -gt 0 ]; then
  DNS_MODE=harici
  for n in "${NS_NAMES[@]}"; do
    while read -r nip; do
      [ -n "$nip" ] || continue
      if [ "$nip" = "$SRV_IP" ]; then DNS_MODE=bind; fi
    done < <(resolve_a "$n")
  done
fi

# NS1/NS2 her zaman bu sunucunun kendi nameserver ciftidir - DNS modundan
# bagimsiz. Yerel BIND zone'u "NS yonetimi bizde" modeline gore uretilir;
# Cloudflare senkronunda NS/SOA kayitlari gonderilmez, geri kalan her sey
# aynen gider. Boylece iki mod arasinda tek fark delegasyonun nerede oldugudur.
NS1="${NS1:-ns1.${MAIN_DOMAIN}}"
NS2="${NS2:-ns2.${MAIN_DOMAIN}}"

# Gercekte otoriter olan sunucular - sadece bilgi ve rapor icin.
AUTH_NS="${NS_NAMES[*]:-bilinmiyor}"

case "$DNS_MODE" in
  bind)    log "  Mod: BIND - NS kayitlari bu sunucuyu gosteriyor (sunucu otoriter)." ;;
  harici)  log "  Mod: HARICI DNS - otoriter: $AUTH_NS" ;;
  *)       warn "  Mod: belirlenemedi (NS kaydi okunamadi)." ;;
esac
echo

# ---- 4) ozet ----
log "Yapilacaklar:"
log "  - Hostname    : $HOSTNAME_FQDN"
if [ "$VM" = yes ]; then log "  - Virtualmin  : kurulu (atlanacak)"; else log "  - Virtualmin  : KURULACAK"; fi
if is_truthy "$POSTGRES"; then log "  - PostgreSQL  : kurulacak (Virtualmin sonrasi, ayri adim)"; fi
log "  - DNS sablonu : NS1=${NS1}  NS2=${NS2}   (bu sunucunun NS cifti)"
log "  - Ana domain  : $MAIN_DOMAIN  (web + SSL + DNS; mail ve veritabani KAPALI)"
log "  - SSL         : $MAIN_DOMAIN icin Lets Encrypt"
if is_truthy "$docker"; then
  log "  - Docker + Portainer"
  log "  - ${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN} -> Portainer proxy"
fi
echo

# ---- dogrulama ----
errors=()
case "$MAIN_DOMAIN" in
  *.*) ;;
  *) errors+=("MAIN_DOMAIN gecerli bir domain degil: $MAIN_DOMAIN");;
esac
if ! is_truthy "${SKIP_DNS_CHECK:-0}"; then
  if [ ${#MAIN_IPS[@]} -eq 0 ] || ! ip_in_list "$SRV_IP" "${MAIN_IPS[@]}"; then
    errors+=("$MAIN_DOMAIN -> ${MAIN_IPS[*]:-cozumlemiyor} ; beklenen: $SRV_IP  (A kaydini duzeltin)")
  fi
  if [ ${#HOST_IPS[@]} -eq 0 ] || ! ip_in_list "$SRV_IP" "${HOST_IPS[@]}"; then
    errors+=("$HOSTNAME_FQDN -> ${HOST_IPS[*]:-cozumlemiyor} ; beklenen: $SRV_IP  (A kaydini ekleyin)")
  fi
fi

if [ ${#errors[@]} -gt 0 ]; then
  err "Sorunlar var - HICBIR SEY calistirilmadi:"
  for e in "${errors[@]}"; do err "  ! $e"; done
  echo
  err "DNS icin: saglayicinizda su iki A kaydi $SRV_IP adresini gostermeli:"
  err "    $MAIN_DOMAIN      A   $SRV_IP"
  err "    $HOSTNAME_FQDN    A   $SRV_IP"
  err "Cloudflare kullaniyorsaniz kurulum sirasinda proxy KAPALI (gri bulut) olsun."
  err "Yayilmayi bekleyip tekrar calistirin. Kontrolu atlamak icin: SKIP_DNS_CHECK=1 ./install.sh"
  exit 1
fi

# ---- onay ----
if [ "$MODE" = interactive ]; then
  if ! ask_yn "Baslayalim mi?" E; then warn "Iptal edildi."; exit 0; fi
fi

# ---- ADIMLAR: SIRA BURADA, ACIKCA ----
echo
step_hostname
step_virtualmin
if is_truthy "$POSTGRES"; then step_postgres; fi
step_dns_template
step_main_domain
step_host_dns
step_ssl
if is_truthy "$docker"; then
  step_docker
  step_portainer
  step_docker_site
fi
step_report

echo
ok "Tamamlandi."
log "Panel : https://${HOSTNAME_FQDN}:10000"
log "Site  : https://${MAIN_DOMAIN}"
if is_truthy "$docker"; then
  log "Portainer : https://${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}/"
  tok="$(portainer_setup_token || true)"
  if [ -n "$tok" ]; then
    log "  setup_token: $tok"
    log "  (kisa omurlu; suresi dolduysa: sudo ./configure-docker.sh)"
  else
    warn "  setup_token okunamadi -> sudo ./configure-docker.sh"
  fi
fi
log "Rapor : $VMINKIT_REPORT"
