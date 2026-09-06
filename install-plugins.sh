#!/usr/bin/env bash
# install-plugins.sh - vmin-kit Webmin modullerini kurar/gunceller.
#   sudo ./install-plugins.sh          # kurar / gunceller
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
#   gerekir. Yine de her 'git pull' sonrasi calistirmak zararsizdir: dosyalar
#   kopyalanir ve Webmin YALNIZCA module.info degistiginde yeniden baslatilir.
#
# Not: moduller kopyalanir, symlink kurulmaz. Symlink kurulsaydi Webmin'in ve
# bu script'in yazdiklari dogrudan git deposunu kirletirdi.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
require_root

MODE=copy
case "${1:-}" in
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

NEED_RESTART=0
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
    NEED_RESTART=1
    continue
  fi

  log "Kuruluyor: $mod"
  # Webmin yeniden baslatmasi yalnizca module.info degistiginde gerekiyor
  # (onbellek /usr/share/webmin dizininin mtime'ina bakiyor, icerige degil).
  old_info=""
  [ -f "$dst/module.info" ] && old_info="$(md5sum < "$dst/module.info")"
  [ -e "$dst" ] || NEED_RESTART=1

  # Onceki kurulum ne olursa olsun (dizin ya da eski symlink) temizle.
  rm -rf "$dst"
  cp -a "$src" "$dst"
  # Yalnizca CGI'ler calistirilabilir olmali; *.pl dosyalari kutuphane.
  chmod 0755 "$dst"/*.cgi 2>/dev/null || true

  new_info="$(md5sum < "$dst/module.info")"
  [ "$old_info" = "$new_info" ] || NEED_RESTART=1

  # Modulun kendi yapilandirma dizini; config dosyasi yoksa varsayilani koy.
  install -d -m 0755 "/etc/webmin/$mod"
  if [ ! -f "/etc/webmin/$mod/config" ] && [ -f "$src/config" ]; then
    cp "$src/config" "/etc/webmin/$mod/config"
    chmod 0600 "/etc/webmin/$mod/config"
  fi

  acl_grant "$mod"
  plugins_add "$mod"
done

if [ "$NEED_RESTART" = 1 ]; then
  # module.info onbellegi: yalnizca /usr/share/webmin dizininin mtime'ina
  # bakildigi icin icerik degisikliklerinde kendiliginden tazelenmiyor.
  rm -f /etc/webmin/module.infos.cache /var/webmin/module.infos.cache
  log "module.info degisti -> Webmin yeniden baslatiliyor..."
  systemctl restart webmin
else
  log "module.info degismedi -> Webmin yeniden baslatilmadi (sayfayi yenilemek yeterli)."
fi

echo
if [ "$MODE" = remove ]; then
  ok "Moduller kaldirildi: ${MODULES[*]}"
else
  ok "Moduller kuruldu: ${MODULES[*]}"
  log "Panelde:"
  log "  Git Deploy  -> Edit Virtual Server'da ozelligi acin, sonra domain menusunde 'Git Deploy'"
  log "  Cloudflare  -> System Settings -> Cloudflare DNS Sync"
fi
