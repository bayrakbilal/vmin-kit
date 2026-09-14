#!/usr/bin/env bash
# build-plugins.sh - packages the Webmin modules as .wbm.gz.
#   ./build-plugins.sh                 # all of them
#   ./build-plugins.sh vmkit-deploy    # just one
#
# Output: dist/<module>.wbm.gz  (dist/ is gitignored)
#
# Packages are never committed and are always built from source, so a package
# can never be stale. install.sh runs this before installing.
#
# Format: Webmin expects a <module>/ directory with module.info at the archive
# root. Compression is gzip, which Webmin detects from the first two bytes
# rather than from the file name.
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
[ ${#MODULES[@]} -gt 0 ] || { err "No modules found under plugin/."; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for mod in "${MODULES[@]}"; do
  src="$ROOT_DIR/plugin/$mod"
  [ -f "$src/module.info" ] || { err "$mod: no module.info, skipping."; continue; }

  rm -rf "${STAGE:?}/$mod"
  cp -a "$src" "$STAGE/$mod"

  # Permissions are fixed in the package, because a git working copy does not
  # always carry the execute bit (notably when edited on Windows).
  #
  # Executable: every CGI, and .pl files that START WITH A SHEBANG. The second
  # rule matters - sync-all.pl and hook-run.pl are commands that systemd and
  # the web hook run directly. When only *.cgi was made 0755 they shipped as
  # 0644 and the Cloudflare timer died with "Permission denied" on a clean
  # install, while update-plugins.sh hid it because cp -a preserves modes.
  # Library .pl files have no shebang and stay 0644.
  find "$STAGE/$mod" -type d -exec chmod 0755 {} +
  find "$STAGE/$mod" -type f -exec chmod 0644 {} +
  chmod 0755 "$STAGE/$mod"/*.cgi 2>/dev/null || true
  for f in "$STAGE/$mod"/*.pl; do
    [ -f "$f" ] || continue
    case "$(head -c 2 "$f")" in "#!") chmod 0755 "$f" ;; esac
  done

  out="$DIST/$mod.wbm.gz"
  tar -czf "$out" -C "$STAGE" "$mod"
  ok "$(basename "$out")  ($(du -h "$out" | cut -f1 | tr -d ' '))"
done
