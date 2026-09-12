# vmkit-check helper functions.
#
# The panel's answer to "did the last Webmin/Virtualmin upgrade break a vmkit
# plugin?". The other three plugins call into Virtualmin, Webmin's UI library
# and a few Webmin modules, none of which promise a stable interface. Nothing
# here is a hand-kept list: the plugins' own source is scanned for what they
# call, and each name is looked up in the running system.
#
# Results are kept in the module's config directory together with a stamp of
# the versions they were produced under. The dashboard block re-runs the checks
# when the stamp no longer matches (an upgrade happened) or the result is a day
# old; the page runs them on demand.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, %in, $module_name, $module_config_directory,
     $root_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

# The hardening measures are defined ONCE in harden-lib.pl (the same file the
# installer runs); we require it for their check/apply subs and their
# where/why metadata. Standalone Perl, so requiring it here is harmless.
require "$module_root_directory/harden-lib.pl";

# The plugins this module looks after: every vmkit-* module that is a
# Virtualmin plugin, except this one.
sub vmkit_plugins
{
my @rv;
opendir(my $D, $root_directory) || return ( );
foreach my $m (sort readdir($D)) {
	next if ($m !~ /^vmkit-/ || $m eq $module_name);
	next if (!-r "$root_directory/$m/virtual_feature.pl");
	push(@rv, $m);
	}
closedir($D);
return @rv;
}

sub source_files
{
my ($mod) = @_;
my $dir = "$root_directory/$mod";
opendir(my $D, $dir) || return ( );
my @rv = map { "$dir/$_" } grep { /\.(cgi|pl)$/ } readdir($D);
closedir($D);
return sort @rv;
}

# Comment lines are dropped so that a name mentioned in a comment is not taken
# for a call.
sub code_of
{
my ($file) = @_;
my $src = &read_file_contents($file);
return "" if (!defined($src));
return join("\n", grep { !/^\s*#/ } split(/\n/, $src));
}

# A check is { plugin, desc, ok, detail, fix } - 'fix' names a repair this
# module can apply from the page.
sub mkcheck
{
my ($plugin, $desc, $ok, $detail, $fix) = @_;
return { 'plugin' => $plugin, 'desc' => $desc, 'ok' => $ok ? 1 : 0,
	 'detail' => $detail, 'fix' => $fix };
}

# ---- symbols ---------------------------------------------------------------
# Everything the plugin calls in another package (virtual_server::, bind8::,
# acl::) and every ui_* helper. A missing function kills a page with
# "Undefined subroutine", and only when that page is opened.
#
# A helper the plugin calls behind defined(&name) is optional by design and is
# skipped: the plugin already falls back when it is missing.
#
# ui_* helpers are looked up in the PLUGIN'S OWN PACKAGE: miniserv runs a
# module's CGIs in a package named after the module (vmkit-deploy ->
# vmkit_deploy) and Webmin's libraries load into that package, so that is
# where the plugin's pages will find - or miss - them. Loading the plugin's
# library with foreign_require brings the libraries in the same way.
sub check_symbols
{
my ($mod) = @_;
my (%seen, %optional, @checks);
my %pkgs = ( 'virtual_server' => 'virtual-server', 'bind8' => 'bind8',
	     'acl' => 'acl' );
foreach my $p (values %pkgs) {
	eval { &foreign_require($p) } if (-d "$root_directory/$p");
	}
my $modpkg = $mod;
$modpkg =~ s/[^A-Za-z0-9]/_/g;
eval { &foreign_require($mod, "$mod-lib.pl"); };
foreach my $f (&source_files($mod)) {
	my $code = &code_of($f);
	while ($code =~ /defined\(&(ui_[a-z_0-9]+)\)/g) { $optional{$1} = 1; }
	while ($code =~ /([&\$\@\%])(virtual_server|bind8|acl)::([A-Za-z_0-9]+)/g) {
		my ($sigil, $pkg, $name) = ($1, $2, $3);
		next if ($seen{"$sigil$pkg$name"}++);
		my $ok;
		{
		no strict 'refs';
		$ok = $sigil eq '&' ? defined(&{"${pkg}::${name}"})
				    : exists(${"${pkg}::"}{$name});
		}
		push(@checks, &mkcheck($mod, &text('chk_symbol', "$sigil${pkg}::$name"),
				       $ok, $ok ? "" : $text{'chk_missing'}));
		}
	while ($code =~ /&(ui_[a-z_0-9]+)\(/g) {
		my $name = $1;
		next if ($seen{"ui:$name"}++ || $optional{$name});
		my $ok;
		{ no strict 'refs'; $ok = defined(&{"${modpkg}::$name"}); }
		push(@checks, &mkcheck($mod, &text('chk_symbol', "&$name"),
				       $ok, $ok ? "" : $text{'chk_missing'}));
		}
	}
return @checks;
}

# ---- hooks -----------------------------------------------------------------
# The other direction: does Virtualmin still call the feature_* hooks the
# plugin implements? A renamed hook raises no error at all - the function just
# sits there unused. The test is that the name appears quoted somewhere in
# Virtualmin's source, which is how plugin_call reaches it.
my %called_cache;
sub virtualmin_called_names
{
return \%called_cache if (%called_cache);
my $dir = "$root_directory/virtual-server";
opendir(my $D, $dir) || return \%called_cache;
foreach my $f (readdir($D)) {
	next if ($f !~ /\.(pl|cgi)$/);
	my $src = &read_file_contents("$dir/$f");
	next if (!defined($src));
	while ($src =~ /["']([a-z_][a-z_0-9]*)["']/g) { $called_cache{$1} = 1; }
	}
closedir($D);
return \%called_cache;
}

sub check_hooks
{
my ($mod) = @_;
my @checks;
my $called = &virtualmin_called_names();
my $code = &code_of("$root_directory/$mod/virtual_feature.pl");
while ($code =~ /^sub\s+([a-z_][a-z_0-9]*)/mg) {
	my $name = $1;
	my $ok = $called->{$name} ? 1 : 0;
	push(@checks, &mkcheck($mod, &text('chk_hook', $name), $ok,
			       $ok ? "" : $text{'chk_hook_uncalled'}));
	}
return @checks;
}

# ---- what each plugin depends on at runtime -------------------------------
sub check_deploy
{
my $mod = "vmkit-deploy";
my @checks;
eval { &foreign_require($mod, "$mod-lib.pl"); };
if ($@) {
	return &mkcheck($mod, $text{'chk_lib'}, 0, "$@");
	}
my $u = &vmkit_deploy::hook_webmin_user();
push(@checks, &mkcheck($mod, &text('chk_hook_user', &vmkit_deploy::hook_user()),
		       $u ? 1 : 0, $u ? "" : $text{'chk_missing'}, 'deploy_hook'));
my $allowed = $u && &indexof($mod, @{$u->{'modules'} || []}) >= 0;
push(@checks, &mkcheck($mod, $text{'chk_hook_module'}, $allowed,
		       $allowed ? "" : $text{'chk_missing'}, 'deploy_hook'));
my $e = &vmkit_deploy::hook_anon_entry();
my $present = grep { $_ eq $e } &vmkit_deploy::anon_entries();
push(@checks, &mkcheck($mod, &text('chk_hook_entry', $e), $present,
		       $present ? "" : $text{'chk_missing'}, 'deploy_hook'));
return @checks;
}

sub check_cloudflare
{
my $mod = "vmkit-cloudflare";
my @checks;
eval { &foreign_require($mod, "$mod-lib.pl"); };
if ($@) {
	return &mkcheck($mod, $text{'chk_lib'}, 0, "$@");
	}
my $st = &vmkit_cloudflare::sync_units_status();
if (!$st->{'systemd'}) {
	return &mkcheck($mod, $text{'chk_sync'}, 0, $text{'chk_nosystemd'});
	}
my @bad;
foreach my $k ("path", "timer") {
	my $u = $st->{$k} || { };
	push(@bad, $u->{'name'}) if (!$u->{'exists'} || !$u->{'current'} || !$u->{'active'});
	}
push(@bad, $text{'chk_nowatch'}) if ($st->{'nowatch'});
push(@checks, &mkcheck($mod, $text{'chk_sync'}, !@bad, join(", ", @bad),
		       'cloudflare_units'));
return @checks;
}

sub check_composer
{
my $mod = "vmkit-composer";
my $cmd = &has_command("composer");
return &mkcheck($mod, $text{'chk_composer'}, $cmd ? 1 : 0,
		$cmd ? $cmd : $text{'chk_missing'});
}

# ---- hardening (the four pentest measures) ---------------------------------
# One check per measure, using the shared harden-lib.pl. 'plugin' is 'hardening'
# so the page can pull these into their own section; 'where'/'why' carry the
# "what did we change and where" the user wants surfaced months later. The fix
# id is harden_<id>, dispatched in apply_fix.
sub check_hardening
{
my @checks;
foreach my $m (&vmkit_harden::measures()) {
	my $ok = eval { $m->{'check'}->() } ? 1 : 0;
	my $c = &mkcheck('hardening', $m->{'title'}, $ok,
			 $m->{'where'}, 'harden_'.$m->{'id'});
	$c->{'where'} = $m->{'where'};
	$c->{'why'}   = $m->{'why'};
	push(@checks, $c);
	}
return @checks;
}

# hardening_measures() -> the raw list, for the page's own Hardening table.
sub hardening_measures
{
return &vmkit_harden::measures();
}

# ---- running and storing ---------------------------------------------------

# The versions the results were produced under. Any change means an upgrade
# happened and the checks are due again.
sub current_stamp
{
my @parts = ( "webmin=".&get_webmin_version() );
my %vinfo = &get_module_info("virtual-server");
push(@parts, "virtualmin=".($vinfo{'version'} || '?'));
foreach my $m (&vmkit_plugins()) {
	my %minfo = &get_module_info($m);
	push(@parts, "$m=".($minfo{'version'} || '?'));
	}
return join(" ", @parts);
}

sub run_checks
{
my @checks;
my %plugins = map { $_ => 1 } &vmkit_plugins();
foreach my $m (sort keys %plugins) {
	push(@checks, &check_symbols($m), &check_hooks($m));
	}
push(@checks, &check_deploy())     if ($plugins{'vmkit-deploy'});
push(@checks, &check_cloudflare()) if ($plugins{'vmkit-cloudflare'});
push(@checks, &check_composer())   if ($plugins{'vmkit-composer'});
push(@checks, &check_hardening());
return \@checks;
}

sub results_file
{
return "$module_config_directory/last";
}

# save_results(&checks) -> &results
sub save_results
{
my ($checks) = @_;
my $failed = grep { !$_->{'ok'} } @$checks;
my %r = ( 'time'   => time(),
	  'stamp'  => &current_stamp(),
	  'total'  => scalar(@$checks),
	  'failed' => $failed,
	  'data'   => &serialise_variable($checks) );
-d $module_config_directory || &make_dir($module_config_directory, 0700, 1);
&lock_file(&results_file());
&write_file(&results_file(), \%r);
&unlock_file(&results_file());
$r{'checks'} = $checks;
return \%r;
}

# load_results() -> &results, or undef when the checks never ran
sub load_results
{
my %r;
&read_file(&results_file(), \%r) || return undef;
return undef if (!$r{'time'});
my $checks = eval { &unserialise_variable($r{'data'}) };
return undef if (ref($checks) ne 'ARRAY');
$r{'checks'} = $checks;
return \%r;
}

# results_current(&results) -> same versions, and not older than a day
sub results_current
{
my ($r) = @_;
return 0 if (!$r);
return 0 if ($r->{'stamp'} ne &current_stamp());
return 0 if (time() - $r->{'time'} > 24*60*60);
return 1;
}

# run_and_save() -> &results
sub run_and_save
{
return &save_results(&run_checks());
}

# ---- repairs ---------------------------------------------------------------
# Each repair is a plugin's own idempotent ensure_* function.
sub apply_fix
{
my ($id) = @_;
if ($id eq 'deploy_hook') {
	&foreign_require("vmkit-deploy", "vmkit-deploy-lib.pl");
	my ($changed, $err) = &vmkit_deploy::ensure_hook_access();
	return $err;
	}
if ($id eq 'cloudflare_units') {
	&foreign_require("vmkit-cloudflare", "vmkit-cloudflare-lib.pl");
	my ($done, $err) = &vmkit_cloudflare::ensure_sync_units(1);
	return $err;
	}
if ($id =~ /^harden_(.+)$/) {
	my $m = &vmkit_harden::measure_by_id($1);
	return $text{'fix_eunknown'} if (!$m);
	my ($ok, $msg) = $m->{'apply'}->();
	return $ok ? undef : $msg;
	}
return $text{'fix_eunknown'};
}

1;
