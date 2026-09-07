#!/usr/bin/env bash
# build-plugins.sh - Webmin modullerini .wbm.gz olarak paketler.
#   ./build-plugins.sh                 # hepsini paketle
#   ./build-plugins.sh vmkit-deploy    # yalnizca birini
#
# Cikti: dist/<modul>.wbm.gz  (dist/ .gitignore'da)
#
# Paketler depoda TUTULMAZ, her zaman kaynaktan uretilir: boylece "paket
# bayatladi, kaynakla ayristi" diye bir sorun olmaz. install.sh de kurulum
# sirasinda once bunu calistirir.
#
# Bicim: Webmin arsivin kokunde <modul>/ dizini ve icinde module.info bekliyor
# (install_webmin_module 'tar tf' ile buna bakiyor). Sikistirma gzip; Webmin
# dosya adina degil, ilk iki bayta bakarak anliyor.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

DIST="$ROOT_DIR/dist"
mkdir -p "$DIST"

MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
  for dir in "$ROOT_DIR"/plugin/*/; do
    [ -f "${dir}module.info" ] || continue
    MODULES+=("$(basename "$dir")")
  done
fi
[ ${#MODULES[@]} -gt 0 ] || { err "plugin/ altinda modul bulunamadi."; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for mod in "${MODULES[@]}"; do
  src="$ROOT_DIR/plugin/$mod"
  [ -f "$src/module.info" ] || { err "$mod: module.info yok, atlaniyor."; continue; }

  rm -rf "${STAGE:?}/$mod"
  cp -a "$src" "$STAGE/$mod"

  # Izinleri pakette sabitliyoruz: git calisma kopyasinda calistirilabilir bit
  # tasinmayabiliyor (ozellikle Windows'ta duzenlenmisse). Yalnizca CGI'ler
  # calistirilabilir olmali; *.pl dosyalari kutuphane.
  find "$STAGE/$mod" -type d -exec chmod 0755 {} +
  find "$STAGE/$mod" -type f -exec chmod 0644 {} +
  chmod 0755 "$STAGE/$mod"/*.cgi 2>/dev/null || true

  out="$DIST/$mod.wbm.gz"
  tar -czf "$out" -C "$STAGE" "$mod"
  ok "$(basename "$out")  ($(du -h "$out" | cut -f1 | tr -d ' '))"
done
