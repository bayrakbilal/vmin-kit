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
set_kv(){
  local f="$1" k="$2" v="$3"
  if grep -qE "^${k}=" "$f"; then sed -i "s|^${k}=.*|${k}=${v}|" "$f"; else printf '%s=%s\n' "$k" "$v" >> "$f"; fi
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
