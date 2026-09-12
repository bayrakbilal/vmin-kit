#!/usr/bin/env bash
# update-plugins.sh - the DEVELOPMENT loop: copies the modules under plugin/
# straight into /usr/share/webmin.
#   sudo ./update-plugins.sh          # install / update
#   sudo ./update-plugins.sh --remove # remove
#
# A CLEAN INSTALL DOES NOT USE THIS. install.sh packages the plugins as .wbm.gz
# and installs them with Webmin's own install-module.pl (step_plugins). This is
# for development: it skips the packaging step so the edit-refresh loop is fast.
#
# WHEN IS IT NEEDED?
#   Webmin runs every request in a fresh Perl process; there is no build step,
#   so edits to .cgi / *.pl / lang need NOTHING - just refresh the page. This
#   script is needed only on the first install, when module.info changes (the
#   cache looks at the mtime of /usr/share/webmin, not at the file), and when a
#   module is added or removed. Running it after every 'git pull' is harmless:
#   the files are copied and Webmin is restarted ONLY if module.info changed.
#
# Modules are copied, not symlinked: a symlink would let Webmin's own writes
# land in the git working copy.
#
# The module's postinstall.pl / uninstall.pl hooks are run here too - Webmin
# normally calls them itself, and this script does not go through that path.
# vmkit-cloudflare installs its systemd units in them.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
require_root

MODE=copy
case "${1:-}" in
  --remove) MODE=remove ;;
  "")       ;;
  *) err "Unknown option: $1"; exit 1 ;;
esac

WEBMIN_ROOT="$(webmin_root)"
[ -d "$WEBMIN_ROOT" ] || { err "Webmin not found: $WEBMIN_ROOT"; exit 1; }
[ -f /etc/webmin/virtual-server/config ] || { err "No Virtualmin configuration."; exit 1; }

NEED_RESTART=0
MODULES=()
for dir in "$ROOT_DIR"/plugin/*/; do
  [ -f "${dir}module.info" ] || continue
  MODULES+=("$(basename "$dir")")
done
[ ${#MODULES[@]} -gt 0 ] || { err "No modules found under plugin/."; exit 1; }

# merge_config <module's config file> <installed config file>
#
# The SAME behaviour as Webmin's copyconfig.pl: the existing file is kept, but
# NEW keys the module ships are added with their defaults.
#
# This used to be "copy if absent", and the result was that a setting added in
# a new version arrived with its default on servers installed from .wbm.gz but
# never appeared on a development server updated with this script - the
# settings page looked empty. The development loop must not behave differently
# from a real install.
merge_config(){
  local src="$1" dst="$2" line k
  [ -f "$src" ] || return 0
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod 0600 "$dst"
    return 0
  fi
  # If the existing file does not end with a newline, the first appended line
  # GLUES onto the last one and corrupts two settings at once (measured:
  # 'scan_depth=9flags='). Quite possible in a hand-edited file.
  if [ -s "$dst" ] && [ -n "$(tail -c 1 "$dst")" ]; then
    printf '\n' >> "$dst"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"
    [ "$k" = "$line" ] && continue          # no '=', so not a setting line
    # Anchored at the start of the line so 'timeout=' does not match
    # 'x_timeout='. The same pattern as set_kv.
    awk -v k="$k" 'index($0, k "=") == 1 { found = 1 } END { exit !found }' \
      "$dst" || printf '%s\n' "$line" >> "$dst"
  done < "$src"
}

# Webmin's module install hooks. install-module.pl normally calls them; this
# script copies the files by hand, so it calls them itself and a module runs
# the same post-install steps however it was installed.
run_module_hook(){
  local mod="$1" file="$2" func="$3"
  [ -f "$WEBMIN_ROOT/$mod/$file" ] || return 0
  perl -e '
    my ($root, $mod, $file, $func) = @ARGV;
    $ENV{WEBMIN_CONFIG} ||= "/etc/webmin"; $ENV{WEBMIN_VAR} ||= "/var/webmin";
    push(@INC, $root, "$root/$mod"); $main::no_acl_check++;
    chdir("$root/$mod");
    # init_config reads the module name from the directory in $0.
    $0 = "$root/$mod/$file";
    require "./$file";
    &{\&{"main::$func"}}();
  ' "$WEBMIN_ROOT" "$mod" "$file" "$func" || warn "  $mod: could not run $file"
}

for mod in "${MODULES[@]}"; do
  src="$ROOT_DIR/plugin/$mod"
  dst="$WEBMIN_ROOT/$mod"

  if [ "$MODE" = remove ]; then
    log "Removing: $mod"
    # The module's own cleanup first (systemd units), while its files are there.
    run_module_hook "$mod" uninstall.pl module_uninstall
    rm -rf "$dst"
    plugins_remove "$mod"
    acl_revoke "$mod"
    NEED_RESTART=1
    continue
  fi

  log "Installing: $mod"
  # A Webmin restart is needed only when module.info changed: the cache looks
  # at the mtime of /usr/share/webmin, not at the file contents.
  old_info=""
  [ -f "$dst/module.info" ] && old_info="$(md5sum < "$dst/module.info")"
  [ -e "$dst" ] || NEED_RESTART=1

  # Clear whatever was there before, directory or old symlink.
  rm -rf "$dst"
  cp -a "$src" "$dst"
  # 'cp -a' PRESERVES OWNERSHIP. If the checkout is not root's - say it lives
  # in a domain's home - the module files would belong to that user, and since
  # Webmin runs CGIs as ROOT that user could edit their own .cgi and become
  # root. Module files are always root's.
  chown -R root:root "$dst"
  # Only the CGIs need to be executable; *.pl files are libraries.
  chmod 0755 "$dst"/*.cgi 2>/dev/null || true

  new_info="$(md5sum < "$dst/module.info")"
  [ "$old_info" = "$new_info" ] || NEED_RESTART=1

  # The module's own config directory and default settings.
  install -d -m 0755 "/etc/webmin/$mod"
  merge_config "$src/config" "/etc/webmin/$mod/config"

  acl_grant "$mod"
  plugins_add "$mod"

  # The module's post-install work: vmkit-cloudflare installs and starts its
  # systemd units here. Does nothing when they are already in place.
  run_module_hook "$mod" postinstall.pl module_install
done

if clear_links_cache; then
  log "Domain menu cache cleared."
else
  warn "Could not clear the menu cache; save a domain if changes do not appear."
fi

if [ "$NEED_RESTART" = 1 ]; then
  # The module.info cache is keyed on the mtime of /usr/share/webmin, so it
  # does not refresh itself when only the contents change.
  rm -f /etc/webmin/module.infos.cache /var/webmin/module.infos.cache
  log "module.info changed -> restarting Webmin..."
  systemctl restart webmin
else
  log "module.info unchanged -> Webmin not restarted (refreshing the page is enough)."
fi

echo
if [ "$MODE" = remove ]; then
  ok "Modules removed: ${MODULES[*]}"
else
  ok "Modules installed: ${MODULES[*]}"
  echo
  log "Three are per-domain features. Enable them under System Settings ->"
  log "Features and Plugins, then turn them on for a domain in Edit Virtual"
  log "Server. Once on, they appear in that domain's menu:"
  log "  Git Deploy       - deploy from a remote repository"
  log "  Composer         - install/update for directories with a composer.json"
  log "  Cloudflare DNS   - syncs the local zone to Cloudflare"
  log "The fourth, Check vmin-kit, is a page under System Settings."
  if systemctl is-active --quiet vmkit-cloudflare-sync.path 2>/dev/null; then
    log "Automatic DNS sync is running (triggered when a zone changes)."
  fi
fi
