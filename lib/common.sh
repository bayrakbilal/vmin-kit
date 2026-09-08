#!/usr/bin/env bash
# Ortak yardimcilar.
set -euo pipefail

log(){  printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

require_root(){ [ "$(id -u)" -eq 0 ] || { err "root ile calistirin."; exit 1; }; }

detect_ip(){
  if [ -n "${SERVER_IP:-}" ]; then printf '%s' "$SERVER_IP"; return; fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# key=value satirini config dosyasinda ayarla (varsa degistir, yoksa ekle)
#
# Deger sed'e VERILMEZ: sed'in degistirme tarafinda '&' tum eslesmeye
# genisler, '|' de ayraci oldugu icin ifadeyi bitirir. newdom_aliases gibi
# serbest metin degerlerde bu dosyayi sessizce bozardi. awk degeri veri
# olarak tasiyor, hicbir karakteri yorumlamiyor.
#
# Yazma gecici dosyaya yapilip icerik geri kopyalaniyor ('mv' degil): dosyanin
# sahipligi, izinleri ve inode'u korunuyor - /etc/webmin altindakiler 0600.
set_kv(){
  local f="$1" k="$2" v="$3" tmp
  if ! grep -qE "^${k}=" "$f"; then
    printf '%s=%s\n' "$k" "$v" >> "$f"
    return
  fi
  tmp="$(mktemp)"
  # Deger awk'a -v ile DEGIL, ortamdan geciyor: -v atamalarinda awk ters bolu
  # kacislarini yorumluyor ('\1' 0x01 oluyor). ENVIRON'dan okununca deger
  # oldugu gibi geliyor.
  VMKIT_K="$k" VMKIT_V="$v" awk '
    BEGIN { k = ENVIRON["VMKIT_K"]; v = ENVIRON["VMKIT_V"] }
    index($0, k "=") == 1 { print k "=" v; next }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

is_truthy(){ case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|yes|true|on|e|evet) return 0;; *) return 1;; esac; }

# ask "Soru" "varsayilan" -> cevabi yazar (bos girilirse varsayilan)
ask(){
  local q="$1" def="${2:-}" a
  if [ -n "$def" ]; then read -rp "$q [$def]: " a; printf '%s' "${a:-$def}"
  else read -rp "$q: " a; printf '%s' "$a"; fi
}

# ask_yn "Soru" "E"  -> evet ise 0 doner
ask_yn(){
  local q="$1" def="${2:-E}" a
  read -rp "$q [E/h] " a; a="${a:-$def}"
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in e|evet|y|yes) return 0;; *) return 1;; esac
}

# ensure_pkg <komut> <paket> [alternatif-paket...] -> komut yoksa paketi kurar
ensure_pkg(){
  local cmd="$1"; shift
  command -v "$cmd" >/dev/null 2>&1 && return 0
  log "'$cmd' bulunamadi, kuruluyor ($*)..."
  apt-get update -qq >/dev/null 2>&1 || true
  local p
  for p in "$@"; do
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >/dev/null 2>&1 || true
    command -v "$cmd" >/dev/null 2>&1 && return 0
  done
  return 1
}

# --- DNS yardimcilari -------------------------------------------------------
# Disaridan bakan bir resolver kullaniriz: dunyanin gordugu cevap onemli,
# sunucunun kendi /etc/resolv.conf'u degil (ileride BIND yerelde otoriter olabilir).
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"

# resolve_a <isim> -> IPv4 adreslerini satir satir yazar
resolve_a(){
  local n="$1" out
  out="$(dig +short +time=3 +tries=2 A "$n" @"$DNS_RESOLVER" 2>/dev/null || true)"
  [ -n "$out" ] || out="$(dig +short +time=3 +tries=2 A "$n" 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -E '^[0-9]+(\.[0-9]+){3}$' || true
}

# resolve_ns <domain> -> NS isimlerini (sondaki nokta atilmis) satir satir yazar
resolve_ns(){
  local d="$1" out
  out="$(dig +short +time=3 +tries=2 NS "$d" @"$DNS_RESOLVER" 2>/dev/null || true)"
  [ -n "$out" ] || out="$(dig +short +time=3 +tries=2 NS "$d" 2>/dev/null || true)"
  printf '%s\n' "$out" | sed 's/\.$//' | grep -E '[a-zA-Z]' || true
}

# ip_in_list <aranan-ip> <liste...>  -> listede varsa 0
ip_in_list(){
  local want="$1"; shift
  local i; for i in "$@"; do [ "$i" = "$want" ] && return 0; done
  return 1
}

gen_pass(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20
  else
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n' | cut -c1-20
  fi
}

# ---- Webmin / Virtualmin yardimcilari -------------------------------------
# install.sh (step_plugins) ve update-plugins.sh ayni isi yapiyor; tanim tek
# yerde dursun diye burada.

# Webmin kok dizini (Debian'da /usr/share/webmin)
webmin_root(){
  local r
  r="$(awk -F= '/^root=/{print $2; exit}' /etc/webmin/miniserv.conf 2>/dev/null || true)"
  printf '%s' "${r:-/usr/share/webmin}"
}

# webmin.acl: root'un erisebildigi moduller listesi. Modul burada yoksa
# panelde hic gorunmez. (install-module.pl --acl ile bunu kendisi yapar;
# dosyalari elle kopyalayan yol icin gerekli.)
acl_grant(){
  local mod="$1" acl="/etc/webmin/webmin.acl"
  [ -f "$acl" ] || return 0
  [ -f "${acl}.vmin-kit.bak" ] || cp -a "$acl" "${acl}.vmin-kit.bak"
  if awk -v m="$mod" '/^root:/ { for(i=2;i<=NF;i++) if($i==m) found=1 } END { exit !found }' "$acl"; then
    return 0
  fi
  sed -i "s|^root:.*|& ${mod}|" "$acl"
  log "  webmin.acl: root'a $mod erisimi verildi"
}

acl_revoke(){
  local mod="$1" acl="/etc/webmin/webmin.acl"
  [ -f "$acl" ] || return 0
  sed -i "s|^\(root:.*\)\b${mod}\b|\1|" "$acl"
}

# Virtualmin plugin listesi: /etc/webmin/virtual-server/config icinde
# bosluklarla ayrilmis 'plugins=' satiri. Modul kurulu olsa bile bu listede
# degilse Virtualmin onu eklenti olarak gormez - install-module.pl bu adimi
# yapmaz, cunku Virtualmin'e ozgudur. Panelde "Features and Plugins" sayfasinda
# kutuyu tiklemekle ayni sey (save_newfeatures.cgi de bu satiri yaziyor).
#
# BILEREK yazmadigimiz ikinci bir liste var: 'plugins_inactive'. Bir eklenti
# orada DEGILSE varsayilan olarak acik sayiliyor
# (list_available_features: 'default' => !$inactive{$_}). Yeni domainlerde
# eklentilerin acik gelmesini istiyoruz, o yuzden o listeye dokunmuyoruz.
#
# Bunun dogrudan sonucu: ana domain --default-features ile olusturuldugu icin
# (step_main_domain) uc eklenti de onda acik geliyor. Vekil alt sunucularinda
# ise ozellikler tek tek sayildigi icin eklenti acilmiyor - orasi yalnizca bir
# ters vekil, istedigimiz de bu.
plugins_add(){
  local mod="$1" cur cfg=/etc/webmin/virtual-server/config
  [ -f "$cfg" ] || return 1
  cur="$(awk -F= '/^plugins=/{sub(/^plugins=/,""); print; exit}' "$cfg" || true)"
  case " $cur " in *" $mod "*) return 0 ;; esac
  set_kv "$cfg" plugins "$(echo "$cur $mod" | xargs)"
  log "  Virtualmin plugin listesine eklendi: $mod"
}

plugins_remove(){
  local mod="$1" cur new cfg=/etc/webmin/virtual-server/config
  [ -f "$cfg" ] || return 1
  cur="$(awk -F= '/^plugins=/{sub(/^plugins=/,""); print; exit}' "$cfg" || true)"
  new="$(echo "$cur" | tr ' ' '\n' | grep -vxF "$mod" | xargs || true)"
  set_kv "$cfg" plugins "$new"
}

# Domain menusu baglantilari domain basina onbellekleniyor ve yalnizca domain
# kaydedilince tazeleniyor. Modul degisikliginden sonra temizlemezsek yeni
# etiketler/ikonlar panelde gorunmez.
clear_links_cache(){
  perl -e '
    my ($root) = @ARGV;
    $ENV{WEBMIN_CONFIG} ||= "/etc/webmin"; $ENV{WEBMIN_VAR} ||= "/var/webmin";
    push(@INC, $root); $main::no_acl_check++;
    chdir("$root/virtual-server");
    $0 = "$root/virtual-server/clear.pl";
    require "./virtual-server-lib.pl";
    &clear_links_cache();
  ' "$(webmin_root)" 2>/dev/null
}
