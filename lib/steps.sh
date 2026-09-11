#!/usr/bin/env bash
# Step functions. install.sh calls them in an explicit order. Their inputs are
# set by install.sh or come from config.env: MAIN_DOMAIN, HOSTNAME_FQDN, NS1,
# NS2, DNS_MODE and the feature flags. Every step is idempotent.

# Steps run under 'set +e', so a failure does not stop the install. Their names
# are collected here because a single red line scrolls away during a long run;
# the summary and the closing line both read this.
VMINKIT_FAILED=()

# Certificate state per sub-domain prefix: 1 = valid ACME cert, 0 = self-signed.
# ensure_site_cert writes it, the port-closing steps read it.
#
# Without it we can lock a user out of their own server: a browser will not
# trust a self-signed address, so if the management port is closed at the same
# moment there is no way in at all.
declare -A VMINKIT_SITE_CERT=()

# run_step <step-function>
# Runs the step and records its name on failure. The status is taken with
# '|| rc=$?' rather than 'if "$fn"' - a failing if without else yields 0, so $?
# would be the if's status, not the step's.
#
# No error DETAIL is printed: command output is already in the install log, and
# the screen's job is to show state.
run_step(){
  local fn="$1" rc=0
  "$fn" || rc=$?
  [ "$rc" -eq 0 ] || VMINKIT_FAILED+=("${fn#step_}")
  return "$rc"
}

# Which version of the tool built this server - the answer a year from now.
# '-uno' ignores untracked files: the install leaves files of its own behind,
# and counting them reported "modified" when no code had changed.
vminkit_version(){
  local v
  v="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$v" ] || { printf 'unknown'; return; }
  if [ -n "$(git -C "$ROOT_DIR" status --porcelain -uno 2>/dev/null)" ]; then
    v="$v (modified working copy)"
  fi
  printf '%s' "$v"
}

step_hostname(){
  local cur; cur="$(hostname -f 2>/dev/null || hostname)"
  if [ "$cur" = "$HOSTNAME_FQDN" ]; then ok "Hostname is already $HOSTNAME_FQDN."; return; fi
  log "Hostname -> $HOSTNAME_FQDN (was: $cur)"
  hostnamectl set-hostname "$HOSTNAME_FQDN"
  local ip short; ip="$(detect_ip)"; short="${HOSTNAME_FQDN%%.*}"
  if ! grep -q "[[:space:]]$HOSTNAME_FQDN\([[:space:]]\|$\)" /etc/hosts; then
    printf '%s %s %s\n' "${ip:-127.0.1.1}" "$HOSTNAME_FQDN" "$short" >> /etc/hosts
  fi
  ok "Hostname set."
}

step_virtualmin(){
  if command -v virtualmin >/dev/null 2>&1; then ok "Virtualmin is already installed (skipping)."; return; fi
  ensure_pkg curl curl || { err "Could not install curl."; return 1; }
  # The URL matters: 'install.sh', NOT 'virtualmin-install.sh'. The old name is
  # still served but frozen at VER=7.5.2 ("Debian 10, 11 and 12"), which is why
  # installs used to end up a year behind and why Debian 13 appeared unsupported.
  log "Downloading the official Virtualmin installer..."
  curl -fsSL https://software.virtualmin.com/gpl/scripts/install.sh -o /root/virtualmin-install.sh
  chmod +x /root/virtualmin-install.sh
  local args=(--force --hostname "$HOSTNAME_FQDN")
  # The one step whose output is also shown on screen: it runs for minutes, and
  # a silent screen for that long reads as a hang.
  log "Running (takes a while, output shown): virtualmin install.sh ${args[*]}"
  run_visible sh /root/virtualmin-install.sh "${args[@]}"
  ok "Virtualmin installed."
}

# Does the domain have an ACME (Let's Encrypt) certificate?
# The label is not reliable - the line in list-domains output is named
# differently across Virtualmin versions - so check the filesystem first.
domain_has_acme_cert(){
  local d="$1"
  [ -s "/etc/letsencrypt/live/$d/cert.pem" ] && return 0
  virtualmin list-domains --domain "$d" --multiline 2>/dev/null \
    | grep -i 'cert issued' >/dev/null && return 0
  return 1
}

# PostgreSQL does not come with Virtualmin; install the package separately.
step_postgres(){
  if command -v psql >/dev/null 2>&1; then
    ok "PostgreSQL is already installed."
  else
    log "Installing PostgreSQL..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
    # Verify: steps run under 'set +e', so a failed apt-get would otherwise be
    # followed by a line claiming success.
    if ! command -v psql >/dev/null 2>&1; then
      err "Could not install PostgreSQL (psql not found)."
      return 1
    fi
    ok "PostgreSQL installed. The post-install wizard will offer it."
  fi
  # The feature needs no enabling here: Virtualmin detects PostgreSQL itself
  # and offers it in the wizard. (set-global-feature does not work on a fresh
  # box - clamd is not up yet and Virtualmin's config check refuses.)
  systemctl enable --now postgresql 2>/dev/null || warn "Could not start the postgresql service."
}

# Composer does not come with Virtualmin either; the vmkit-composer plugin
# requires it and will not open without it.
step_composer(){
  if command -v composer >/dev/null 2>&1; then
    ok "Composer is already installed."
    return
  fi
  log "Installing Composer..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y composer
  # Verify, as above. The message deliberately names no cause: it used to
  # assert that Ubuntu's 'universe' component was disabled, which turned out
  # to be wrong on a real failure (the mirror was missing the .deb the index
  # advertised). A made-up cause delays finding the real one.
  if ! command -v composer >/dev/null 2>&1; then
    err "Could not install Composer. Apt's own output is in the install log."
    return 1
  fi
  ok "Composer installed."
}

step_dns_template(){
  local cfg="/etc/webmin/virtual-server/config"
  if [ ! -f "$cfg" ]; then err "No Virtualmin config; skipping dns-template."; return 1; fi
  if [ -z "${NS1:-}" ] || [ -z "${NS2:-}" ]; then warn "NS1/NS2 empty; skipping dns-template."; return 0; fi
  [ -f "${cfg}.vmin-kit.bak" ] || cp -a "$cfg" "${cfg}.vmin-kit.bak"
  # dns_default_ip4/ip6 is BIND's recursive forwarder, not an A-record address;
  # leave it alone.
  set_kv "$cfg" bind_master "$NS1"
  set_kv "$cfg" dns_ns      "$NS2"
  set_kv "$cfg" dns_prins   "1"
  set_kv "$cfg" bind_sub    "yes"
  systemctl restart webmin 2>/dev/null || warn "Could not restart webmin (manually: systemctl restart webmin)"
  ok "dns-template: bind_master=$NS1, dns_ns=$NS2, bind_sub=yes"
}

# Virtualmin adds two shortcuts to every new domain - admin.<domain> to Webmin
# and webmail.<domain> to Usermin - each an A record plus a 301 in the vhost.
# We want neither; the panel is reached through the hostname.
#
# The switches are template-level (web_admin / web_webmail), and the default
# template has no file of its own: template 0 is built from the module config,
# so the right place to write is virtual-server/config.
#
# Each key disables both the DNS record and the redirect with its ServerAlias.
# Losing the alias also keeps the name out of certificates, because
# get_hostnames_for_ssl only collects names the web server actually answers on.
#
# Must run BEFORE any domain exists: disabling later does not clean up domains
# that already have the record and the redirect.
step_panel_redirects(){
  local cfg="/etc/webmin/virtual-server/config"
  if [ ! -f "$cfg" ]; then err "No Virtualmin config; skipping panel redirects."; return 1; fi
  [ -f "${cfg}.vmin-kit.bak" ] || cp -a "$cfg" "${cfg}.vmin-kit.bak"

  local row key flag name cur
  for row in "web_admin|${NO_ADMIN_REDIRECT:-1}|admin"              "web_webmail|${NO_WEBMAIL_REDIRECT:-1}|webmail"; do
    IFS='|' read -r key flag name <<< "$row"
    if ! is_truthy "$flag"; then
      log "  leaving the ${name}.<domain> redirect alone (setting is 0)."
      continue
    fi
    # Values can contain '=' (newdom_aliases does), so sed rather than awk -F=.
    cur="$(sed -n "s/^${key}=//p" "$cfg" | head -1)"
    if [ "$cur" = "0" ]; then
      ok "${name}.<domain> redirect is already off."
    else
      set_kv "$cfg" "$key" "0"
      ok "${name}.<domain> redirect turned off (for domains created from now on)."
    fi
  done
}

# Domain defaults, written to Virtualmin's module config before the first
# domain exists because that is where new domains read them from.
#
#   bind_spf=yes   an SPF record on every new domain; off by default
#   bind_spfall=1  the SPF "all" qualifier. 0/1/2 here become ?all / ~all / -all.
#                  Empty yields ?all, which asserts nothing. 1 (~all) is the
#                  safe standard; -all rejects forwarded mail.
#   bind_dmarc=yes a DMARC record on every new domain. The policy is left unset,
#                  which means p=none: published but blocking nothing. Tighten
#                  from the panel once SPF and DKIM are confirmed working.
#
# spam=0 / virus=0 are deliberately NOT written here. Setting them made the
# post-install wizard stop asking about spam and virus scanning - it only asks
# about features that are on - so the decision became silently ours. The main
# domain gets an explicit feature list instead (step_main_domain), which keeps
# it light while leaving the question to the user.
#
# Also deliberately untouched: mailbox naming (append_style) and the target of
# the role aliases. The domain owner's unix account is its mailbox, and every
# way of changing that carries the name into the home directory and the
# database name too.
step_domain_defaults(){
  local cfg="/etc/webmin/virtual-server/config"
  if [ ! -f "$cfg" ]; then err "No Virtualmin config; skipping domain defaults."; return 1; fi
  [ -f "${cfg}.vmin-kit.bak" ] || cp -a "$cfg" "${cfg}.vmin-kit.bak"

  local row key val name cur
  for row in "bind_spf|yes|SPF record" \
             "bind_spfall|1|SPF qualifier (~all)" \
             "bind_dmarc|yes|DMARC record"; do
    IFS='|' read -r key val name <<< "$row"
    cur="$(sed -n "s/^${key}=//p" "$cfg" | head -1)"
    if [ "$cur" = "$val" ]; then
      ok "$name: already set ($key=$val)"
    else
      set_kv "$cfg" "$key" "$val"
      ok "$name: wrote $key=$val"
    fi
  done

  # Role addresses: keep only the ones that are actually required.
  #   postmaster  must be accepted (RFC 5321)
  #   abuse       where other operators and blocklists send reports
  # hostmaster and webmaster are convention only - nothing in Virtualmin uses
  # them, and the SOA record does not point at hostmaster either.
  #
  # The value is FILTERED, not rewritten from scratch, so Virtualmin's own
  # target format survives. Affects domains created from now on.
  local keep="${ROLE_ALIASES:-postmaster abuse}" cur_a new_a e nm
  cur_a="$(sed -n "s/^newdom_aliases=//p" "$cfg" | head -1)"
  if [ -z "$cur_a" ]; then
    log "  Role-address template is empty; left alone."
  else
    new_a=""
    # '%s\n', not '%s': without the newline 'read' never sees the last entry
    # and it was dropped silently.
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      nm="${e%%=*}"
      case " $keep " in *" $nm "*) new_a="${new_a}${new_a:+$'\t'}${e}" ;; esac
    done < <(printf '%s\n' "$cur_a" | tr '\t' '\n')
    if [ -z "$new_a" ]; then
      warn "  '$keep' not found in the role-address template; left alone."
    elif [ "$cur_a" = "$new_a" ]; then
      ok "Role addresses: already just $keep"
    else
      set_kv "$cfg" newdom_aliases "$new_a"
      ok "Role addresses: reduced to $keep"
    fi
  fi
}

# DKIM: sign outgoing mail.
#
# A server-wide, one-time setup, so it runs BEFORE the first domain: with DKIM
# enabled, every domain created afterwards gets its <selector>._domainkey record
# automatically. There is no CLI for this, so the steps of the panel's
# enable_dkim.cgi are repeated here (selector defaults to YYYYMM, sign and
# verify on, only domains with DNS and mail, 2048-bit key).
#
# check_dkim() reports why the system cannot do it; in that case we skip rather
# than fail the install.
step_dkim(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping DKIM."; return 1; }
  local out
  out="$(perl -e '
    my ($root) = @ARGV;
    $ENV{WEBMIN_CONFIG} ||= q(/etc/webmin); $ENV{WEBMIN_VAR} ||= q(/var/webmin);
    push(@INC, $root); $main::no_acl_check++;
    chdir("$root/virtual-server");
    $0 = "$root/virtual-server/vmkit-dkim.pl";
    require q(./virtual-server-lib.pl);
    my $err = &check_dkim();
    if ($err) { print qq(VMKIT-DKIM:SKIP $err\n); exit(0); }
    my $dkim = &get_dkim_config() || { };
    if ($dkim->{enabled}) { print qq(VMKIT-DKIM:ALREADY $dkim->{selector}\n); exit(0); }
    $dkim->{selector} ||= &get_default_dkim_selector();
    $dkim->{enabled} = 1;
    $dkim->{sign}    = 1;
    $dkim->{verify}  = 1;
    $dkim->{alldns}  = 0;
    $dkim->{extra} ||= [ ];
    &set_all_text_print();
    my $ok = &enable_dkim($dkim, 0, 2048);
    if (!$ok) { print qq(VMKIT-DKIM:FAILED\n); exit(1); }
    $config{dkim_enabled} = 1;
    &lock_file($module_config_file);
    &save_module_config();
    &unlock_file($module_config_file);
    &run_post_actions();
    print qq(VMKIT-DKIM:OK $dkim->{selector}\n);
  ' "$(webmin_root)" 2>&1)"

  printf '%s\n' "$out" | grep -v '^VMKIT-DKIM:' | sed 's/^/    /'
  # The marker is extracted per LINE: ${out##...} would take everything after
  # the marker instead.
  local mark val
  mark="$(printf '%s\n' "$out" | grep '^VMKIT-DKIM:' | head -1)"
  val="${mark#VMKIT-DKIM:* }"
  case "$mark" in
    "VMKIT-DKIM:ALREADY"*) ok "DKIM is already on (selector: $val)." ;;
    "VMKIT-DKIM:SKIP"*)    warn "DKIM not enabled, skipping: $val" ;;
    "VMKIT-DKIM:OK"*)      ok "DKIM enabled (selector: $val)." ;;
    *)                     err "Could not enable DKIM."; return 1 ;;
  esac
}

# Creates the main domain with an EXPLICIT feature list.
#
# '--default-features' was used at first and had two problems: shaping those
# defaults meant changing Virtualmin's global config, which silenced the
# post-install wizard's questions; and the result became "whatever this server
# currently defaults to", which is not reproducible.
#
# The list:
#   unix dir    user and home directory; both mandatory
#   web ssl     the site and its certificate - the reason the domain exists
#   dns         the local BIND zone; the Cloudflare sync models itself on it
#   mail        where the role addresses (postmaster/abuse) land
#   logrotate   so the domain's logs do not grow forever
#   webmin      lets the domain owner sign in to the panel
#   mysql       REQUIRED: the webmail sub-server needs a database for Roundcube,
#               and sub-servers take their MySQL user from the PARENT, so
#               without mysql here that database would have no owner
#   vmkit-*     our own plugins
#
# Deliberately absent: spam and virus (the wizard should ask), postgres (the
# wizard enables it), virtualmin-awstats (per domain if wanted).
#
# Enabling mail turns the domain owner's unix account into a mailbox at
# <user>@<domain>. Its password is random and discarded, so set one from the
# panel before using it.
step_main_domain(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping main domain."; return 1; }
  if virtualmin list-domains --name-only 2>/dev/null | grep -x "$MAIN_DOMAIN" >/dev/null; then
    ok "Main domain already exists: $MAIN_DOMAIN (skipping)."; return
  fi
  # Random password, stored nowhere. A secret that is not kept cannot leak;
  # set a real one from the panel when it is needed.
  local pw; pw="$(gen_pass)"

  # Flags are FILTERED against the module config. Passing a flag for a disabled
  # feature stops create-domain with a usage error, and since the main domain
  # would then not exist, every following step (SSL, panel sites, webmail,
  # docker) fails too. Skipping the feature with a warning is far better than
  # losing the whole install. This is also why postgres cannot be listed here:
  # it is off until the wizard enables it.
  local cfg="/etc/webmin/virtual-server/config"
  local want="unix dir web ssl dns mail logrotate webmin mysql"
  local -a flags=()
  local f skipped=""
  for f in $want; do
    if grep -qE "^${f}=[^0]" "$cfg" 2>/dev/null; then
      flags+=("--$f")
    else
      skipped="$skipped $f"
    fi
  done
  # Plugins are checked separately: they must be on the 'plugins=' line, which
  # step_plugins writes before this step runs.
  local p
  for p in vmkit-cloudflare vmkit-composer vmkit-deploy; do
    if grep -qE "^plugins=.*\b${p}\b" "$cfg" 2>/dev/null; then
      flags+=("--$p")
    else
      skipped="$skipped $p"
    fi
  done
  [ -z "$skipped" ] || warn "Skipped because they are disabled:$skipped"

  log "Creating the main domain: $MAIN_DOMAIN"
  virtualmin create-domain \
    --domain "$MAIN_DOMAIN" \
    --pass   "$pw" \
    --desc   "$MAIN_DOMAIN" \
    "${flags[@]}"
  unset pw
  ok "Main domain created."
  # Record what was actually enabled: some flags depend on the module config.
  virtualmin list-domains --domain "$MAIN_DOMAIN" --multiline 2>/dev/null |
    awk '/^[[:space:]]*(Features|Plugins):/ { sub(/^[[:space:]]*/,""); print "    "$0 }'
}

# The hostname needs an A record in the main domain's zone; Virtualmin does not
# add one. With external DNS the published copy lives elsewhere, but the local
# zone is our model and has to be right for the sync to send the right record.
# In BIND mode it is what makes the panel address resolve once delegation lands.
step_host_dns(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping the hostname DNS record."; return 1; }
  case "$HOSTNAME_FQDN" in
    *".$MAIN_DOMAIN") ;;
    *) log "Hostname is not a subdomain of the main domain; skipping the DNS record."; return;;
  esac
  local ip; ip="$(detect_ip)"
  if virtualmin get-dns --domain "$MAIN_DOMAIN" --name-only 2>/dev/null \
     | sed 's/\.$//' | grep -ixF "$HOSTNAME_FQDN" >/dev/null; then
    ok "The zone already has a record for $HOSTNAME_FQDN."
    return
  fi
  log "Adding the hostname A record to the zone: $HOSTNAME_FQDN -> $ip"
  if virtualmin modify-dns --domain "$MAIN_DOMAIN" --add-record "${HOSTNAME_FQDN}. A ${ip}"; then
    ok "Hostname A record added."
  else
    warn "Could not add it. Manually:"
    warn "  virtualmin modify-dns --domain $MAIN_DOMAIN --add-record \"${HOSTNAME_FQDN}. A ${ip}\""
  fi
}

# The hostname virtual server.
#
# Virtualmin's installer only keeps this when the certificate succeeds - its
# SSL config plugin deletes what it created on failure - but the virtual server
# is needed regardless: it is the DEFAULT website a bare-IP request lands on,
# and it is where the Webmin/Usermin/Postfix/Dovecot certificates come from.
# Without it Apache falls back to the alphabetically first vhost.
#
# Virtualmin's own function is called rather than a plain create-domain: it
# marks the domain 'defaulthostdomain', sets the default website and manages
# the default_domain_ssl key. A hand-made domain would appear in the list but
# Virtualmin would not recognise it as the hostname domain. There is no CLI
# wrapper for it, hence the inline Perl in Webmin's environment.
step_host_domain(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping the hostname virtual server."; return 1; }
  local host="$HOSTNAME_FQDN" vsdir="/usr/share/webmin/virtual-server"

  if virtualmin list-domains --name-only 2>/dev/null | grep -xF "$host" >/dev/null; then
    ok "Hostname virtual server already exists: $host"
    # The function is no use here: it refuses when the domain exists
    # ('check_defhost_clash'), so the certificate is requested the normal way.
    ensure_site_cert hostname "$host" || true
    # Distribute ONLY when the certificate was obtained in this run. Renewal
    # refreshes services that already hold a copy of the cert, so unless the
    # first copy is made once, that list stays empty forever.
    [ "${VMINKIT_CERT_NEW:-0}" = "1" ] && host_cert_to_services "$host"
    site_cert_ok hostname "$host"
    return
  fi

  if [ ! -f "$vsdir/virtual-server-lib.pl" ]; then
    err "Virtualmin module not found: $vsdir"
    return 1
  fi
  log "Creating the hostname virtual server: $host"
  WEBMIN_CONFIG=/etc/webmin WEBMIN_VAR=/var/webmin perl - "$vsdir" <<'PERL'
package virtual_server;
my $dir = shift(@ARGV);
$main::no_acl_check++;
chdir($dir);
$0 = "$dir/vmkit-host-domain.pl";
require './virtual-server-lib.pl';
&set_all_text_print();
my ($ok, $msg) = &setup_virtualmin_default_hostname_ssl();
$msg =~ s/<[^>]*>//g;
print "vmkit: hostname domain -> ", ($ok ? "ok" : "fail"), " : $msg\n";
PERL

  # Success is checked against the system, not the return code: the function
  # uses the same value for a failed certificate and for early refusals.
  if ! virtualmin list-domains --name-only 2>/dev/null | grep -xF "$host" >/dev/null; then
    err "Could not create the hostname virtual server: $host"
    return 1
  fi
  ok "Hostname virtual server created: $host"

  # The intent has to be recorded in Virtualmin's config as well: its
  # "Re-Check Configuration" DELETES the hostname domain when the domain
  # exists while default_domain_ssl is off, and Virtualmin only sets that key
  # when the certificate succeeded.
  #
  # Value 1 is what Virtualmin itself writes, so both paths end up identical.
  # 2 would also show the domain in the panel's lists, which we do not want.
  # An existing value is left alone - the user's choice wins.
  local vcfg="/etc/webmin/virtual-server/config"
  if [ -f "$vcfg" ]; then
    case "$(awk -F= '/^default_domain_ssl=/{print $2; exit}' "$vcfg")" in
      1|2) ;;
      *) set_kv "$vcfg" default_domain_ssl 1
         ok "  Hostname domain enabled in the Virtualmin settings." ;;
    esac
  fi

  # When the certificate succeeded, the function distributed it to the services.
  if domain_has_acme_cert "$host"; then
    VMINKIT_SITE_CERT[hostname]=1
    ok "Certificate obtained: $host"
    return 0
  fi
  VMINKIT_SITE_CERT[hostname]=0
  warn "Could not obtain a certificate: $host (still self-signed)"
  return 1
}

# host_cert_to_services <hostname>
# Makes the hostname certificate the services' global default.
#
# Services do not work like vhosts: Postfix, Dovecot and miniserv present one
# certificate whatever name the client used, and that certificate is a COPY of
# the file (/etc/webmin/<host>.cert and friends), not a link.
#
# Called one service at a time: install-service-cert rejects the whole call if
# any service name is invalid, and the valid list comes from the system at
# runtime, so this is the only way to skip an unsupported one quietly.
host_cert_to_services(){
  local host="$1" svc
  local -a done_svc=()
  for svc in webmin usermin postfix dovecot proftpd; do
    virtualmin install-service-cert --domain "$host" --add-global --service "$svc" \
      && done_svc+=("$svc")
  done
  if [ ${#done_svc[@]} -gt 0 ]; then
    ok "Certificate copied to services: ${done_svc[*]}"
    return 0
  fi
  warn "Could not copy the certificate to any service."
  return 1
}

step_ssl(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping SSL."; return 1; }
  # create-domain already requests the certificate when automatic ACME is on.
  # Asking again would issue a second certificate for the same name set and eat
  # the provider's quota.
  if domain_has_acme_cert "$MAIN_DOMAIN"; then
    ok "Certificate already obtained (skipping)."
    return
  fi
  log "Requesting a certificate (ACME/Let's Encrypt): $MAIN_DOMAIN"
  if virtualmin generate-letsencrypt-cert --domain "$MAIN_DOMAIN" --default-hosts --renew; then
    ok "Certificate obtained, automatic renewal is on."
  else
    warn "Could not obtain a certificate. Check the A record and access to ports 80/443, then:"
    warn "  virtualmin generate-letsencrypt-cert --domain $MAIN_DOMAIN --default-hosts --renew"
  fi
}

# ensure_site_cert <key> [fqdn] -> does this address have a valid ACME cert?
#
# Without an fqdn, <key>.<main-domain> is assumed; the hostname virtual server
# need not be a subdomain of the main domain, so it passes one.
#
# Called right after a sub-server is created - the same shape as step_ssl for
# the main domain. Virtualmin only requests a certificate while CREATING the
# domain: if DNS has not propagated yet or the Let's Encrypt quota is spent it
# says "keeping self-signed certificate" and nobody ever asks again. Retrying
# here means re-running ./install.sh is enough once the obstacle clears.
#
# Only a domain WITHOUT a certificate is requested: asking every run would
# burn the quota (5 per 7 days for the same name set).
#
# The verdict goes into VMINKIT_SITE_CERT for the port-closing steps, and
# VMINKIT_CERT_NEW marks a certificate obtained in THIS run.
ensure_site_cert(){
  local key="$1" site="${2:-$1.${MAIN_DOMAIN}}"
  VMINKIT_CERT_NEW=0
  if domain_has_acme_cert "$site"; then
    VMINKIT_SITE_CERT["$key"]=1
    ok "Certificate in place: $site"
    return 0
  fi
  log "Requesting a certificate (ACME): $site"
  if virtualmin generate-letsencrypt-cert --domain "$site" --default-hosts --renew; then
    VMINKIT_SITE_CERT["$key"]=1
    VMINKIT_CERT_NEW=1
    ok "Certificate obtained: $site"
    return 0
  fi
  VMINKIT_SITE_CERT["$key"]=0
  warn "Could not obtain a certificate: $site (still self-signed)"
  return 1
}

# site_cert_ok <key> [fqdn] -> can this address be reached with a valid cert?
# When the table was never filled (step skipped, or an older install) the
# filesystem is consulted: the decision always rests on the real state.
site_cert_ok(){
  local key="$1" site="${2:-$1.${MAIN_DOMAIN}}"
  if [ -n "${VMINKIT_SITE_CERT[$key]:-}" ]; then
    [ "${VMINKIT_SITE_CERT[$key]}" = "1" ]
    return
  fi
  domain_has_acme_cert "$site"
}

# Reads the latest setup_token from Portainer's logs (empty when there is none).
# With $1 it only looks at logs after that moment, so an old consumed token is
# never mistaken for a fresh one.
portainer_setup_token(){
  local since="${1:-}"
  if [ -n "$since" ]; then docker logs --since "$since" portainer 2>&1
  else                     docker logs portainer 2>&1; fi \
    | grep -oE 'setup_token=[0-9a-f]+' | tail -1 | cut -d= -f2
}

# Has a Portainer admin account been created?
# /api/users/admin/check returns 204 when an admin EXISTS and 404 when the
# setup is still pending. Anything else (service not up yet, path changed) is
# treated as "not set up"; the worst case is one unnecessary restart.
portainer_configured(){
  local port="${PORTAINER_PORT:-9000}" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
          "http://127.0.0.1:${port}/api/users/admin/check" 2>/dev/null || true)"
  [ "$code" = "204" ]
}

# Restarts Portainer and returns a FRESH setup_token.
portainer_restart_for_token(){
  local since tok="" i
  since="$(date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker restart portainer >/dev/null 2>&1 || return 1
  for i in $(seq 1 15); do
    sleep 2
    tok="$(portainer_setup_token "$since")"
    [ -n "$tok" ] && break
  done
  printf '%s' "$tok"
}

# The LAST step of the install: the token lives only a few minutes, so it is
# produced here no matter how many steps are added before it.
step_portainer_token(){
  command -v docker >/dev/null 2>&1 || return 0
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x portainer >/dev/null || return 0
  local site="${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}"

  # Silent when an admin account already exists: this step only speaks when
  # there is something left to do.
  portainer_configured && return 0

  say ""
  log "Getting a fresh Portainer setup_token (restarting the container)..."
  local tok; tok="$(portainer_restart_for_token || true)"
  say ""
  if [ -n "$tok" ]; then
    ok "Finish the Portainer setup NOW - the token is valid for a few minutes:"
    say "    Address     : https://${site}/"
    say "    setup_token : $tok"
    say ""
    log "If you miss the window: sudo ./configure-docker.sh"
  else
    warn "Could not read a setup_token. Try: sudo ./configure-docker.sh"
  fi
}

# ensure_proxy_site <prefix> <target-url> <description> [proxy-host]
# Creates the <prefix>.<main-domain> sub-server and proxies / to the target.
#
# This is the pattern for publishing a management UI without opening a port:
# the interface listens on 127.0.0.1 and is reached through Apache under that
# sub-domain's OWN certificate. docker./webmin./usermin. all use it.
#
# Features are kept minimal: --dir (required for a website), --web (vhost),
# --ssl, --dns (the sub-domain's A record - with bind_sub=yes it goes into the
# parent zone rather than creating a new one; without it the name does not
# resolve at all), --parent (a sub-server, so no separate unix user) and
# --break-ssl-cert so it gets its own certificate instead of sharing the main
# domain's.
#
ensure_proxy_site(){
  local prefix="$1" url="$2" desc="$3" phost="${4:-}"
  local site="${prefix}.${MAIN_DOMAIN}"
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping $site."; return 1; }

  if virtualmin list-domains --name-only 2>/dev/null | grep -xF "$site" >/dev/null; then
    ok "Sub-server already exists: $site"
  else
    log "Creating sub-server: $site (parent: $MAIN_DOMAIN)"
    if ! virtualmin create-domain \
           --domain "$site" \
           --parent "$MAIN_DOMAIN" \
           --desc   "$desc" \
           --dir --web --ssl --dns --break-ssl-cert; then
      err "Could not create $site."
      return 1
    fi
    ok "Sub-server created: $site"
  fi

  # Is the proxy already defined? (look for the target in the vhost)
  local vhost="/etc/apache2/sites-available/${site}.conf"
  if [ -f "$vhost" ] && grep -qF "$url" "$vhost"; then
    ok "Proxy already defined: / -> $url"
  else
    log "Setting up the proxy: / -> $url  (with websocket support)"
    # Update an existing proxy (an old http target, say), otherwise create one.
    if virtualmin modify-proxy --domain "$site" --path / --url "$url" >/dev/null 2>&1; then
      ok "Proxy target updated."
    elif virtualmin create-proxy --domain "$site" --path / --url "$url" --websockets; then
      ok "Proxy added."
    else
      err "Could not add the proxy. Manually: virtualmin create-proxy --domain $site --path / --url $url --websockets"
      return 1
    fi
  fi

  # The 4th argument turns on ProxyPreserveHost. Webmin and Usermin need it
  # behind a proxy: without it the Host header they see is 127.0.0.1:<port>,
  # so the URLs they generate and their session checks are all wrong.
  # Portainer does not need it, so the docker site passes no 4th argument.
  if [ -n "$phost" ]; then
    if [ -f "$vhost" ] && grep -qi 'ProxyPreserveHost[[:space:]]*On' "$vhost"; then
      ok "Host header is already forwarded."
    else
      if virtualmin modify-web --domain "$site" --proxy-host >/dev/null 2>&1; then
        ok "Host header forwarded to the proxy (ProxyPreserveHost On)."
      else
        warn "Could not enable ProxyPreserveHost; logins through $site may be refused."
      fi
    fi
  fi

  # Certificate check belongs to the site's own step, right after creation -
  # the same shape as step_ssl for the main domain. A missing certificate does
  # NOT fail this step: the site and the proxy work, only the trusted
  # certificate is missing, and the port-closing step decides what that means.
  ensure_site_cert "$prefix" || true

  return 0
}

# proxy_site_works <prefix> -> does the proxy actually answer?
# Independent of DNS: --resolve goes straight to the local Apache with the
# right Host and SNI, because with external DNS the sub-domain may not have
# propagated yet while the proxy itself is fine.
proxy_site_works(){
  local site="$1.${MAIN_DOMAIN}" code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
          --resolve "${site}:443:127.0.0.1" "https://${site}/" 2>/dev/null || true)"
  case "$code" in
    200|302|301|401) return 0 ;;
    *) log "  $site -> HTTP ${code:-no response}"; return 1 ;;
  esac
}


# webmail.<main-domain>: Roundcube.
#
# Not a proxy but a real PHP application, installed through Virtualmin's own
# Install Scripts, which is why this sub-server is created with --mysql.
#
# Roundcube is only an IMAP client: the mail lives in Dovecot's Maildir and
# users, mailboxes and passwords stay in Virtualmin. Logins use the full email
# address.
step_webmail(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping webmail."; return 1; }
  local site="${WEBMAIL_PREFIX:-webmail}.${MAIN_DOMAIN}"

  if virtualmin list-domains --name-only 2>/dev/null | grep -xF "$site" >/dev/null; then
    ok "Sub-server already exists: $site"
  else
    log "Creating sub-server: $site (parent: $MAIN_DOMAIN)"
    if ! virtualmin create-domain \
           --domain "$site" \
           --parent "$MAIN_DOMAIN" \
           --desc   "Roundcube (vmin-kit)" \
           --dir --web --ssl --dns --mysql --break-ssl-cert; then
      err "Could not create $site; skipping Roundcube."
      return 1
    fi
    ok "Sub-server created: $site"
  fi

  # Same shape as the proxy sites: certificate right after creation.
  ensure_site_cert "${WEBMAIL_PREFIX:-webmail}" || true

  if virtualmin list-scripts --domain "$site" 2>/dev/null | grep -i roundcube >/dev/null; then
    ok "Roundcube is already installed: https://${site}/"
  else
    log "Installing Roundcube: https://${site}/  (download and setup take a while)"
    if virtualmin install-script --domain "$site" --type roundcube \
           --version latest --path / --db "mysql roundcube" --newdb --prefix-db; then
      ok "Roundcube installed: https://${site}/"
    else
      err "Could not install Roundcube. Manually: Virtualmin -> $site -> Install Scripts"
      return 1
    fi
  fi

  # Sender identity. Virtualmin's installer writes mail_domain by REPLACING a
  # line in config.inc.php.sample, and Roundcube 1.7 no longer ships that line,
  # so the value stayed empty and the domain owner's identity came out as
  # <user>@localhost.
  #
  # A single mail_domain would be wrong on a multi-domain server, so the
  # virtuser_file plugin is used instead: it looks the login name up in
  # Postfix's virtual map. The setting alone is not enough - the plugin must
  # also be in $config['plugins'].
  #
  # Scope: this fixes the domain owner only. Aliases are not covered, because
  # the map is two levels deep (alias -> address -> unix user) while the plugin
  # looks at one, and login names containing @ are escaped in the map. Add
  # aliases as identities in Roundcube by hand.
  local dir cfg
  dir="$(virtualmin list-scripts --domain "$site" --multiline 2>/dev/null |
         awk -F': ' '/^[[:space:]]*Directory:/{print $2; exit}')"
  cfg="$dir/config/config.inc.php"
  if [ ! -f "$cfg" ]; then
    warn "Roundcube config not found ($cfg); skipping the identity setting."
    return 0
  fi
  if grep -q "virtuser_file" "$cfg"; then
    ok "Roundcube identity setting is already in place."
  else
    {
      echo
      echo "// vmin-kit: resolve the login name to a real address via Postfix's virtual map"
      echo "\$config['virtuser_file'] = '/etc/postfix/virtual';"
      echo "\$config['plugins'][] = 'virtuser_file';"
    } >> "$cfg"
    ok "Roundcube virtuser_file plugin enabled."
  fi

  # --- des_key: the session encryption key ---
  #
  # Roundcube encrypts the user's IMAP PASSWORD in the session with this key,
  # and its default is a fixed, publicly known string. Roundcube's own web
  # installer would generate a random one, but Virtualmin never runs that
  # installer and its script never touches des_key, so the default survives.
  #
  # 24 characters, letters and digits only: the default cipher needs that
  # length, and no quote or backslash may end up inside a PHP string.
  #
  # The current value is read by taking the LAST assignment (as PHP would),
  # after dropping comment lines.
  local cur_key
  cur_key="$(grep 'des_key' "$cfg" | grep -v '^[[:space:]]*//' |
             sed -n "s/.*= *'\(.*\)';.*/\1/p" | tail -1)"
  if [ -n "$cur_key" ] && [ "$cur_key" != "rcmail-!24ByteDESkey*Str" ]; then
    # Someone (or an earlier run) already set one. Writing a new key every run
    # would drop every active session.
    ok "Roundcube session key is already private."
  else
    local newkey
    # '|| true' is required: head exits after 24 bytes, tr then dies of SIGPIPE
    # and pipefail would report failure even though the value is correct.
    newkey="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24 || true)"
    if [ "${#newkey}" -ne 24 ]; then
      warn "Could not generate a random key; Roundcube des_key left at its default."
    else
      {
        echo
        echo "// vmin-kit: key that encrypts the IMAP password in the session."
        echo "// Roundcube's default is fixed and publicly known."
        echo "\$config['des_key'] = '$newkey';"
      } >> "$cfg"
      ok "Roundcube session key replaced with a random value."
    fi
  fi

  # --- remove the setup wizard ---
  #
  # Roundcube keeps the wizard in <root>/installer with a front controller at
  # <root>/public_html/installer.php. enable_installer defaults to false, so it
  # refuses to run, but Roundcube's own advice is to delete it after setup -
  # and then the setting cannot be turned on by accident.
  #
  # A script upgrade re-extracts the tarball and can bring it back, so this
  # block is repeatable: re-running install.sh is enough.
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    local removed=0
    if [ -e "$dir/installer" ]; then rm -rf "$dir/installer"; removed=1; fi
    if [ -e "$dir/public_html/installer.php" ]; then
      rm -f "$dir/public_html/installer.php"; removed=1
    fi
    if [ "$removed" = 1 ]; then
      ok "Roundcube setup wizard removed."
    else
      ok "Roundcube setup wizard is already gone."
    fi
  fi

  # A missing certificate fails this step: Roundcube is installed, but nobody
  # reads mail from an address the browser does not trust.
  [ "${VMINKIT_SITE_CERT[${WEBMAIL_PREFIX:-webmail}]:-1}" = "0" ] && return 1
  return 0
}

# The docker.<domain> sub-server and its proxy to Portainer.
# The feature list is the minimum a reverse proxy needs; see ensure_proxy_site.
step_docker_site(){
  local prefix="${DOCKER_PREFIX:-docker}" port="${PORTAINER_PORT:-9000}"
  ensure_proxy_site "$prefix" "http://127.0.0.1:${port}/" "Portainer (vmin-kit)" || return 1

  # Portainer's 9000 follows the SAME rule as Webmin and Usermin: the port is
  # closed only when the proxy address has a certificate a browser will trust,
  # so there is never a moment with no way in at all.
  #
  # A user who set PORTAINER_BIND_LOCAL=no opened it deliberately; the
  # certificate state does not override that.
  [ "${PORTAINER_BIND_LOCAL:-yes}" = "yes" ] || return 0

  if site_cert_ok "$prefix"; then
    portainer_set_publish "127.0.0.1:${port}:9000"
    return
  fi
  warn "Portainer ${port} left open: ${prefix}.${MAIN_DOMAIN} has no certificate."
  portainer_set_publish "${port}:9000"
  return 1   # missing certificate: count the step as failed so it is visible
}

# Webmin and Usermin compare the request's Referer against the Host AND PORT
# they see. Behind the proxy the referer is https://webmin.<domain> (port 443)
# while the interface's own port is 10000, so the check fails and the request
# is refused with a "Security Warning" page.
#
# The fix is the panel's own: add the address to the trusted referrers list
# (Webmin Configuration -> Trusted Referrers). The file is re-read on every
# request, so no restart is needed.
add_trusted_referer(){
  local conf="$1" site="$2" cur
  [ -f "$conf" ] || return 0
  cur="$(awk -F= '/^referers=/{sub(/^referers=/,""); print; exit}' "$conf")"
  case " $cur " in
    *" $site "*) ok "  Trusted address already registered: $site"; return 0 ;;
  esac
  [ -f "${conf}.vmin-kit.bak" ] || cp -a "$conf" "${conf}.vmin-kit.bak"
  set_kv "$conf" referers "$(echo "$cur $site" | xargs)"
  ok "  Trusted address added: $site"
}


# Behind the proxy the interface must know its EXTERNAL port: its own is 10000
# but requests arrive on 443, and miniserv builds the list of allowed websocket
# origins from that. Without it the browser sends https://webmin.<domain> while
# miniserv expects https://webmin.<domain>:10000 and answers "403 Invalid
# Websockets origin" - which breaks the theme's dashboard, file manager and
# terminal.
#
# The host name is not written: with redirect_host empty miniserv uses the
# incoming Host header, which ProxyPreserveHost already makes correct.
set_panel_external_port(){
  local name="$1" conf="$2" svc="$3"
  [ -f "$conf" ] || return 0
  if [ "$(sed -n 's/^redirect_port=//p' "$conf" | head -1)" = "443" ]; then
    ok "  $name external port is already declared (443)."
    return 0
  fi
  [ -f "${conf}.vmin-kit.bak" ] || cp -a "$conf" "${conf}.vmin-kit.bak"
  set_kv "$conf" redirect_port "443"
  systemctl restart "$svc" >/dev/null 2>&1 || warn "  Could not restart $svc."
  ok "  $name external port declared as 443 (for websocket origins)."
}

# The management interfaces are published as sub-domains of the main domain,
# so no management port has to stay open. Closing the ports is a separate step
# (step_lock_panel_ports) that first verifies the proxy works.
step_panel_sites(){
  local wport uport
  wport="$(awk -F= '/^port=/{print $2; exit}' /etc/webmin/miniserv.conf 2>/dev/null)"
  wport="${wport:-10000}"
  ensure_proxy_site "${WEBMIN_PREFIX:-webmin}" "https://127.0.0.1:${wport}/" \
                    "Webmin (vmin-kit)" phost
  add_trusted_referer /etc/webmin/config "${WEBMIN_PREFIX:-webmin}.${MAIN_DOMAIN}"
  set_panel_external_port "Webmin" /etc/webmin/miniserv.conf webmin

  if [ -f /etc/usermin/miniserv.conf ]; then
    uport="$(awk -F= '/^port=/{print $2; exit}' /etc/usermin/miniserv.conf 2>/dev/null)"
    uport="${uport:-20000}"
    ensure_proxy_site "${USERMIN_PREFIX:-usermin}" "https://127.0.0.1:${uport}/" \
                      "Usermin (vmin-kit)" phost
    add_trusted_referer /etc/usermin/config "${USERMIN_PREFIX:-usermin}.${MAIN_DOMAIN}"
    set_panel_external_port "Usermin" /etc/usermin/miniserv.conf usermin
  else
    log "Usermin is not installed; skipping usermin.<domain>."
  fi

  # A missing certificate fails this step: the site and the proxy work, but the
  # intended result - a panel address the browser trusts - was not reached, and
  # the management port therefore stayed open.
  local p rc=0
  for p in "${WEBMIN_PREFIX:-webmin}" "${USERMIN_PREFIX:-usermin}"; do
    [ "${VMINKIT_SITE_CERT[$p]:-1}" = "0" ] && rc=1
  done
  return "$rc"
}

# Binds the management ports to 127.0.0.1 only.
#
# A DANGEROUS step: afterwards the panel is reachable only through the proxy.
# So the proxy is verified first, and if that fails the port is left open with
# instructions for doing it by hand.
#
# The interface keeps its own SSL and the proxy talks https to it, so Webmin
# still considers itself secure and emits https links.
lock_panel_port(){
  local name="$1" conf="$2" svc="$3" prefix="$4"
  [ -f "$conf" ] || { log "  $name is not installed, skipping."; return 0; }

  if [ "$(awk -F= '/^bind=/{print $2; exit}' "$conf")" = "127.0.0.1" ]; then
    ok "$name already listens on 127.0.0.1 only."
    return 0
  fi

  if ! proxy_site_works "$prefix"; then
    warn "$name not locked: the ${prefix}.${MAIN_DOMAIN} proxy could not be verified."
    warn "  Once the proxy works: add bind=127.0.0.1 to $conf and restart $svc"
    return 1
  fi

  # Second condition: the sub-domain must have a valid certificate.
  #
  # A responding proxy is not enough - curl is given -k and a self-signed
  # certificate still returns 200, while a browser refuses, and with HSTS in
  # play there is not even a "continue anyway" option. Closing the port at that
  # moment leaves no way in at all.
  #
  # So a missing certificate leaves the port OPEN. An open port is a known
  # state that the summary reports; a closed one locks the user out of their
  # own server.
  if ! site_cert_ok "$prefix"; then
    warn "$name port left open: ${prefix}.${MAIN_DOMAIN} has no certificate."
    return 0
  fi

  [ -f "${conf}.vmin-kit.bak" ] || cp -a "$conf" "${conf}.vmin-kit.bak"
  set_kv "$conf" bind "127.0.0.1"
  systemctl restart "$svc" >/dev/null 2>&1 || warn "  Could not restart $svc."
  ok "$name listens on 127.0.0.1 only -> https://${prefix}.${MAIN_DOMAIN}/"
}

step_lock_panel_ports(){
  lock_panel_port "Webmin"  /etc/webmin/miniserv.conf  webmin  "${WEBMIN_PREFIX:-webmin}"
  lock_panel_port "Usermin" /etc/usermin/miniserv.conf usermin "${USERMIN_PREFIX:-usermin}"
}

step_docker(){
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then ok "Docker is already installed (skipping)."; return; fi
  local pkg
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then log "Removing conflicting package: $pkg"; apt-get remove -y "$pkg" || true; fi
  done
  apt-get update; apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  # Docker's repository is per distribution: .../linux/debian and
  # .../linux/ubuntu are separate trees and neither carries the other's
  # codenames. So the distribution and codename are read from /etc/os-release
  # rather than hard-coded.
  local os_id code arch
  os_id="$(. /etc/os-release && echo "${ID:-debian}")"
  code="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  arch="$(dpkg --print-architecture)"
  case "$os_id" in
    debian|ubuntu) ;;
    *) warn "Unknown distribution for the Docker repository ($os_id); assuming debian."
       os_id=debian ;;
  esac
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${code} stable" > /etc/apt/sources.list.d/docker.list
  fi
  apt-get update; apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  if docker run --rm hello-world >/dev/null 2>&1; then ok "Docker installed ($(docker --version))."; else err "The Docker hello-world test failed."; return 1; fi
}

step_portainer(){
  command -v docker >/dev/null 2>&1 || { err "Docker missing; skipping Portainer."; return 1; }
  local image="${PORTAINER_IMAGE:-portainer/portainer-ce:lts}" port="${PORTAINER_PORT:-9000}" pub
  if [ "${PORTAINER_BIND_LOCAL:-yes}" = "yes" ]; then pub="127.0.0.1:${port}:9000"; else pub="${port}:9000"; fi
  if docker ps -a --format '{{.Names}}' | grep -x portainer >/dev/null; then
    if docker ps --format '{{.Names}}' | grep -x portainer >/dev/null; then ok "Portainer is already running (skipping)."; return; fi
    docker start portainer >/dev/null; ok "Portainer started."; return
  fi
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  # Pull the image separately so a missing tag (if 'lts' ever disappears) is
  # seen explicitly and can fall back to 'latest', rather than docker run
  # failing with something cryptic.
  if ! docker pull "$image" >/dev/null 2>&1; then
    warn "Could not pull the image: $image"
    if [ "$image" != "portainer/portainer-ce:latest" ] &&
       docker pull portainer/portainer-ce:latest >/dev/null 2>&1; then
      warn "Continuing with portainer/portainer-ce:latest."
      image="portainer/portainer-ce:latest"
    else
      err "Could not download a Portainer image."; return 1
    fi
  fi
  portainer_run "$pub" "$image" || return 1
  ok "Portainer running -> $pub"
}

# portainer_run <publish> <image>
# The ONLY place the container is created. Two callers (first install and a
# publish change); duplicating the command would let them drift apart.
portainer_run(){
  docker run -d --name portainer --restart=always -p "$1" \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data "$2" >/dev/null
}

# portainer_set_publish <publish>  e.g. "127.0.0.1:9000:9000" or "9000:9000"
#
# Docker cannot change a running container's published ports, so the container
# is removed and recreated. State lives in the portainer_data volume, so the
# admin account and settings survive.
#
# Does nothing when the container is already published as wanted: on a clean
# install it is created once and never touched again.
portainer_set_publish(){
  local want="$1" cur expect image
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x portainer >/dev/null || return 0

  # "127.0.0.1:9000:9000" -> "127.0.0.1:9000" ; "9000:9000" -> "0.0.0.0:9000"
  expect="${want%:9000}"
  case "$expect" in
    *:*) ;;
    *)   expect="0.0.0.0:$expect" ;;
  esac
  # 'docker port' can print two lines (0.0.0.0 and [::]); the first is enough.
  # Trimmed with parameter expansion rather than 'head -1', which can kill the
  # producer with SIGPIPE and read as a false negative under pipefail.
  cur="$(docker port portainer 9000/tcp 2>/dev/null || true)"
  cur="${cur%%$'\n'*}"
  cur="${cur%$'\r'}"
  [ "$cur" = "$expect" ] && return 0

  log "Changing the Portainer publish address: ${cur:-none} -> $expect"
  image="$(docker inspect -f '{{.Config.Image}}' portainer 2>/dev/null || true)"
  [ -n "$image" ] || image="${PORTAINER_IMAGE:-portainer/portainer-ce:lts}"
  docker rm -f portainer >/dev/null 2>&1 || true
  if portainer_run "$want" "$image"; then
    ok "Portainer published on: $expect"
  else
    err "Could not recreate Portainer."
    return 1
  fi
}

# Plugins: build the packages and install them Webmin's OWN way.
#
# install-module.pl replaces the old copy, checks module.info's depends=,
# grants access in webmin.acl, merges the module config (keeping existing
# values) and runs postinstall.pl -> module_install(), which is where the
# Cloudflare plugin installs its systemd units.
#
# The one thing it does not do is add the module to Virtualmin's 'plugins='
# list - that is Virtualmin-specific, and real Virtualmin plugins do not
# self-register either - so we do it.
#
# Flags come from config.env (PLUGIN_DEPLOY, PLUGIN_COMPOSER,
# PLUGIN_CLOUDFLARE, default 1). 0 means "do not install"; it never uninstalls
# a working plugin because a flag changed. To remove: ./update-plugins.sh --remove
plugin_flag(){   # vmkit-deploy -> PLUGIN_DEPLOY
  printf 'PLUGIN_%s' "$(printf '%s' "${1#vmkit-}" | tr '[:lower:]-' '[:upper:]_')"
}

plugin_enabled(){
  local var; var="$(plugin_flag "$1")"
  is_truthy "${!var:-1}"
}

# The list shown on the summary screen.
plugin_list_enabled(){
  local dir mod out=""
  for dir in "$ROOT_DIR"/plugin/*/; do
    [ -f "${dir}module.info" ] || continue
    mod="$(basename "$dir")"
    plugin_enabled "$mod" && out="$out ${mod#vmkit-}"
  done
  printf '%s' "${out:- (none)}"
}

step_plugins(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin missing; skipping plugins."; return 1; }
  local wroot im
  wroot="$(webmin_root)"
  im="$wroot/install-module.pl"
  [ -r "$im" ] || { err "Webmin's install-module.pl is missing: $im"; return 1; }

  local dir mod pkg any=0 skipped=""
  for dir in "$ROOT_DIR"/plugin/*/; do
    [ -f "${dir}module.info" ] || continue
    mod="$(basename "$dir")"
    if ! plugin_enabled "$mod"; then
      skipped="$skipped $mod"
      continue
    fi

    # Build the package from source at install time, so it can never be stale.
    # Called through 'bash' because git does not carry the execute bit in every
    # environment (core.filemode=false on Windows).
    if ! bash "$ROOT_DIR/build-plugins.sh" "$mod" >/dev/null; then
      err "  Could not package $mod."; continue
    fi
    pkg="$ROOT_DIR/dist/$mod.wbm.gz"

    # Through perl, not directly: its shebang is /usr/local/bin/perl.
    if perl "$im" --acl root "$pkg" >/dev/null 2>&1; then
      log "  installed: $mod"
    else
      err "  Could not install $mod (install-module.pl)."
      continue
    fi
    plugins_add "$mod" || true
    any=1
  done

  [ -n "$skipped" ] && log "  skipped (flag is 0):$skipped"

  if [ "$any" = 1 ]; then
    if clear_links_cache; then :; else
      warn "  Could not clear the menu cache; save a domain if changes do not appear."
    fi
    systemctl restart webmin 2>/dev/null || warn "  Could not restart webmin."
    ok "Plugins installed. In the panel: System Settings -> Features and Plugins."
  else
    ok "No plugins to install."
  fi
}

# Installation summary: what this server is, its addresses, what is exposed.
#
# A STATUS SCREEN, NOT A MANUAL. Anything that reads as advice belongs in the
# README; this prints facts, plus at most a couple of short reminders.
#
# Written to the screen and to the install log; there is no separate report file.
step_report(){
  local ip dfeat dplug dinfo cmp

  ip="$(detect_ip)"

  # Only components that EXIST are listed. Counting absent things just makes
  # the summary longer, and no status word is needed: if it is in the list,
  # it is there.
  local -a comps=()
  command -v psql >/dev/null 2>&1 && comps+=("PostgreSQL")
  command -v docker >/dev/null 2>&1 && comps+=("Docker")
  docker ps --format '{{.Names}}' 2>/dev/null | grep -x portainer >/dev/null &&
    comps+=("Portainer")
  if command -v composer >/dev/null 2>&1; then
    # Composer'i dagitim paketinden kuruyoruz: kendini guncelleyemez. Yeni
    # cerceveler daha yeni bir composer isterse cevap burada gorunur.
    #
    # SABIT ALAN NUMARASI KULLANILMIYOR: eskiden $3 aliniyordu ve Ubuntu
    # 22.04'te ozette surum yerine "2022-02-04" yazdi - o satirda alan sirasi
    # beklenenden bir kaymis. Surum numarasina benzeyen ILK alan aliniyor.
    #
    # awk erken 'exit' etmiyor: girdiyi bitirmeden kapatsaydi composer
    # SIGPIPE alir, 'pipefail' altinda atama basarisiz olurdu.
    cmp="$(composer --version --no-interaction 2>/dev/null |
           awk 'NR==1{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+/){v=$i; break}}
                END{print v}')"
    comps+=("Composer ${cmp:-}")
  fi

  # Domain bilgisi TEK cagrida aliniyor; iki alan bu ciktidan ayikleniyor
  # (eskiden ayni komut dort kez calisiyordu).
  dinfo="$(virtualmin list-domains --domain "$MAIN_DOMAIN" --multiline 2>/dev/null)"
  # Hangi ozelliklerin acildigini Virtualmin'in kendisinden okuyoruz: domain
  # --default-features ile olusturuldugu icin liste sunucunun kendi
  # yapilandirmasindan geliyor, varsayimda bulunmuyoruz.
  dfeat="$(printf '%s\n' "$dinfo" | awk -F": " '/^[[:space:]]*Features:/{print $2; exit}')"
  dplug="$(printf '%s\n' "$dinfo" | awk -F": " '/^[[:space:]]*Plugins:/{print $2; exit}')"

  say ""
  say "=========== vmin-kit kurulum ozeti ==========="
  say "Tarih        : $(date '+%Y-%m-%d %H:%M:%S %z')"
  say "Arac surumu  : $(vminkit_version)"
  say "Ana domain   : $MAIN_DOMAIN"
  say "Hostname     : $HOSTNAME_FQDN  (${ip:-IP bilinmiyor})"
  # Mod ETIKETIN ICINDE: "DNS (harici)" / "DNS (bind)". Degeri satirin
  # sagina yazmak yerine boyle daha kisa ve sutun hizasi bozulmuyor -
  # etiketler 12 karaktere yaslaniyor.
  local dnslabel
  if [ -n "${DNS_MODE:-}" ] && [ "$DNS_MODE" != bilinmiyor ]; then
    dnslabel="DNS ($DNS_MODE)"
  else
    dnslabel="DNS"
  fi
  say "$(printf '%-12s : %s' "$dnslabel" "${AUTH_NS:-bilinmiyor}")"
  say "               zone sablonundaki cift: ${NS1:-} / ${NS2:-}"
  if [ -n "$dfeat" ]; then say "Ozellikler   : $dfeat"; fi
  if [ -n "$dplug" ]; then say "Eklentiler   : $dplug"; fi
  # Elle birlestiriliyor: 'IFS=" | "' ile "${comps[*]}" ISE YARAMAZ, bash
  # IFS'in yalnizca ILK karakterini ayirici olarak kullanir (yani bosluk).
  if [ ${#comps[@]} -gt 0 ]; then
    local joined="" c
    for c in "${comps[@]}"; do
      if [ -z "$joined" ]; then joined="$c"; else joined="$joined | $c"; fi
    done
    say "Bilesenler   : $joined"
  fi

  # Adim ADI yazilmiyor: 'panel_sites' fonksiyon adi, okuyan icin bir sey
  # ifade etmiyor. Sorunun ne oldugu zaten yukarida kendi satirinda yaziyor;
  # burada tek is "her sey yolunda gitmedi" bayragini kaldirmak.
  if [ ${#VMINKIT_FAILED[@]} -gt 0 ]; then
    say ""
    warn "Eksik tamamlandi - sorunlar yukarida [!] ile isaretli."
  fi

  say ""
  say "Adresler"
  say "  Site       : https://${MAIN_DOMAIN}"
  if [ "$(awk -F= '/^bind=/{print $2; exit}' /etc/webmin/miniserv.conf 2>/dev/null)" = "127.0.0.1" ]; then
    say "  Panel      : https://${WEBMIN_PREFIX:-webmin}.${MAIN_DOMAIN}/"
  else
    say "  Panel      : https://${HOSTNAME_FQDN}:10000"
  fi
  if is_truthy "${ROUNDCUBE:-0}"; then
    say "  Webmail    : https://${WEBMAIL_PREFIX:-webmail}.${MAIN_DOMAIN}/"
  fi
  if is_truthy "${DOCKER:-0}"; then
    say "  Portainer  : https://${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}/"
  fi

  # Disariya acik dinleyen portlar. Guvenlik duvarini bu arac yonetmiyor;
  # en azindan sonucun ne oldugu gorunsun - 10000/20000 burada gorunuyorsa
  # kilitleme adimi calismamis demektir.
  #
  # SUREC ADIYLA: yalniz port numarasi "bu da neyin nesi" sorusunu cevapsiz
  # birakiyordu. '-p' surec adini veriyor (root oldugumuz icin gorunuyor).
  #
  # Boru hatti dogrudan yazmiyor, once degiskene aliniyor: 'say' disindaki
  # her cikti yalnizca log dosyasina gider, ekranda gorunmezdi.
  if command -v ss >/dev/null 2>&1; then
    local portlist
    portlist="$(ss -ltnpH 2>/dev/null | awk '
      {
        addr = $4
        # Yalnizca yerel dinleyenler bizi ilgilendirmiyor.
        #
        # TUM 127.0.0.0/8 eleniyor, yalnizca 127.0.0.1 degil: systemd-resolved
        # "127.0.0.53%lo" ve "127.0.0.54" uzerinde dinliyor. Dar suzgec bunu
        # "disariya acik" gosteriyor, ustelik ayni porttaki GERCEK dinleyiciyi
        # (named) de gizliyordu - temiz kurulumda "53 systemd-resolve" diye
        # cikti, oysa dogrusu "53 named". Gercek 'ss' ciktisiyla dogrulandi.
        #
        # fe80::/10 de eleniyor: baglanti-yerel adresler yalnizca ayni ag
        # segmentinden erisilebilir, "disariya acik" sayilmaz. named her
        # arayuz icin bir tane aciyor (ens192, docker0, veth...).
        #
        # Docker koprusu (172.17.x) BILEREK eleniyor DEGIL: oradan bir
        # konteyner erisebilir, yani gercek bir yol.
        if (addr ~ /^127\./ || addr ~ /^\[::1\]:/ || addr ~ /^\[[Ff][Ee]80:/) next
        n = split(addr, a, ":")
        port = a[n]
        # users:(("ad",pid=...  -> ad. Onek 9 karakter, kapanis tirnagi 1.
        name = "?"
        if (match($0, /users:\(\("[^"]+"/)) {
          name = substr($0, RSTART + 9, RLENGTH - 10)
        }
        # Ayni port hem IPv4 hem IPv6 icin gorunuyor; bir kez yazalim.
        if (!(port in seen) || seen[port] == "?") seen[port] = name
      }
      END { for (p in seen) printf "%s %s\n", p, seen[p] }
    ' | sort -n -u | awk '
      { rows[NR] = sprintf("%5s  %-18s", $1, $2) }
      END {
        # Iki sutun: liste uzun, tek sutunda raporu gereksiz uzatiyor.
        half = int((NR + 1) / 2)
        for (i = 1; i <= half; i++) {
          line = sprintf("  %s%s", rows[i], (i + half <= NR ? rows[i + half] : ""))
          sub(/[ \t]+$/, "", line)   # sagda bosluk birakma
          print line
        }
      }
    ')"
    say ""
    say "Dinleyen portlar (yerel olmayan adreslerde)"
    if [ -n "$portlist" ]; then
      say "$portlist"
    else
      # 'ss' var ve calisti; bos sonuc "okunamadi" degil "hicbiri" demek.
      say "  (yok - yalnizca 127.0.0.1 uzerinde dinleyenler var)"
    fi
    # GUVENLIK DUVARI DURUMU BURADA RAPORLANMIYOR - bilerek.
    #
    # Bir sure "nftables kural seti yuklu/bos" diye bir satir vardi ve iki
    # sekilde birden yanlisti:
    #
    #   1) KAPSAM DISI. Bu bir kurulum araci; "hangi portlar dinliyor" bir
    #      olgu, "guvenlik duvari ne durumda" ise ayri bir konu ve henuz
    #      incelemedigimiz bir sey hakkinda yorum yapmis oluyorduk.
    #
    #   2) OLCUM DE YANLISTI. 'nft list ruleset | grep -q ...' kaliyordu:
    #      grep ilk eslesmede cikinca nft SIGPIPE ile 141 donuyor ve
    #      'set -o pipefail' bunu tum boru hattinin hatasi sayiyor - kural
    #      seti DOLUYKEN "BOS" yaziyordu. (Kucuk ciktilarda uremiyor, boru
    #      arabellegine sigiyor; gercek nft ciktisi sigmiyor.)
    #
    # Gerektiginde guvenlik duvari yapilandirmasi ayri bir adim olarak
    # eklenir; o zamana kadar burada yalnizca dinleyen soketler yaziyor.
  fi

  # NOTLAR: yalnizca ILERIDE YAPILACAK, kendiliginden olmayacak seyler.
  # Nasil yapilacagi README'de; burada sadece hatirlatma.
  say ""
  say "Notlar"
  say "  - Domain sahibi sifresi saklanmadi; gerekirse panelden belirleyin."
  case " $dfeat " in
    *" mail "*)
      say "  - DMARC 'p=none' ile basliyor; birkac hafta sonra quarantine'e cekin."
      ;;
  esac
  # Harici DNS icin ayrica bir hatirlatma YOK: Cloudflare senkron eklentisi
  # tam da bu is icin var, yani "A kaydini saglayicida da ac" demek hem
  # gereksiz hem de kendi aracimizin yaptigi isi bilmiyormus gibi duruyor.
  if [ "${DNS_MODE:-}" = bind ]; then
    say "  - Registrar'da ${NS1:-ns1} / ${NS2:-ns2} icin glue kaydi: ${ip:-<sunucu-ip>}"
  fi
  say "  - Ayrinti ve sorun giderme: README.md"
  say ""

  # Ikinci sunucu icin ayrica bir cevap dosyasi URETMIYORUZ: ayarlar zaten
  # depodaki config.env icinde duruyor. Yeni sunucuda depoyu cekip ana
  # domaini yazmak yeterli.
}
