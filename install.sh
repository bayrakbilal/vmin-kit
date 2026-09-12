#!/usr/bin/env bash
# install.sh - the single entry point of vmin-kit.
#   sudo ./install.sh
#
# The point of the tool is that nobody has to REMEMBER the installation steps.
# The main domain is the only question; everything else is a default or is
# detected.
#
# SCOPE RULE (read before growing this file):
#   Only work that must happen BEFORE THE FIRST DOMAIN or ONCE PER SERVER
#   belongs here. Anything repeated, per-domain or panel-managed is a plugin.
#   Backups, health checks and post-deploy tasks are therefore not here.
#
# Flow:
#   1) System state
#   2) Settings   : config.env (tracked, where preferences live) + ask the domain
#   3) DNS check  : do the domain and hostname resolve here, and in which mode
#   4) Summary and validation (on a problem, NOTHING is run)
#   5) Steps      : in an explicit order
#   6) Report     : what was done
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/steps.sh"
require_root

# ---- install log ----
#
# The log is ALWAYS written, never behind a flag: a record you have to enable
# in advance is the record you do not have when you need it.
#
# The screen carries only our own lines; the output of the commands we run goes
# to the log. Nothing is sent to /dev/null - we made that mistake once with the
# deploy hook and a real error stayed invisible for weeks.
#
# --verbose additionally echoes command output to the screen.
VMINKIT_VERBOSE=0
for a in "$@"; do
  case "$a" in
    -v|--verbose) VMINKIT_VERBOSE=1 ;;
    -h|--help)
      echo "Usage: sudo ./install.sh [--verbose]"
      echo "  --verbose  also print command output on screen (the log is written either way)"
      exit 0 ;;
    *) err "Unknown option: $a"; exit 1 ;;
  esac
done
export VMINKIT_VERBOSE

VMINKIT_LOGFILE="$ROOT_DIR/vmin-kit-install-$(date +%Y%m%d-%H%M%S).log"
: > "$VMINKIT_LOGFILE"
chmod 0600 "$VMINKIT_LOGFILE"

# A run that never reaches the steps - cancelled at a prompt, or stopped by the
# checks - has nothing worth keeping: everything it printed was on screen. The
# flag is raised right before the first step. Ctrl+C is routed through EXIT so
# the same rule applies.
#
# The message comes BEFORE the rm: log() appends a copy of every line to the
# file by path, which would recreate it.
VMINKIT_STEPS_STARTED=0
trap '[ "$VMINKIT_STEPS_STARTED" = 1 ] || { log "No step ran; the log file was removed."; rm -f "$VMINKIT_LOGFILE"; }' EXIT
trap 'exit 130' INT

# From here on stdout/stderr are THE LOG FILE. log/ok/warn/err write to fd 3
# (the real terminal) and leave a plain copy in the log - see lib/common.sh.
#
# With --verbose, 'tee' runs in a process substitution and the last few lines
# may not reach it before the script exits. The log file itself is unaffected.
if is_truthy "$VMINKIT_VERBOSE"; then
  exec > >(tee -a "$VMINKIT_LOGFILE") 2>&1
else
  exec >>"$VMINKIT_LOGFILE" 2>&1
fi

say "==================== vmin-kit ===================="
log "Install log: $VMINKIT_LOGFILE"

# ---- 0) isletim sistemi ----
OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then . /etc/os-release; OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"; fi
# SUPPORTED SYSTEMS
#
# The list matches what Virtualmin's OWN installer supports: "Debian 12 and 13"
# and "Ubuntu 22.04 LTS and 24.04 LTS". Anything else is refused, because on a
# system Virtualmin does not support the install stops halfway and leaves a
# half-configured server behind.
#
# The RHEL family is deliberately out: Virtualmin supports it, but this tool is
# built on apt/dpkg. Claiming support and leaving a half install is worse than
# not supporting it. CentOS Stream, Fedora, Oracle, Amazon Linux and non-LTS
# Ubuntu are "unstable" in Virtualmin's own classification, so also out.
#
# ONE list: "supported" means "tested". A system is tested first, then added -
# hence no second "supported but unverified" list.
OS_KEY="${OS_ID}-${OS_VER}"
OS_SUPPORTED="debian-12 debian-13 ubuntu-22.04 ubuntu-24.04"

if ! printf '%s\n' $OS_SUPPORTED | grep -xF "$OS_KEY" >/dev/null; then
  if is_truthy "${ALLOW_ANY_OS:-0}"; then
    warn "Not a supported system ($OS_ID $OS_VER) - continuing because ALLOW_ANY_OS=1."
  else
    err "Supported systems: Debian 12/13, Ubuntu 22.04/24.04 LTS."
    err "Found: ${OS_ID:-?} ${OS_VER:-?}"
    err "To try anyway: ALLOW_ANY_OS=1 ./install.sh"
    exit 1
  fi
fi

# ---- 1) system state ----
# HAS_* is what the system ALREADY has, prefixed so it cannot be confused with
# the settings of the same name (POSTGRES, DOCKER, ...).
HAS_VIRTUALMIN=no; if command -v virtualmin >/dev/null 2>&1; then HAS_VIRTUALMIN=yes; fi
HAS_DOCKER=no;     if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAS_DOCKER=yes; fi
HAS_PORTAINER=no;  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x portainer >/dev/null; then HAS_PORTAINER=yes; fi
CUR_HOST="$(hostname -f 2>/dev/null || hostname)"
SRV_IP="$(detect_ip)"

log "System state:"
log "  Hostname  : $CUR_HOST"
log "  IP        : ${SRV_IP:-unknown}"
log "  Virtualmin: $HAS_VIRTUALMIN"
log "  Docker    : $HAS_DOCKER"
log "  Portainer : $HAS_PORTAINER"
say ""
[ -n "$SRV_IP" ] || { err "Could not detect the server IP. Set SERVER_IP= in config.env."; exit 1; }

# ---- 2) settings and main domain ----
# Settings come from config.env, which is TRACKED in the repository and is
# where preferences live: edit it, commit it, and the next server installs the
# same way.
#
# The main domain is NOT kept there - it is the one value that differs on every
# server, so it is asked each run. For scripted use:
#   MAIN_DOMAIN=example.com ./install.sh
if [ -f "$ROOT_DIR/config.env" ]; then
  # shellcheck source=/dev/null
  source "$ROOT_DIR/config.env"
else
  warn "config.env not found; defaults will be used for every setting."
fi

if [ -z "${MAIN_DOMAIN:-}" ]; then
  log "First make sure the A records for the main domain and the hostname"
  log "point at this server (${SRV_IP}). They are checked below."
  say ""
  while :; do
    MAIN_DOMAIN="$(ask "Main domain (e.g. example.com)" "")"
    [ -n "$MAIN_DOMAIN" ] && break
    warn "It cannot be empty."
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
# Docker and Portainer share one flag: Portainer is pointless without Docker,
# and we do not want Docker without Portainer, so they travel together.
DOCKER="${DOCKER:-1}"

# ---- 3) DNS check and mode detection ----
ensure_pkg dig bind9-dnsutils dnsutils || { err "Could not install dig (bind9-dnsutils)."; exit 1; }

log "Checking DNS (external resolver: $DNS_RESOLVER)"
mapfile -t MAIN_IPS < <(resolve_a "$MAIN_DOMAIN")
mapfile -t HOST_IPS < <(resolve_a "$HOSTNAME_FQDN")
mapfile -t NS_NAMES < <(resolve_ns "$MAIN_DOMAIN")

log "  $MAIN_DOMAIN -> ${MAIN_IPS[*]:-(does not resolve)}"
log "  $HOSTNAME_FQDN -> ${HOST_IPS[*]:-(does not resolve)}"
log "  NS: ${NS_NAMES[*]:-(none)}"

DNS_MODE=unknown
if [ ${#NS_NAMES[@]} -gt 0 ]; then
  DNS_MODE=external
  for n in "${NS_NAMES[@]}"; do
    while read -r nip; do
      [ -n "$nip" ] || continue
      if [ "$nip" = "$SRV_IP" ]; then DNS_MODE=bind; fi
    done < <(resolve_a "$n")
  done
fi

# NS1/NS2 are always this server's own nameserver pair, whatever the DNS mode:
# the local BIND zone is always built as if we managed the delegation, and the
# Cloudflare sync simply does not push NS/SOA. The only difference between the
# two modes is therefore where the delegation points.
NS1="${NS1_PREFIX:-ns1}.${MAIN_DOMAIN}"
NS2="${NS2_PREFIX:-ns2}.${MAIN_DOMAIN}"

# The servers that are actually authoritative - information only.
AUTH_NS="${NS_NAMES[*]:-unknown}"

case "$DNS_MODE" in
  bind)     log "  Mode: BIND - the NS records point at this server (it is authoritative)." ;;
  external) log "  Mode: EXTERNAL DNS - authoritative: $AUTH_NS" ;;
  *)        warn "  Mode: undetermined (no NS record could be read)." ;;
esac
say ""
# ---- 4) summary ----
log "Plan:"
log "  - Hostname    : $HOSTNAME_FQDN"
if [ "$HAS_VIRTUALMIN" = yes ]; then log "  - Virtualmin  : installed (skipping)"; else log "  - Virtualmin  : WILL BE INSTALLED"; fi
if is_truthy "$POSTGRES"; then
  if command -v psql >/dev/null 2>&1; then log "  - PostgreSQL  : installed (skipping)"
  else                                     log "  - PostgreSQL  : WILL BE INSTALLED"; fi
fi
if is_truthy "$COMPOSER"; then
  if command -v composer >/dev/null 2>&1; then log "  - Composer    : installed (skipping)"
  else                                         log "  - Composer    : WILL BE INSTALLED"; fi
fi
log "  - DNS template: NS1=${NS1}  NS2=${NS2}   (this server's NS pair)"
log "  - Main domain : $MAIN_DOMAIN  (web, ssl, dns, mail, mysql, webmin + plugins)"
log "  - SSL         : Let's Encrypt for $MAIN_DOMAIN"
if is_truthy "$NO_ADMIN_REDIRECT"; then
  log "  - admin.<domain> -> panel redirect: WILL BE DISABLED"
fi
if is_truthy "$NO_WEBMAIL_REDIRECT"; then
  log "  - webmail.<domain> -> Usermin redirect: WILL BE DISABLED"
fi
if is_truthy "$PANEL_PROXY"; then
  log "  - ${WEBMIN_PREFIX:-webmin}.${MAIN_DOMAIN} -> Webmin (proxy)"
  log "  - ${USERMIN_PREFIX:-usermin}.${MAIN_DOMAIN} -> Usermin (proxy)"
  is_truthy "$LOCK_PANEL_PORTS" &&
    log "  - Management ports (10000/20000) will bind to 127.0.0.1 only"
fi
if is_truthy "$ROUNDCUBE"; then
  log "  - ${WEBMAIL_PREFIX:-webmail}.${MAIN_DOMAIN} -> Roundcube"
fi
log "  - Plugins     :$(plugin_list_enabled)"

if is_truthy "$DOCKER"; then
  log "  - Docker + Portainer"
  log "  - ${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN} -> Portainer proxy"
fi
say ""
# ---- validation ----
errors=()
case "$MAIN_DOMAIN" in
  *.*) ;;
  *) errors+=("MAIN_DOMAIN is not a valid domain: $MAIN_DOMAIN");;
esac
if ! is_truthy "${SKIP_DNS_CHECK:-0}"; then
  if [ ${#MAIN_IPS[@]} -eq 0 ] || ! ip_in_list "$SRV_IP" "${MAIN_IPS[@]}"; then
    errors+=("$MAIN_DOMAIN -> ${MAIN_IPS[*]:-does not resolve} ; expected: $SRV_IP  (fix the A record)")
  fi
  if [ ${#HOST_IPS[@]} -eq 0 ] || ! ip_in_list "$SRV_IP" "${HOST_IPS[@]}"; then
    errors+=("$HOSTNAME_FQDN -> ${HOST_IPS[*]:-does not resolve} ; expected: $SRV_IP  (add the A record)")
  fi
fi

if [ ${#errors[@]} -gt 0 ]; then
  err "There are problems - NOTHING was run:"
  for e in "${errors[@]}"; do err "  ! $e"; done
  say ""
  err "For DNS, these two A records must point at $SRV_IP at your provider:"
  err "    $MAIN_DOMAIN      A   $SRV_IP"
  err "    $HOSTNAME_FQDN    A   $SRV_IP"
  err "On Cloudflare, keep the proxy OFF (grey cloud) during the install."
  err "Wait for propagation and run again. To skip the check: SKIP_DNS_CHECK=1 ./install.sh"
  exit 1
fi

# ---- confirmation ----
# The summary is always shown and confirmation is always asked: if a setting
# looks wrong, cancel, fix config.env and run again.
if ! ask_yn "Continue with these settings?" Y; then
  warn "Cancelled. The settings are in: $ROOT_DIR/config.env"
  exit 0
fi

# ---- STEPS, IN AN EXPLICIT ORDER ----
#
# set -e is OFF here. Each step reports its own error and returns 1; one
# failing step must not cancel the rest. With set -e on, the first failure
# killed the whole install. The preparation and validation above keep set -e,
# where stopping IS the right behaviour.
#
# run_step records the failures so the end of a long install, and the report,
# can say what did not work.
set +e
VMINKIT_STEPS_STARTED=1
say ""
run_step step_hostname
run_step step_virtualmin
# The hostname virtual server right after the Virtualmin install: that is where
# the installer creates it too, while no domain exists yet.
run_step step_host_domain
if is_truthy "$POSTGRES"; then run_step step_postgres; fi
if is_truthy "$COMPOSER"; then run_step step_composer; fi
run_step step_dns_template
run_step step_panel_redirects
run_step step_domain_defaults
run_step step_dkim
# Plugins BEFORE any domain, so their features can be selected while the domain
# is created. Virtualmin is installed by now, so BIND is too and the zone
# directory the sync service watches already exists.
run_step step_plugins
run_step step_main_domain
run_step step_host_dns
run_step step_ssl
if is_truthy "$PANEL_PROXY"; then run_step step_panel_sites; fi
if is_truthy "$ROUNDCUBE"; then run_step step_webmail; fi
if is_truthy "$DOCKER"; then
  run_step step_docker
  run_step step_portainer
  run_step step_docker_site
fi
# Locking LAST: the proxies are verified first, and the port stays open if they
# cannot be. In the wrong order this loses access to the panel.
if is_truthy "$PANEL_PROXY" && is_truthy "$LOCK_PANEL_PORTS"; then
  run_step step_lock_panel_ports
fi
step_report
set -e

# The token is produced LAST because it is valid for only a few minutes, so it
# must be fresh however many steps are added before it. The closing lines come
# after it, otherwise the token ends up above them and the screen does not look
# like it has finished.
if is_truthy "$DOCKER"; then step_portainer_token; fi

# The addresses are already together in the summary and are NOT repeated here.
# The closing lines only answer "did it finish" and "where is the full output".
say ""
if [ ${#VMINKIT_FAILED[@]} -gt 0 ]; then
  warn "Finished with problems."
else
  ok "Done."
fi
log "Install log: $VMINKIT_LOGFILE"
