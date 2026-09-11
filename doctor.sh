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
  | grep -oE '[&$@%](virtual_server|bind8)::[a-zA-Z_0-9]+' \
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

while(my $l = <STDIN>) {
	chomp($l);
	my ($sigil, $pkg, $name) = split(/\t/, $l);
	next if (!$name);
	# The plugins' 'virtual_server::' and 'main::' here are the same set.
	my $p = $pkg eq 'bind8' ? 'bind8' : 'main';
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
# 8) MINISERV'S 'unauthcgi' LIST
#
# vmkit-deploy adds the webhook path to miniserv's list of CGIs that may RUN
# without a login. That key's default is not in miniserv.conf but in miniserv's
# own %vital table, and it applies only while the key is absent from the file:
#
#   foreach my $v (keys %vital) { if (!$config{$v}) { $config{$v} = $vital{$v} } }
#
# So whoever writes the key must reproduce the whole default, or it disappears
# silently - for 'unauthcgi' that would be Webmin's password-recovery pages.
#
# The plugin reads the default from the source and merges on every run, but a
# Webmin upgrade in between can add an entry the written copy lacks. That is
# the contract checked here: is every entry of the source default present in
# the file?
#
# The defaults do change between versions: the 'unauth' list was identical from
# 1.990 to 2.111 and gained '^/service-worker.js$' by 2.202. Not a theoretical
# scenario.
# ---------------------------------------------------------------------------
log "Verifying miniserv's unauthcgi list..."
MSCONF="${WEBMIN_CONFIG:-/etc/webmin}/miniserv.conf"
UNAUTH_CUR="$(sed -n 's/^unauthcgi=//p' "$MSCONF" 2>/dev/null | head -1)"
if [ -z "$UNAUTH_CUR" ]; then
  # The key is absent, so miniserv uses its own default and there is no drift
  # to verify.
  ok "unauthcgi is not in the file (miniserv's default applies)"
else
  # The string in the source is double-quoted, so '\$' and '\\' are escapes
  # that Perl resolves; they are resolved here too. In a regex '\$' and '$' are
  # not the same thing, so matching without resolving them would be wrong.
  UNAUTH_RAW="$(grep -hoE '"unauthcgi", "[^"]*"' \
                  "$WEBMIN_ROOT/miniserv-lib.pl" "$WEBMIN_ROOT/miniserv.pl" \
                  2>/dev/null | head -1)"
  if [ -z "$UNAUTH_RAW" ]; then
    warn "could not find the unauthcgi default in the miniserv source; not compared"
    MISSING=$((MISSING + 1))
  else
    UNAUTH_DEF="${UNAUTH_RAW#\"unauthcgi\", \"}"
    UNAUTH_DEF="${UNAUTH_DEF%\"}"
    UNAUTH_DEF="$(printf '%s' "$UNAUTH_DEF" | sed 's/\\\$/$/g; s/\\\\/\\/g')"
    UNAUTH_OK=0
    declare -A UNAUTH_SEEN=()
    # Filename expansion OFF: entries contain things like '[A-Za-z0-9\-/_]'
    # which the shell would treat as a glob after word splitting.
    set -f
    for d in $UNAUTH_DEF; do
      # The default list contains '^/robots.txt$' twice (since Webmin 1.990);
      # count the duplicate once.
      [ -n "${UNAUTH_SEEN[$d]:-}" ] && continue
      UNAUTH_SEEN["$d"]=1
      # Literal comparison rather than a glob: in a 'case' pattern those same
      # expressions would be read as character classes.
      hit=0
      for c in $UNAUTH_CUR; do [ "$c" = "$d" ] && hit=1; done
      if [ "$hit" = 1 ]; then
        UNAUTH_OK=$((UNAUTH_OK + 1))
      else
        err "default missing from the unauthcgi list: $d"
        MISSING=$((MISSING + 1))
      fi
    done
    set +f
    ok "$UNAUTH_OK unauthcgi defaults in place"
  fi
fi
echo

# ---------------------------------------------------------------------------
if [ "$MISSING" -eq 0 ]; then
  ok "Everything in place. Virtualmin version: $(cat "$VS_DIR/module.info" 2>/dev/null | sed -n 's/^version=//p')"
  exit 0
fi
err "$MISSING dependencies could not be verified."
err "After a Virtualmin upgrade the code behind them needs reviewing."
exit 1
