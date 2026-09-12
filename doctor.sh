#!/usr/bin/env bash
# doctor.sh - verifies vmin-kit's DEPENDENCIES on Virtualmin.
#
#   sudo ./doctor.sh
#
# WHY IT EXISTS
# This tool uses Virtualmin's internal functions, CLI commands and config keys,
# none of which promise a stable interface. If an upgrade renames one, a plugin
# page returns 500 or - worse - an install step silently succeeds while doing
# nothing at all.
#
# So the check runs ON DEMAND rather than during the install: the risk appears
# AFTER an upgrade, and at install time everything was working.
#
# THE LISTS ARE NOT MAINTAINED BY HAND. A hand-written list rots within months:
# we start using a new function, doctor does not know about it and reports
# "all fine" for nothing. The dependencies are EXTRACTED FROM THE SOURCE on
# every run instead.
#
# Exit code: 0 = everything in place, 1 = something is missing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
require_root

WEBMIN_ROOT="$(webmin_root)"
VS_DIR="$WEBMIN_ROOT/virtual-server"
[ -d "$VS_DIR" ] || { err "Virtualmin not found: $VS_DIR"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MISSING=0

# ---------------------------------------------------------------------------
# 1) PERL SYMBOLS
#
# The plugins reach Virtualmin through the 'virtual_server::' and 'bind8::'
# prefixes, which makes them easy to extract. install.sh's embedded perl blocks
# call without a prefix ('&check_dkim()'); bash has no '&name(' syntax, so any
# line matching that pattern is embedded perl.
# ---------------------------------------------------------------------------
log "Extracting dependencies from the source..."

# NON-CODE LINES ARE FILTERED OUT. Both sources actually happened:
#
#   - COMMENTS: describing a removed call in a comment made doctor believe we
#     still used it.
#
#   - OUR OWN MESSAGES: text inside log/ok/warn/err/say was taken for a command.
#     A line reading 'log "... virtualmin install.sh ..."' invented a CLI
#     command called "virtualmin install" and doctor reported it missing. These
#     functions never run commands, so their lines hold no dependency.
code_lines(){
  grep -rhv -e '^[[:space:]]*#' -e '^[[:space:]]*\(log\|ok\|warn\|err\|say\)[[:space:]]' \
    "$@" 2>/dev/null || true
}

# sigil + paket + isim
code_lines "$ROOT_DIR/plugin" \
  | grep -oE '[&$@%](virtual_server|bind8|acl)::[a-zA-Z_0-9]+' \
  | sed -E 's/^(.)([a-z8_]+)::(.*)$/\1\t\2\t\3/' \
  | sort -u > "$TMP/symbols"

# The install side: prefix-less embedded perl calls. Some come from Webmin's
# core (lock_file), some from Virtualmin; both are searched in the same place,
# so they are not separated.
code_lines "$ROOT_DIR/lib" "$ROOT_DIR/install.sh" \
  | grep -oE '&[a-z_][a-z_0-9]*\(' \
  | sed 's/($//; s/(//; s/^&//' \
  | sort -u | sed 's/^/\&\tmain\t/' >> "$TMP/symbols"

sort -u -o "$TMP/symbols" "$TMP/symbols"
SYM_COUNT="$(wc -l < "$TMP/symbols")"

# ---------------------------------------------------------------------------
# 2) CLI COMMANDS
#
# Virtualmin's 'virtualmin <cmd>' dispatcher maps the command to '<cmd>.pl' in
# the module directory, so checking that the file exists is the right test.
# ---------------------------------------------------------------------------
code_lines "$ROOT_DIR/lib" "$ROOT_DIR"/*.sh \
  | grep -oE '\bvirtualmin [a-z][a-z-]+' \
  | sed 's/^virtualmin //' | sort -u > "$TMP/commands"
CMD_COUNT="$(wc -l < "$TMP/commands")"

# ---------------------------------------------------------------------------
# 3) CONFIG KEYS
#
# We have four writing patterns and all four are scanned. What is maintained by
# hand here is the PATTERNS, not the key list - a new writing pattern needs a
# line added.
#
# WHICH FILE a key is written to is deliberately ignored. Some go to
# Virtualmin's config, some to miniserv.conf ('redirect_port', 'referers'), and
# telling them apart from bash source proved fragile - it was tried and raised
# false alarms by looking for miniserv keys in Virtualmin's source. Every
# component we touch is searched instead; the question is only "is this name
# still recognised". Writing a removed key raises no error and silently does
# nothing, which is exactly what this is meant to catch.
#
# Names shorter than three characters are dropped: sed expressions produce
# false matches like 's', and none of our keys are that short.
# ---------------------------------------------------------------------------
# Each pattern is handled SEPARATELY and reduced to the key name. One big sed
# expression was tried and proved fragile ('{' is special in ERE).
{
  # set_kv "$cfg" <key> ...   /   set_kv "$conf" <key> ...
  grep -rhoE 'set_kv "\$[a-z]+" [a-z_][a-z_0-9]*' "$ROOT_DIR/lib" \
    | awk '{ print $NF }' || true
  # for row in "<key>|value|label"
  grep -rhoE '"[a-z_][a-z_0-9]*\|' "$ROOT_DIR/lib" | tr -d '"|' || true
  # sed 's/^<key>=//' and awk '/^<key>=/' - both contain '^<name>='
  grep -rhoE '\^[a-z_][a-z_0-9]*=' "$ROOT_DIR/lib" | tr -d '^=' || true
  # embedded perl: $config{<key>} or $config{'<key>'}
  grep -rhoE '\$config\{[^}]*\}' "$ROOT_DIR/lib" \
    | sed "s/.*[{]//; s/[}]//; s/'//g" || true
} | grep -E '^[a-z_][a-z_0-9]{2,}$' | sort -u > "$TMP/keys"
KEY_COUNT="$(wc -l < "$TMP/keys")"

# UNIQUE names: the three plugins define the same hooks separately, but what is
# verified is the name itself.
HOOK_COUNT="$(grep -hoE '^sub feature_[a-z_0-9]+' "$ROOT_DIR"/plugin/*/virtual_feature.pl \
  | sort -u | wc -l)"
log "Found: $SYM_COUNT perl symbols, $CMD_COUNT CLI commands, $KEY_COUNT config keys, $HOOK_COUNT hook names"
echo

# ---------------------------------------------------------------------------
# 4) VERIFY THE PERL SYMBOLS
#
# virtual-server-lib.pl is loaded directly, so its functions land in 'main::'.
# The plugins see them under 'virtual_server::' through foreign_require, but
# the NAME SET is the same - "does this function still exist" has the same
# answer either way.
#
# For non-functions (%text, @plugins) the symbol table is consulted: an array
# may legitimately be empty, so 'defined' would be the wrong test.
# ---------------------------------------------------------------------------
log "Verifying perl symbols..."
# The program is written to a SEPARATE FILE: 'perl - <list <<PERL' does not
# work, because 'perl -' reads the program from stdin too and the two streams
# collide - the list would never be read.
cat > "$TMP/check.pl" <<'PERL'
my ($root) = @ARGV;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
push(@INC, $root);
$main::no_acl_check++;
chdir("$root/virtual-server");
$0 = "$root/virtual-server/doctor.pl";
require "./virtual-server-lib.pl";
eval { &foreign_require("bind8"); };
eval { &foreign_require("acl", "acl-lib.pl"); };

while(my $l = <STDIN>) {
	chomp($l);
	my ($sigil, $pkg, $name) = split(/\t/, $l);
	next if (!$name);
	# The plugins' 'virtual_server::' and 'main::' here are the same set;
	# other modules are checked in their own package.
	my $p = $pkg eq 'virtual_server' || $pkg eq 'main' ? 'main' : $pkg;
	my $ok;
	if ($sigil eq '&') {
		no strict 'refs';
		$ok = defined(&{"${p}::${name}"}) ? 1 : 0;
		}
	else {
		no strict 'refs';
		$ok = exists ${"${p}::"}{$name} ? 1 : 0;
		}
	print(($ok ? "OK" : "MISSING"), "\t", $sigil, $pkg, "::", $name, "\n");
	}
PERL
perl "$TMP/check.pl" "$WEBMIN_ROOT" < "$TMP/symbols" > "$TMP/symres"

while IFS=$'\t' read -r state sym; do
  if [ "$state" = "MISSING" ]; then err "missing: $sym"; MISSING=$((MISSING + 1)); fi
done < "$TMP/symres"
GOOD="$(grep -c '^OK' "$TMP/symres" || true)"
ok "$GOOD symbols in place"
echo

# ---------------------------------------------------------------------------
# 5) VERIFY THE CLI COMMANDS
# ---------------------------------------------------------------------------
log "Verifying CLI commands..."
CMD_OK=0
while read -r cmd; do
  [ -n "$cmd" ] || continue
  if [ -r "$VS_DIR/$cmd.pl" ]; then
    CMD_OK=$((CMD_OK + 1))
  else
    err "missing command: virtualmin $cmd  (no $VS_DIR/$cmd.pl)"
    MISSING=$((MISSING + 1))
  fi
done < "$TMP/commands"
ok "$CMD_OK CLI commands in place"
echo

# ---------------------------------------------------------------------------
# 6) VERIFY THE CONFIG KEYS
# ---------------------------------------------------------------------------
log "Verifying config keys..."
KEY_OK=0
# The components we touch: Virtualmin, miniserv itself, the Webmin module and
# BIND. Which one a key belongs to does not matter here.
KEY_SEARCH=( "$VS_DIR"/*.pl "$WEBMIN_ROOT"/*.pl )
[ -d "$WEBMIN_ROOT/webmin" ] && KEY_SEARCH+=( "$WEBMIN_ROOT"/webmin/*.pl )
[ -d "$WEBMIN_ROOT/bind8" ]  && KEY_SEARCH+=( "$WEBMIN_ROOT"/bind8/*.pl )
while read -r key; do
  [ -n "$key" ] || continue
  if grep -qE "\b$key\b" "${KEY_SEARCH[@]}" 2>/dev/null; then
    KEY_OK=$((KEY_OK + 1))
  else
    warn "key does not appear in the Virtualmin source: $key"
    MISSING=$((MISSING + 1))
  fi
done < "$TMP/keys"
ok "$KEY_OK config keys in place"
echo

# ---------------------------------------------------------------------------
# 7) PLUGIN HOOKS - the side of the contract that CALLS US
#
# The sections above check what we ask of Virtualmin. This one checks the
# reverse: does Virtualmin still call the feature_* hooks we implement?
#
# A renamed or removed hook raises NO ERROR at all - our function just sits
# there, never called. The feature silently fails to set up, the backup is
# silently not taken. It is the hardest kind of breakage to notice.
#
# The test is that the hook name appears QUOTED in Virtualmin's source.
# Matching the call syntax ('plugin_call($f, "feature_x"') was tried and was
# NOT enough: some calls span lines and a line-based search misses them -
# feature_restore escaped that way.
# ---------------------------------------------------------------------------
log "Verifying plugin hooks..."
grep -hoE '^sub feature_[a-z_0-9]+' "$ROOT_DIR"/plugin/*/virtual_feature.pl \
  | sed 's/^sub //' | sort -u > "$TMP/hooks_ours"
grep -hoE "['\"]feature_[a-z_0-9]+['\"]" "$VS_DIR"/*.pl "$VS_DIR"/*.cgi 2>/dev/null \
  | tr -d "\"'" | sort -u > "$TMP/hooks_called"

HOOK_OK=0
while read -r h; do
  [ -n "$h" ] || continue
  if grep -qxF "$h" "$TMP/hooks_called"; then
    HOOK_OK=$((HOOK_OK + 1))
  else
    err "Virtualmin never calls this hook: $h"
    MISSING=$((MISSING + 1))
  fi
done < "$TMP/hooks_ours"
ok "$HOOK_OK plugin hooks are called by Virtualmin"
echo

# ---------------------------------------------------------------------------
# 8) THE WEBHOOK'S ANONYMOUS ACCESS
#
# vmkit-deploy lets its hook.cgi through without a login via miniserv's
# 'anonymous' setting (Webmin Configuration -> Anonymous Module Access), tied
# to the plugin's own Webmin user. Three things have to hold: the user exists,
# the user is allowed the module, and the entry is in miniserv.conf. miniserv
# itself would let an unknown user through, so a missing user does not break
# the hook today - it is still reported, because that leniency is not promised.
# ---------------------------------------------------------------------------
if [ -d "$WEBMIN_ROOT/vmkit-deploy" ]; then
  log "Verifying the webhook's anonymous access..."
  WCONF="${WEBMIN_CONFIG:-/etc/webmin}"
  HOOK_USER="vmkit-hook"
  HOOK_ENTRY="/vmkit-deploy/hook.cgi=$HOOK_USER"
  if grep "^${HOOK_USER}:" "$WCONF/miniserv.users" >/dev/null 2>&1; then
    ok "Webmin user exists: $HOOK_USER"
  else
    err "Webmin user missing: $HOOK_USER"; MISSING=$((MISSING + 1))
  fi
  # webmin.acl lines look like "user: mod1 mod2 ..."
  if awk -v u="$HOOK_USER:" '$1 == u { for (i = 2; i <= NF; i++) if ($i == "vmkit-deploy") found = 1 } END { exit !found }' "$WCONF/webmin.acl" 2>/dev/null; then
    ok "$HOOK_USER is allowed the vmkit-deploy module"
  else
    err "$HOOK_USER is not allowed the vmkit-deploy module (webmin.acl)"; MISSING=$((MISSING + 1))
  fi
  if sed -n 's/^anonymous=//p' "$WCONF/miniserv.conf" 2>/dev/null | tr ' ' '\n' | grep -xF "$HOOK_ENTRY" >/dev/null; then
    ok "anonymous entry in place: $HOOK_ENTRY"
  else
    err "anonymous entry missing from miniserv.conf: $HOOK_ENTRY"; MISSING=$((MISSING + 1))
  fi
  echo
fi

# ---------------------------------------------------------------------------
if [ "$MISSING" -eq 0 ]; then
  ok "Everything in place. Virtualmin version: $(cat "$VS_DIR/module.info" 2>/dev/null | sed -n 's/^version=//p')"
  exit 0
fi
err "$MISSING dependencies could not be verified."
err "After a Virtualmin upgrade the code behind them needs reviewing."
exit 1
