#!/usr/bin/env bash
# Shared helpers.
set -euo pipefail

# ---------------------------------------------------------------------------
# SCREEN AND LOG
#
# fd 3 is the user-visible channel. It is opened here, before install.sh
# redirects stdout/stderr to the log file, so our own lines stay on screen
# while command output goes to the log. In doctor.sh and update-plugins.sh
# nothing is redirected, so fd 3 is just the terminal.
exec 3>&1

# When set, a plain (uncoloured) copy of our lines is appended here.
VMINKIT_LOGFILE="${VMINKIT_LOGFILE:-}"

# _say <colour> <tag> <text...>
# Text is passed to printf as an ARGUMENT, never as the format string: a '%'
# or a backslash in the text would otherwise be interpreted.
_say(){
  local color="$1" tag="$2"; shift 2
  printf '\033[1;%sm%s\033[0m %s\n' "$color" "$tag" "$*" >&3
  if [ -n "$VMINKIT_LOGFILE" ]; then
    printf '%s %s\n' "$tag" "$*" >> "$VMINKIT_LOGFILE"
  fi
  # Explicit: under 'set -e' the last command's status becomes the function's,
  # and the 'if' above returns 1 when no log file is set.
  return 0
}

# Untagged plain line. Do not use bare 'echo': install.sh sends stdout to the
# log file, so it would not appear on screen.
say(){
  printf '%s\n' "$*" >&3
  if [ -n "$VMINKIT_LOGFILE" ]; then printf '%s\n' "$*" >> "$VMINKIT_LOGFILE"; fi
  return 0
}

log(){  _say 34 '[*]' "$@"; }
ok(){   _say 32 '[+]' "$@"; }
warn(){ _say 33 '[!]' "$@"; }
err(){  _say 31 '[x]' "$@"; }

# run_visible <command...>
# For long commands whose output must also stay on screen (the Virtualmin
# installer): minutes of silence look like a hang.
#
# 'tee' is deliberately not used. Given /dev/fd/3 it opens a second descriptor,
# and when fd 3 points at a real file (./install.sh > screen.log) the two
# descriptors write from independent offsets: plain tee truncates and leaves
# NUL holes, 'tee -a' gets overwritten by the shell's own offset. Both were
# measured. The read loop has a single descriptor.
#
# Line-based reading would hold back progress output that redraws with '\r',
# but the Virtualmin installer emits no carriage returns at all (checked).
#
# '|| rc=$?' is required: under 'set -e' with pipefail a failing command would
# kill the script before its status could be read. The status is the COMMAND's.
run_visible(){
  local rc=0
  if is_truthy "${VMINKIT_VERBOSE:-0}"; then
    "$@" || rc=$?
    return "$rc"
  fi
  {
    "$@" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line" >&3   # screen
      printf '%s\n' "$line"       # log (stdout is already the log file)
    done
    rc="${PIPESTATUS[0]}"
  } || rc=$?
  return "$rc"
}

require_root(){ [ "$(id -u)" -eq 0 ] || { err "Run as root."; exit 1; }; }

detect_ip(){
  if [ -n "${SERVER_IP:-}" ]; then printf '%s' "$SERVER_IP"; return; fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# Set key=value in a config file (replace if present, append if not).
#
# The value never reaches sed: on sed's replacement side '&' expands to the
# whole match and '|' ends the expression, which would silently corrupt
# free-text values such as newdom_aliases. awk carries it as data.
#
# awk reads the value from ENVIRON, not -v: -v assignments interpret backslash
# escapes ('\1' becomes 0x01).
#
# Written through a temp file and copied back rather than moved, so ownership,
# permissions and inode survive - files under /etc/webmin are 0600.
set_kv(){
  local f="$1" k="$2" v="$3" tmp
  if ! grep -qE "^${k}=" "$f"; then
    printf '%s=%s\n' "$k" "$v" >> "$f"
    return
  fi
  tmp="$(mktemp)"
  VMKIT_K="$k" VMKIT_V="$v" awk '
    BEGIN { k = ENVIRON["VMKIT_K"]; v = ENVIRON["VMKIT_V"] }
    index($0, k "=") == 1 { print k "=" v; next }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# get_kv <file> <key> -> the value of the first "key=value" line, or nothing.
# Everything after the first '=' is the value: Webmin lists (plugins=,
# referers=) are space-separated and never contain '='.
get_kv(){
  local f="$1" k="$2"
  [ -f "$f" ] || return 0
  VMKIT_K="$k" awk '
    BEGIN { k = ENVIRON["VMKIT_K"] "=" }
    index($0, k) == 1 { print substr($0, length(k) + 1); exit }
  ' "$f"
}

is_truthy(){ case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|yes|true|on) return 0;; *) return 1;; esac; }

# ask "Question" "default" -> prints the answer (default when input is empty)
#
# The prompt goes to fd 3, not through 'read -p': bash writes -p prompts to
# stderr, which install.sh redirects to the log, so the question would never
# appear and the run would look frozen.
ask(){
  local q="$1" def="${2:-}" a
  if [ -n "$def" ]; then
    printf '%s [%s]: ' "$q" "$def" >&3
    read -r a
    printf '%s' "${a:-$def}"
  else
    printf '%s: ' "$q" >&3
    read -r a
    printf '%s' "$a"
  fi
}

# ask_yn "Question" "Y" -> 0 on yes. Prompt goes to fd 3, see ask().
ask_yn(){
  local q="$1" def="${2:-Y}" a
  printf '%s [Y/n] ' "$q" >&3
  read -r a; a="${a:-$def}"
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in y|yes) return 0;; *) return 1;; esac
}

# ensure_pkg <command> <package> [alternative...] -> install if the command is missing
ensure_pkg(){
  local cmd="$1"; shift
  command -v "$cmd" >/dev/null 2>&1 && return 0
  log "'$cmd' not found, installing ($*)..."
  apt-get update -qq >/dev/null 2>&1 || true
  local p
  for p in "$@"; do
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >/dev/null 2>&1 || true
    command -v "$cmd" >/dev/null 2>&1 && return 0
  done
  return 1
}

# --- DNS helpers ------------------------------------------------------------
# Queries go through an external resolver on purpose: what matters is the
# answer the world gets, not the server's own /etc/resolv.conf.
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"

# resolve_a <name> -> one IPv4 address per line
resolve_a(){
  local n="$1" out
  out="$(dig +short +time=3 +tries=2 A "$n" @"$DNS_RESOLVER" 2>/dev/null || true)"
  [ -n "$out" ] || out="$(dig +short +time=3 +tries=2 A "$n" 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -E '^[0-9]+(\.[0-9]+){3}$' || true
}

# resolve_ns <domain> -> one NS name per line, trailing dot removed
resolve_ns(){
  local d="$1" out
  out="$(dig +short +time=3 +tries=2 NS "$d" @"$DNS_RESOLVER" 2>/dev/null || true)"
  [ -n "$out" ] || out="$(dig +short +time=3 +tries=2 NS "$d" 2>/dev/null || true)"
  printf '%s\n' "$out" | sed 's/\.$//' | grep -E '[a-zA-Z]' || true
}

# ip_in_list <wanted> <list...> -> 0 when present
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

# ---- Webmin / Virtualmin helpers -------------------------------------------
# Shared by install.sh (step_plugins) and update-plugins.sh.

# Webmin root directory (/usr/share/webmin on Debian)
webmin_root(){
  local r
  r="$(get_kv /etc/webmin/miniserv.conf root)"
  printf '%s' "${r:-/usr/share/webmin}"
}

# webmin.acl lists the modules root may open; a module missing from it is
# invisible in the panel. install-module.pl does this itself with --acl, so
# this is only for the path that copies files by hand.
acl_grant(){
  local mod="$1" acl="/etc/webmin/webmin.acl"
  [ -f "$acl" ] || return 0
  [ -f "${acl}.vmin-kit.bak" ] || cp -a "$acl" "${acl}.vmin-kit.bak"
  if awk -v m="$mod" '/^root:/ { for(i=2;i<=NF;i++) if($i==m) found=1 } END { exit !found }' "$acl"; then
    return 0
  fi
  sed -i "s|^root:.*|& ${mod}|" "$acl"
  log "  webmin.acl: granted root access to $mod"
}

acl_revoke(){
  local mod="$1" acl="/etc/webmin/webmin.acl"
  [ -f "$acl" ] || return 0
  sed -i "s|^\(root:.*\)\b${mod}\b|\1|" "$acl"
}

# Virtualmin's 'plugins=' line in virtual-server/config. An installed module
# that is missing from it is not treated as a plugin at all. install-module.pl
# does not do this - it is Virtualmin-specific - so we do, which is exactly
# what ticking the box on Features and Plugins does.
#
# 'plugins_inactive' is deliberately left alone: a plugin absent from THAT
# list is pre-ticked for new virtual servers, which is what we want.
plugins_add(){
  local mod="$1" cur cfg=/etc/webmin/virtual-server/config
  [ -f "$cfg" ] || return 1
  cur="$(get_kv "$cfg" plugins)"
  case " $cur " in *" $mod "*) return 0 ;; esac
  set_kv "$cfg" plugins "$(echo "$cur $mod" | xargs)"
  log "  added to the Virtualmin plugin list: $mod"
}

plugins_remove(){
  local mod="$1" cur new cfg=/etc/webmin/virtual-server/config
  [ -f "$cfg" ] || return 1
  cur="$(get_kv "$cfg" plugins)"
  new="$(echo "$cur" | tr ' ' '\n' | grep -vxF "$mod" | xargs || true)"
  set_kv "$cfg" plugins "$new"
}

# Per-domain menu links are cached on disk and only refreshed when a domain is
# saved, so new labels and icons stay invisible until the cache is cleared.
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
