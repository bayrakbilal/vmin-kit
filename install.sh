#!/usr/bin/env bash
# install.sh - vmin-kit tek giris noktasi.
#   sudo ./install.sh
#
# Amac: bu araci calistiran kisinin kurulum adimlarini HATIRLAMAK zorunda
# kalmamasi. Tek zorunlu soru ana domaindir; gerisi ya varsayilan ya tespit.
#
# Akis:
#   1) Sistem durumu
#   2) Ayarlar    : config.env (depoda, tercihlerin yeri) + ana domaini sor
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
# HAS_* = sistemde ZATEN ne var. Ayar degiskenleriyle (POSTGRES, DOCKER ...)
# karismasin diye ayri onek tasiyorlar.
HAS_VIRTUALMIN=no; if command -v virtualmin >/dev/null 2>&1; then HAS_VIRTUALMIN=yes; fi
HAS_DOCKER=no;     if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAS_DOCKER=yes; fi
HAS_PORTAINER=no;  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx portainer; then HAS_PORTAINER=yes; fi
CUR_HOST="$(hostname -f 2>/dev/null || hostname)"
SRV_IP="$(detect_ip)"

log "Sistem durumu:"
log "  Hostname  : $CUR_HOST"
log "  IP        : ${SRV_IP:-bilinmiyor}"
log "  Virtualmin: $HAS_VIRTUALMIN"
log "  Docker    : $HAS_DOCKER"
log "  Portainer : $HAS_PORTAINER"
echo

[ -n "$SRV_IP" ] || { err "Sunucu IP'si tespit edilemedi. config.env icinde SERVER_IP= verin."; exit 1; }

# ---- 2) ayarlar + ana domain ----
# Ayarlar config.env'den gelir. O dosya DEPODA durur ve tercihlerin yeridir:
# degistir, commit'le; sonraki sunucu ayni sekilde kurulur.
#
# Ana domain orada TUTULMAZ, her calistirmada sorulur - her sunucuda farkli
# olan tek deger odur. Betikten calistirmak icin ortam degiskeni verilebilir:
#   MAIN_DOMAIN=ornek.com ./install.sh
if [ -f "$ROOT_DIR/config.env" ]; then
  # shellcheck source=/dev/null
  source "$ROOT_DIR/config.env"
else
  warn "config.env bulunamadi; her ayar icin varsayilan kullanilacak."
fi

if [ -z "${MAIN_DOMAIN:-}" ]; then
  log "Once sunu dogrulayin: ana domain ve hostname icin A kayitlari"
  log "bu sunucunun IP'sine (${SRV_IP}) isaret etmeli. Kontrol edecegim."
  echo
  while :; do
    MAIN_DOMAIN="$(ask "Ana domain (or: ornek.com)" "")"
    [ -n "$MAIN_DOMAIN" ] && break
    warn "Bos olamaz."
  done
fi

HOST_PREFIX="${HOST_PREFIX:-s}"
HOSTNAME_FQDN="${HOSTNAME_FQDN:-${HOST_PREFIX}.${MAIN_DOMAIN}}"
POSTGRES="${POSTGRES:-1}"
COMPOSER="${COMPOSER:-1}"
NO_ADMIN_REDIRECT="${NO_ADMIN_REDIRECT:-1}"
NO_WEBMAIL_REDIRECT="${NO_WEBMAIL_REDIRECT:-1}"
PANEL_PROXY="${PANEL_PROXY:-1}"
ROUNDCUBE="${ROUNDCUBE:-1}"
LOCK_PANEL_PORTS="${LOCK_PANEL_PORTS:-1}"
# Docker ve Portainer tek bayrak: Portainer, Docker olmadan anlamsiz ve
# Docker'i Portainer'siz kurmak istemedigimiz icin ikisi birlikte gider.
DOCKER="${DOCKER:-1}"

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
NS1="${NS1_PREFIX:-ns1}.${MAIN_DOMAIN}"
NS2="${NS2_PREFIX:-ns2}.${MAIN_DOMAIN}"

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
if [ "$HAS_VIRTUALMIN" = yes ]; then log "  - Virtualmin  : kurulu (atlanacak)"; else log "  - Virtualmin  : KURULACAK"; fi
if is_truthy "$POSTGRES"; then
  if command -v psql >/dev/null 2>&1; then log "  - PostgreSQL  : kurulu (atlanacak)"
  else                                     log "  - PostgreSQL  : KURULACAK"; fi
fi
if is_truthy "$COMPOSER"; then
  if command -v composer >/dev/null 2>&1; then log "  - Composer    : kurulu (atlanacak)"
  else                                         log "  - Composer    : KURULACAK"; fi
fi
log "  - DNS sablonu : NS1=${NS1}  NS2=${NS2}   (bu sunucunun NS cifti)"
log "  - Ana domain  : $MAIN_DOMAIN  (Virtualmin varsayilan ozellikleriyle)"
log "  - SSL         : $MAIN_DOMAIN icin Lets Encrypt"
if is_truthy "$NO_ADMIN_REDIRECT"; then
  log "  - admin.<domain> -> panel yonlendirmesi: KAPATILACAK"
fi
if is_truthy "$NO_WEBMAIL_REDIRECT"; then
  log "  - webmail.<domain> -> Usermin yonlendirmesi: KAPATILACAK"
fi
if is_truthy "$PANEL_PROXY"; then
  log "  - ${WEBMIN_PREFIX:-webmin}.${MAIN_DOMAIN} -> Webmin (vekil)"
  log "  - ${USERMIN_PREFIX:-usermin}.${MAIN_DOMAIN} -> Usermin (vekil)"
  is_truthy "$LOCK_PANEL_PORTS" &&
    log "  - Yonetim portlari (10000/20000) yalnizca 127.0.0.1'e baglanacak"
fi
if is_truthy "$ROUNDCUBE"; then
  log "  - ${WEBMAIL_PREFIX:-webmail}.${MAIN_DOMAIN} -> Roundcube"
fi
log "  - Eklentiler  :$(plugin_list_enabled)"

if is_truthy "$DOCKER"; then
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
# Ozet her zaman gosterilir ve onay her zaman istenir: yanlis bir ayar
# gorursen iptal edip config.env'i duzeltir, yeniden calistirirsin.
if ! ask_yn "Bu ayarlarla devam edeyim mi?" E; then
  warn "Iptal edildi. Ayarlar burada: $ROOT_DIR/config.env"
  exit 0
fi

# ---- ADIMLAR: SIRA BURADA, ACIKCA ----
#
# Burada set -e KAPALI. Her adim kendi hatasini kendisi bildirip 'return 1'
# ile cikiyor; bir adimin basarisiz olmasi geri kalanini iptal etmemeli.
# set -e acik kalsaydi ilk basarisiz adim tum kurulumu oldururdu - "atlaniyor"
# yazip duruyordu. Yukaridaki hazirlik ve dogrulama bolumu set -e ile korunmaya
# devam ediyor, orada durmak DOGRU davranis.
set +e
echo
step_hostname
step_virtualmin
if is_truthy "$POSTGRES"; then step_postgres; fi
if is_truthy "$COMPOSER"; then step_composer; fi
step_dns_template
step_panel_redirects
# Eklentiler domainlerden ONCE: boylece domain olusturulurken ozellikleri
# secilebilir hale geliyor. Virtualmin kurulu oldugu icin BIND de kurulu,
# senkron servisinin izleyecegi zone dizini bu asamada mevcut.
step_plugins
step_main_domain
step_host_dns
step_ssl
if is_truthy "$PANEL_PROXY"; then step_panel_sites; fi
if is_truthy "$ROUNDCUBE"; then step_webmail; fi
if is_truthy "$DOCKER"; then
  step_docker
  step_portainer
  step_docker_site
fi
# Kilitleme EN SON: once vekillerin calistigi dogrulanir, dogrulanamazsa
# port kapatilmaz. Yanlis sirada yapilirsa panele erisim kaybedilir.
if is_truthy "$PANEL_PROXY" && is_truthy "$LOCK_PANEL_PORTS"; then
  step_lock_panel_ports
fi
step_report
set -e

echo
ok "Tamamlandi."
if is_truthy "$PANEL_PROXY"; then
  log "Panel : https://${WEBMIN_PREFIX:-webmin}.${MAIN_DOMAIN}/"
else
  log "Panel : https://${HOSTNAME_FQDN}:10000"
fi
log "Site  : https://${MAIN_DOMAIN}"
log "Rapor : $VMINKIT_REPORT"

# Token EN SON uretilir: omru birkac dakika oldugu icin araya baska adimlar
# girse bile ekranda gorunen degerin taze olmasi gerekiyor.
if is_truthy "$DOCKER"; then step_portainer_token; fi
