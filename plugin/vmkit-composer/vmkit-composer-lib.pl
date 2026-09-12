# vmkit-composer helper functions.
#
# Nothing is stored: projects are found on disk every time. That is the
# difference from vmkit-deploy, where the user defines a configuration.
#
# IMPORTANT: composer is run with the directory's OWN PHP version. Virtualmin
# can hold a PHP version per directory, and dependencies installed with the
# wrong one would be silently broken.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, %in, $module_name, $module_config_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

sub can_edit_domain
{
my ($d) = @_;
return &virtual_server::can_edit_domain($d);
}

# domain_from_in() -> &domain
# The domain every page works on: named by 'dom', editable by this user, and
# with the feature enabled. Any other case ends the page with an error.
sub domain_from_in
{
my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{$module_name} || &error(&text('index_eoff', $d->{'dom'}));
return $d;
}

# composer_command() -> path to composer, or undef
sub composer_command
{
return &has_command("composer");
}

# php_for_dir(&domain, absolute-dir) -> (version, php-binary)
# Finds the most specific Virtualmin PHP setting matching the directory.
sub php_for_dir
{
my ($d, $dir) = @_;
my @pd = eval { &virtual_server::list_domain_php_directories($d) };
# With no website the function returns text instead of hashes - the system
# default is used then.
return (undef, undef) if ($@ || !@pd || !ref($pd[0]));
my $best;
foreach my $p (@pd) {
	next if (index($dir."/", $p->{'dir'}."/") != 0);
	$best = $p if (!$best || length($p->{'dir'}) > length($best->{'dir'}));
	}
return (undef, undef) if (!$best || !$best->{'version'});
# cgimode 2 = "skip commands ending in -cgi", that is, the COMMAND LINE PHP.
# Not the default 0: that mode tries php<ver>-cgi first, and composer under the
# CGI SAPI warns "should be invoked via the CLI version" and does nothing.
my $cmd = &virtual_server::php_command_for_version($best->{'version'}, 2);
return ($best->{'version'}, $cmd);
}

# web_root(&domain) -> topmost directory to scan (absolute path)
#
# The WEB directory, not the home directory: the home holds the panel's own
# folders, mail, logs and the directories of sub-servers.
#
# Its FIRST COMPONENT, not the document root itself: Virtualmin's "Website
# documents sub-directory" setting can point at something like
# public_html/public (how Laravel and friends are installed), and then
# composer.json sits one level up, in public_html itself.
sub web_root
{
my ($d) = @_;
my $home = $d->{'home'};
return undef if (!$home);
my $abs = &virtual_server::public_html_dir($d);
my $rel = "public_html";
if ($abs && $abs =~ /^\Q$home\E\/(.+)$/) {
	$rel = $1;
	$rel =~ s/\/.*$//;
	}
return "$home/$rel";
}

# list_projects(&domain) -> [ { dir, rel, ver, php } ]
# Looks for composer.json below the web root; vendor, node_modules and .git
# are skipped.
sub list_projects
{
my ($d) = @_;
my $home = &web_root($d);
return ( ) if (!$home || !-d $home);
my $depth = $config{'scan_depth'} || 3;
$depth =~ /^\d+$/ || ($depth = 3);
my $inner = "find ".quotemeta($home)." -maxdepth ".($depth + 1).
	    " -type f -name composer.json".
	    " -not -path ".quotemeta("*/vendor/*").
	    " -not -path ".quotemeta("*/node_modules/*").
	    " -not -path ".quotemeta("*/.git/*");
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>/dev/null", 30);
return ( ) if ($timed);
my @rv;
foreach my $l (split(/\r?\n/, $out)) {
	next if ($l !~ /^\Q$home\E\/(.*)\/composer\.json$/ &&
		 $l !~ /^\Q$home\E\/(composer\.json)$/);
	my $dir = $l;
	$dir =~ s/\/composer\.json$//;
	my $rel = $dir;
	$rel =~ s/^\Q$home\E\/?//;
	$rel = "." if ($rel eq '');
	my ($ver, $php) = &php_for_dir($d, $dir);
	push(@rv, { 'dir' => $dir, 'rel' => $rel, 'ver' => $ver, 'php' => $php });
	}
return sort { $a->{'rel'} cmp $b->{'rel'} } @rv;
}

# valid_project(&domain, absolute-dir) -> the project hash, or undef
# A directory coming from a link is never used directly: it has to be one of
# the projects the scan found.
sub valid_project
{
my ($d, $dir) = @_;
my ($p) = grep { $_->{'dir'} eq $dir } &list_projects($d);
return $p;
}

# run_streaming(command, seconds, callback) -> (output, timed-out?, success?)
#
# Reads the child through a pipe and hands EVERY LINE to the callback before
# accumulating it, so the page can fill as the work proceeds.
# backquote_with_timeout cannot do this: it only returns once the command ends.
#
# The timeout uses alarm: <$fh> blocks, and the alarm interrupts the read and
# jumps out of the eval. Without the TERM the command would keep running after
# the timeout. (vmkit-deploy has a twin of this function - deliberately copied
# so Webmin modules do not depend on each other's libraries.)
sub run_streaming
{
my ($cmd, $secs, $cb) = @_;
my ($out, $timed) = ("", 0);
my $fh;
my $pid = open($fh, "-|", $cmd);
return ("$cmd: $!", 0, 0) if (!$pid);
eval {
	local $SIG{'ALRM'} = sub { $timed = 1; die "timeout\n"; };
	alarm($secs);
	while(my $l = <$fh>) {
		$out .= $l;
		$l =~ s/\r?\n$//;
		&$cb($l);
		}
	alarm(0);
	};
alarm(0);
if ($timed) {
	kill('TERM', $pid);
	close($fh);
	return ($out, 1, 0);
	}
close($fh);
return ($out, 0, $? == 0 ? 1 : 0);
}

# ---------------------------------------------------------------------------
# EXTRA FLAGS
#
# Chosen as CHECKBOXES in the module configuration (config.info type 2, "many
# of many"; the selection is stored comma-separated). NOT a free text box: no
# typos, no shell quoting, and the available options stay visible on screen.
#
# The keys carry NO HYPHEN ('nodev', not 'no-dev'): a config.info line is split
# on commas and the first '-' separates value from label (/^(\S*)\-(.*)$/), so
# a hyphenated value would be split in the wrong place.
#
# TRAP: the same job has a different FLAG NAME per command. Verified against
# Composer's own documentation (doc/03-cli.md):
#   install / update -> --optimize-autoloader
#   dump-autoload    -> --optimize
# hence a mapping per command.
#
# TWO OPTIONS, BOTH ON BY DEFAULT. This is the command Composer's own
# documentation recommends for production: 'composer install --no-dev
# --optimize-autoloader'. Of --optimize-autoloader it says: "recommended
# especially for production, but can take a bit of time to run so it is
# currently not done by default".
#
# DELIBERATELY ABSENT (not even offered, because they silently break the
# default production flow):
#   --classmap-authoritative  "Autoload classes from the classmap only" - the
#     PSR-4 fallback is disabled entirely and anything generating classes at
#     runtime (Doctrine proxies, some framework caches) breaks.
#   --no-scripts  Laravel's package discovery, Symfony's cache clearing and
#     similar work live in post-install scripts; skipping them leaves a
#     deployment silently half-finished.
sub composer_flag_map
{
return (
  'nodev'     => { 'install'       => '--no-dev',
		   'update'        => '--no-dev',
		   'dump-autoload' => '--no-dev' },
  'optimize'  => { 'install'       => '--optimize-autoloader',
		   'update'        => '--optimize-autoloader',
		   'dump-autoload' => '--optimize' },
  );
}

# composer_flags(action) -> the flags to add for that action
sub composer_flags
{
my ($action) = @_;
my %map = &composer_flag_map();
my @rv;
# An unknown key is skipped silently: the config file may have been edited by
# hand or left over from an older version.
foreach my $k (split(/,/, $config{'flags'} || '')) {
	$k =~ s/^\s+|\s+$//g;
	next if (!$k || !$map{$k});
	push(@rv, $map{$k}->{$action}) if ($map{$k}->{$action});
	}
return @rv;
}

# Command timeout, 900 when unset: upgrading the module does NOT add new keys
# to an existing config file (update-plugins.sh only copies it when absent), so
# every read has to carry its own default.
sub composer_timeout
{
my $t = $config{'timeout'};
return $t && $t =~ /^\d+$/ && $t > 0 ? $t : 900;
}

# run_composer(&domain, &project, action, [&callback]) -> (success?, output)
#
# With a callback the output is sent to it line by line and the page fills as
# the work proceeds; without one it is returned in one piece.
sub run_composer
{
my ($d, $p, $action, $cb) = @_;
my $composer = &composer_command();
return (0, $text{'err_nocomposer'}) if (!$composer);

my %args = ( 'install'       => "install --no-interaction --no-progress",
	     'update'        => "update --no-interaction --no-progress",
	     'dump-autoload' => "dump-autoload --no-interaction" );
my $sub = $args{$action};
return (0, $text{'err_action'}) if (!$sub);
my $extra = join(" ", &composer_flags($action));
$sub .= " ".$extra if ($extra);

my $inner = "cd ".quotemeta($p->{'dir'})." && ".
	    ($p->{'php'} ? quotemeta($p->{'php'})." " : "").
	    quotemeta($composer)." ".$sub;
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my $secs = &composer_timeout();
my ($out, $timed, $ok);
if ($cb) {
	($out, $timed, $ok) = &run_streaming("$cmd 2>&1", $secs, $cb);
	}
else {
	($out, $timed) = &backquote_with_timeout("$cmd 2>&1", $secs);
	$ok = !$timed && !$? ? 1 : 0;
	}
# On a timeout the output is not REPLACED: the lines streamed so far are on
# screen and belong in the returned output too. The note is appended.
$out .= "\n".$text{'err_timeout'}."\n" if ($timed);
return ($ok, $out);
}

# composer_packages(&domain, &project) -> (\@packages, error)
# 'composer show --latest --format=json' gives the installed packages, their
# versions and any newer version in one call, so 'outdated' is not needed.
#
# Without vendor/ composer errors out - that error is shown as it is, because
# composer's own message is the best way to say "run install first". The
# timeout is generous since --latest queries versions over the network.
sub composer_packages
{
my ($d, $p) = @_;
my $composer = &composer_command();
return (undef, $text{'err_nocomposer'}) if (!$composer);

my $inner = "cd ".quotemeta($p->{'dir'})." && ".
	    ($p->{'php'} ? quotemeta($p->{'php'})." " : "").
	    quotemeta($composer)." show --latest --format=json --no-interaction";
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 300);
return (undef, $text{'err_timeout'}) if ($timed);
return (undef, $out) if ($?);

my $j;
eval { $j = &convert_from_json($out); };
return (undef, $text{'err_badjson'}) if ($@ || ref($j) ne 'HASH');
return ($j->{'installed'} || [ ], undef);
}

1;
