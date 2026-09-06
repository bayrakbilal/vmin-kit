#!/usr/bin/env bash
# install-plugins.sh - vmin-kit Webmin modullerini kurar/gunceller.
#   sudo ./install-plugins.sh          # kopyalayarak kurar (normal kullanim)
#   sudo ./install-plugins.sh --dev    # symlink kurar (gelistirme)
#   sudo ./install-plugins.sh --remove # kaldirir
#
# NE ZAMAN CALISTIRMAK GEREKIR?
#   Webmin her istegi taze bir Perl process'inde calistirir; derleme yoktur.
#   Bu yuzden .cgi / *.pl / lang duzenlemeleri icin HICBIR SEY gerekmez,
#   tarayicida sayfayi yenilemek yeterlidir. Bu script yalnizca:
#     - ilk kurulumda
#     - module.info degistiginde (onbellek yalnizca /usr/share/webmin
#       dizininin mtime'ina bakiyor, icindeki dosyaya degil)
#     - modul eklenip cikarildiginda
#   gerekir. --dev modunda symlink kuruldugu icin 'git pull' sonrasi bu
#   script'i tekrar calistirmaya da gerek kalmaz.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
require_root

MODE=copy
case "${1:-}" in
  --dev)    MODE=link ;;
  --remove) MODE=remove ;;
  "")       ;;
  *) err "Bilinmeyen secenek: $1"; exit 1 ;;
esac

# Webmin kok dizini (Debian'da /usr/share/webmin)
WEBMIN_ROOT="$(awk -F= '/^root=/{print $2; exit}' /etc/webmin/miniserv.conf 2>/dev/null || true)"
WEBMIN_ROOT="${WEBMIN_ROOT:-/usr/share/webmin}"
[ -d "$WEBMIN_ROOT" ] || { err "Webmin bulunamadi: $WEBMIN_ROOT"; exit 1; }

VS_CONFIG="/etc/webmin/virtual-server/config"
[ -f "$VS_CONFIG" ] || { err "Virtualmin yapilandirmasi yok: $VS_CONFIG"; exit 1; }

MODULES=()
for dir in "$ROOT_DIR"/plugin/*/; do
  [ -f "${dir}module.info" ] || continue
  MODULES+=("$(basename "$dir")")
done
[ ${#MODULES[@]} -gt 0 ] || { err "plugin/ altinda modul bulunamadi."; exit 1; }

# webmin.acl: root'un erisebildigi moduller listesi. Modul burada yoksa
# panelde hic gorunmez.
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
# bosluklarla ayrilmis 'plugins=' satiri.
plugins_add(){
  local mod="$1" cur
  cur="$(awk -F= '/^plugins=/{sub(/^plugins=/,""); print; exit}' "$VS_CONFIG" || true)"
  case " $cur " in *" $mod "*) return 0 ;; esac
  set_kv "$VS_CONFIG" plugins "$(echo "$cur $mod" | xargs)"
  log "  Virtualmin plugin listesine eklendi: $mod"
}

plugins_remove(){
  local mod="$1" cur new
  cur="$(awk -F= '/^plugins=/{sub(/^plugins=/,""); print; exit}' "$VS_CONFIG" || true)"
  new="$(echo "$cur" | tr ' ' '\n' | grep -vxF "$mod" | xargs || true)"
  set_kv "$VS_CONFIG" plugins "$new"
}

for mod in "${MODULES[@]}"; do
  src="$ROOT_DIR/plugin/$mod"
  dst="$WEBMIN_ROOT/$mod"

  if [ "$MODE" = remove ]; then
    log "Kaldiriliyor: $mod"
    rm -rf "$dst"
    plugins_remove "$mod"
    acl_revoke "$mod"
    continue
  fi

  log "Kuruluyor: $mod"
  # Onceki kurulum ne olursa olsun (dizin ya da symlink) temizle.
  rm -rf "$dst"
  if [ "$MODE" = link ]; then
    ln -s "$src" "$dst"
    log "  symlink: $dst -> $src"
  else
    cp -a "$src" "$dst"
  fi
  chmod 0755 "$dst"/*.cgi 2>/dev/null || true
  chmod 0755 "$dst"/*.pl  2>/dev/null || true

  # Modulun kendi yapilandirma dizini; config dosyasi yoksa varsayilani koy.
  install -d -m 0755 "/etc/webmin/$mod"
  if [ ! -f "/etc/webmin/$mod/config" ] && [ -f "$src/config" ]; then
    cp "$src/config" "/etc/webmin/$mod/config"
    chmod 0600 "/etc/webmin/$mod/config"
  fi

  acl_grant "$mod"
  plugins_add "$mod"
done

# module.info onbellegi: yalnizca /usr/share/webmin dizininin mtime'ina
# bakildigi icin icerik degisikliklerinde kendiliginden tazelenmiyor.
rm -f /etc/webmin/module.infos.cache /var/webmin/module.infos.cache

log "Webmin yeniden baslatiliyor..."
systemctl restart webmin

echo
if [ "$MODE" = remove ]; then
  ok "Moduller kaldirildi: ${MODULES[*]}"
else
  ok "Moduller kuruldu: ${MODULES[*]}"
  log "Panelde:"
  log "  Git Deploy  -> Edit Virtual Server'da ozelligi acin, sonra domain menusunde 'Git Deploy'"
  log "  Cloudflare  -> System Settings -> Cloudflare DNS Sync"
  if [ "$MODE" = link ]; then
    echo
    log "Gelistirme modu: kod degisiklikleri icin 'git pull' + sayfa yenileme yeterli."
    log "module.info degisirse bu script'i tekrar calistirin."
  fi
fi
