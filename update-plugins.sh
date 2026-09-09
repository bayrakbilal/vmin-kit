#!/usr/bin/env bash
# update-plugins.sh - GELISTIRME dongusu: plugin/ altindaki modulleri dogrudan
# /usr/share/webmin'e kopyalar.
#   sudo ./update-plugins.sh          # kurar / gunceller
#   sudo ./update-plugins.sh --remove # kaldirir
#
# TEMIZ KURULUMDA BU SCRIPT KULLANILMAZ. install.sh eklentileri .wbm.gz olarak
# paketleyip Webmin'in kendi install-module.pl'i ile kurar (step_plugins).
# Burasi test/gelistirme icin: paketleme adimini atlayip dosyalari dogrudan
# yerine koyar, boylece "duzenle - yenile" dongusu hizli kalir.
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
#
# Modulun postinstall.pl / uninstall.pl kancalari da calistirilir - Webmin
# normalde bunlari kendisi cagirir, bu script o yolu kullanmadigi icin elle
# cagiriyoruz. vmkit-cloudflare kendi systemd birimlerini orada kuruyor.
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

WEBMIN_ROOT="$(webmin_root)"
[ -d "$WEBMIN_ROOT" ] || { err "Webmin bulunamadi: $WEBMIN_ROOT"; exit 1; }
[ -f /etc/webmin/virtual-server/config ] || { err "Virtualmin yapilandirmasi yok."; exit 1; }

NEED_RESTART=0
MODULES=()
for dir in "$ROOT_DIR"/plugin/*/; do
  [ -f "${dir}module.info" ] || continue
  MODULES+=("$(basename "$dir")")
done
[ ${#MODULES[@]} -gt 0 ] || { err "plugin/ altinda modul bulunamadi."; exit 1; }

# Webmin'in modul kurulum kancalari. Normalde install_module.pl bunlari
# cagirir; bu script dosyalari elle kopyaladigi icin ayni isi biz yapiyoruz.
# Modul boylece nasil kurulursa kurulsun (buradan ya da .wbm.gz ile) ayni
# kurulum sonrasi adimlari calistirir.
# merge_config <modulun-config-dosyasi> <kurulu-config-dosyasi>
#
# Webmin'in copyconfig.pl'i ile AYNI davranis: mevcut dosya korunur ama
# modulun getirdigi YENI anahtarlar varsayilanlariyla eklenir.
#
# Eskiden burada yalnizca "dosya yoksa kopyala" vardi. Sonucu suydu: bir
# surumde yeni bir ayar eklendiginde .wbm.gz ile kurulan sunucularda ayar
# varsayilaniyla geliyor, bu betikle guncellenen gelistirme sunucusunda ise
# hic olusmuyordu - ayarlar sayfasi bos gorunuyordu. Gelistirme dongusu
# gercek kurulumdan farkli davranmamali.
merge_config(){
  local src="$1" dst="$2" line k
  [ -f "$src" ] || return 0
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod 0600 "$dst"
    return 0
  fi
  # Mevcut dosya satir sonu ile bitmiyorsa eklenecek ilk satir son satira
  # YAPISIR ve iki ayari birden bozar (olculdu: 'scan_depth=9flags='). Elle
  # duzenlenmis bir dosyada bu gayet mumkun.
  if [ -s "$dst" ] && [ -n "$(tail -c 1 "$dst")" ]; then
    printf '\n' >> "$dst"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"
    [ "$k" = "$line" ] && continue          # '=' yoksa ayar satiri degil
    # Satir basina sabitlenmis arama: 'timeout=' anahtari 'x_timeout=' ile
    # eslesmesin. set_kv ile ayni kalip.
    awk -v k="$k" 'index($0, k "=") == 1 { found = 1 } END { exit !found }' \
      "$dst" || printf '%s\n' "$line" >> "$dst"
  done < "$src"
}

run_module_hook(){
  local mod="$1" file="$2" func="$3"
  [ -f "$WEBMIN_ROOT/$mod/$file" ] || return 0
  perl -e '
    my ($root, $mod, $file, $func) = @ARGV;
    $ENV{WEBMIN_CONFIG} ||= "/etc/webmin"; $ENV{WEBMIN_VAR} ||= "/var/webmin";
    push(@INC, $root, "$root/$mod"); $main::no_acl_check++;
    chdir("$root/$mod");
    # init_config modul adini $0 icindeki dizinden okuyor.
    $0 = "$root/$mod/$file";
    require "./$file";
    &{\&{"main::$func"}}();
  ' "$WEBMIN_ROOT" "$mod" "$file" "$func" || warn "  $mod: $file calistirilamadi"
}

for mod in "${MODULES[@]}"; do
  src="$ROOT_DIR/plugin/$mod"
  dst="$WEBMIN_ROOT/$mod"

  if [ "$MODE" = remove ]; then
    log "Kaldiriliyor: $mod"
    # Once modulun kendi temizligi (systemd birimleri gibi), dosyalar dururken.
    run_module_hook "$mod" uninstall.pl module_uninstall
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
  # 'cp -a' SAHIPLIGI KORUR. Depo root'un degilse (ornegin bir domain
  # klasorune cekilmisse) modul dosyalari o kullanicinin uzerine gecerdi -
  # ve Webmin CGI'leri ROOT olarak calistirdigi icin o kullanici kendi
  # .cgi'sini duzenleyip root olabilirdi. Modul dosyalari her zaman root'un.
  chown -R root:root "$dst"
  # Yalnizca CGI'ler calistirilabilir olmali; *.pl dosyalari kutuphane.
  chmod 0755 "$dst"/*.cgi 2>/dev/null || true

  new_info="$(md5sum < "$dst/module.info")"
  [ "$old_info" = "$new_info" ] || NEED_RESTART=1

  # Modulun kendi yapilandirma dizini ve varsayilan ayarlari.
  install -d -m 0755 "/etc/webmin/$mod"
  merge_config "$src/config" "/etc/webmin/$mod/config"

  acl_grant "$mod"
  plugins_add "$mod"

  # Modulun kendi kurulum sonrasi isi: vmkit-cloudflare burada systemd
  # birimlerini kurup baslatiyor. Zaten kuruluysa hicbir sey yapmaz.
  run_module_hook "$mod" postinstall.pl module_install
done

if clear_links_cache; then
  log "Domain menu onbellegi temizlendi."
else
  warn "Menu onbellegi temizlenemedi; degisiklik gorunmezse domaini kaydedin."
fi

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
  echo
  log "Her ucu de domain basina ozelliktir. Once System Settings -> Features"
  log "and Plugins altindan etkinlestirin, sonra Edit Virtual Server'da ilgili"
  log "domain icin acin. Acildiginda domainin menusunde gorunurler:"
  log "  Git Deploy       - uzak repodan deploy"
  log "  Composer         - composer.json bulunan klasorler icin install/update"
  log "  Cloudflare DNS   - yerel zone'u Cloudflare ile senkronlar"
  if systemctl is-active --quiet vmkit-cloudflare-sync.path 2>/dev/null; then
    log "Otomatik DNS senkronu calisiyor (zone degistiginde tetiklenir)."
  fi
fi
