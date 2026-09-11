# vmkit-deploy helper functions.
#
# Data model: N "deployments" per domain. A deployment is a repository plus a
# target directory, so one domain can run two repositories in two directories.
#
# Storage: one file per deployment,
#   /etc/webmin/vmkit-deploy/deploys/<domain-id>-<deploy-id>
# in Webmin's key=value format, which makes adding and removing atomic and
# backing up no harder than reading the directory.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, %in, $module_name, $module_config_directory,
     $root_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

sub deploys_dir
{
return "$module_config_directory/deploys";
}

# list_deploys([&domain])
# Returns every deployment, or only those belonging to the given domain.
sub list_deploys
{
my ($d) = @_;
my $dir = &deploys_dir();
my @rv;
opendir(my $DIR, $dir) || return ( );
foreach my $f (readdir($DIR)) {
	next if ($f eq "." || $f eq "..");
	next if ($d && $f !~ /^\Q$d->{'id'}\E-/);
	my %dep;
	&read_file("$dir/$f", \%dep) || next;
	$dep{'file'} = "$dir/$f";
	push(@rv, \%dep);
	}
closedir($DIR);
return sort { ($a->{'name'} || '') cmp ($b->{'name'} || '') } @rv;
}

# get_deploy(&domain, id)
sub get_deploy
{
my ($d, $id) = @_;
my ($dep) = grep { $_->{'id'} eq $id } &list_deploys($d);
return $dep;
}

# save_deploy(&domain, &deploy)
# Generates a new id when the id is empty.
sub save_deploy
{
my ($d, $dep) = @_;
my $dir = &deploys_dir();
-d $dir || &make_dir($dir, 0700, 1);
$dep->{'id'} ||= time().$$;
$dep->{'dom'} = $d->{'id'};
my $file = "$dir/$d->{'id'}-$dep->{'id'}";
my %out = %$dep;
delete($out{'file'});
&lock_file($file);
&write_file($file, \%out);
&unlock_file($file);
$dep->{'file'} = $file;
return $dep;
}

# delete_deploy(&domain, &deploy)
# Removes only the definition, the bare repository and the log. It NEVER
# touches the target directory: deployed site content, uploads and .env stay.
sub delete_deploy
{
my ($d, $dep) = @_;
my $file = $dep->{'file'} || &deploys_dir()."/$d->{'id'}-$dep->{'id'}";
my $repo = &deploy_repo_path($d, $dep);
if ($dep->{'id'} && -d $repo) {
	my $cmd = &command_as_user($d->{'user'}, 1, "rm -rf ".quotemeta($repo));
	&backquote_with_timeout("$cmd 2>&1", 60);
	}
unlink(&deploy_log_path($d, $dep));
unlink(&actions_path($d, $dep));
unlink(&actions_script_path($d, $dep)) if ($dep->{'id'});
&lock_file($file);
unlink($file);
&unlock_file($file);
}

# delete_domain_deploys(&domain)
sub delete_domain_deploys
{
my ($d) = @_;
foreach my $dep (&list_deploys($d)) {
	&delete_deploy($d, $dep);
	}
}

# can_edit_domain(&domain)
# Uses Virtualmin's own check: master admin, reseller or the domain's owner.
sub can_edit_domain
{
my ($d) = @_;
return &virtual_server::can_edit_domain($d);
}

# validate_target(&domain, path)
# The target must live under the DOCUMENT ROOT (public_html). The home
# directory also holds the panel's own folders, mail, logs and the sub-servers'
# directories; deploying there would be confusing and would let the parent
# domain's panel write inside a sub-server.
#
# An application that moves its document root one level down (Laravel and
# friends) uses Virtualmin's own setting instead: Website Options -> Website
# documents sub-directory = public_html/public. The deploy still goes to
# public_html and only the served root moves.
sub validate_target
{
my ($d, $path) = @_;
return $text{'err_target_empty'} if ($path eq '');
return $text{'err_target_abs'}   if ($path =~ /^\//);
return $text{'err_target_dots'}  if ($path =~ /(^|\/)\.\.(\/|$)/);
return $text{'err_target_char'}  if ($path !~ /^[A-Za-z0-9._\-\/]+$/);

my $root = &deploy_root($d);
return $text{'err_target_nohtml'} if (!$root);
my $full = "$d->{'home'}/$path";
return &text('err_target_outside', &deploy_root_rel($d))
	if ($full ne $root && $full !~ /^\Q$root\E\//);
return undef;
}

# deploy_root(&domain) -> the topmost directory that may be deployed to
#
# The FIRST segment of the document root. Virtualmin's "Website documents
# sub-directory" can point at something like public_html/public, and in that
# case the project root is still public_html - public is only the served folder
# inside it. So the first segment is taken, not the document root itself.
sub deploy_root
{
my ($d) = @_;
my $home = $d->{'home'};
return undef if (!$home);
my $abs = &virtual_server::public_html_dir($d);
my $rel = "public_html";
if ($abs && $abs =~ /^\Q$home\E\/(.+)$/) {
	$rel = $1;
	$rel =~ s/\/.*$//;	# first segment
	}
return "$home/$rel";
}

# deploy_root_rel(&domain) -> the same directory, relative to the home
sub deploy_root_rel
{
my ($d) = @_;
my $root = &deploy_root($d) || return "public_html";
my $rel = $root;
$rel =~ s/^\Q$d->{'home'}\E\/?//;
return $rel eq '' ? "public_html" : $rel;
}

# target_sub(&domain, target) -> the part of the target below the root (for the
# form). The target is STORED relative to the home (public_html/app), but the
# form only shows what is below the root.
sub target_sub
{
my ($d, $target) = @_;
my $rel = &deploy_root_rel($d);
return "" if (!defined($target) || $target eq '' || $target eq $rel);
my $sub = $target;
return $sub if ($sub !~ s/^\Q$rel\E\///);
return $sub;
}

# target_full(&domain, sub-path) -> the target as stored, relative to the home
sub target_full
{
my ($d, $sub) = @_;
my $rel = &deploy_root_rel($d);
$sub = '' if (!defined($sub));
$sub =~ s/^\/+//; $sub =~ s/\/+$//;
return $sub eq '' ? $rel : "$rel/$sub";
}

# deploy_target_dir(&domain, &deploy) -> absolute path
sub deploy_target_dir
{
my ($d, $dep) = @_;
return "$d->{'home'}/$dep->{'target'}";
}

# validate_repo_url(url)
# An alphanumeric is required right after the scheme, which rejects URLs
# starting with '-' (git would read them as options) and executable forms like
# 'ext::<command>'.
sub validate_repo_url
{
my ($url) = @_;
return $text{'save_erepo'} if ($url !~ /\S/);
return $text{'save_erepourl'}
	if ($url !~ /^(https:\/\/|http:\/\/|ssh:\/\/|git\@)[A-Za-z0-9]/);
return undef;
}

# remote_branches(&domain, url)
# Queries the remote with 'git ls-remote' - no clone, just the ref list. It
# runs AS THE DOMAIN'S OWN USER so that private repositories use that user's
# SSH key.
# Returns: (default-branch, \@branches, error)
sub remote_branches
{
my ($d, $url) = @_;
my $err = &validate_repo_url($url);
return (undef, undef, $err) if ($err);

# BatchMode: fail immediately instead of waiting on a password prompt.
my $inner = "GIT_TERMINAL_PROMPT=0 ".
	    "GIT_SSH_COMMAND=".quotemeta(&git_ssh_command($d))." ".
	    "git ls-remote --symref -- ".quotemeta($url);
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 25);
return (undef, undef, $text{'err_timeout'}) if ($timed);
return (undef, undef, $out) if ($?);

my ($default, @branches);
foreach my $l (split(/\r?\n/, $out)) {
	if ($l =~ /^ref:\s+refs\/heads\/(\S+)\s+HEAD$/) {
		$default = $1;
		}
	elsif ($l =~ /^\S+\s+refs\/heads\/(.+)$/) {
		push(@branches, $1);
		}
	}
return (undef, undef, $text{'err_nobranches'}) if (!@branches);
$default ||= $branches[0];
return ($default, \@branches, undef);
}
# ---- the domain's SSH key ------------------------------------------------
# ONE key per domain, in the standard place: ~/.ssh/id_ed25519
#
# Its public half is added to the ACCOUNT on GitHub/Gitea (Settings -> SSH
# keys), not to a single repository as a "deploy key", so every private
# repository that account can reach works for this domain. A deploy key would
# also work, but GitHub accepts one only on a single repository and the second
# private repository would fail.
sub domain_key_path
{
my ($d) = @_;
return $d->{'home'}."/.ssh/id_ed25519";
}

# domain_key_pub(&domain) -> the public key text, or undef
sub domain_key_pub
{
my ($d) = @_;
my $pub = &domain_key_path($d).".pub";
return undef if (!-r $pub);
my $txt = &read_file_contents($pub);
$txt =~ s/\s+$//;
return $txt;
}

# ensure_domain_key(&domain) -> an error message, or undef
# Generated as the domain's own user, so ownership and permissions are right
# from the start rather than generated as root and chowned afterwards.
sub ensure_domain_key
{
my ($d) = @_;
return undef if (&domain_key_pub($d));
my $path = &domain_key_path($d);
my $sshdir = $d->{'home'}."/.ssh";
my $inner = "mkdir -p ".quotemeta($sshdir)." && ".
	    "chmod 700 ".quotemeta($sshdir)." && ".
	    "ssh-keygen -q -t ed25519 -N '' -f ".quotemeta($path).
	    " -C ".quotemeta("vmkit ".$d->{'dom'});
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 30);
return $text{'err_timeout'} if ($timed);
return $out if ($?);
return &domain_key_pub($d) ? undef : ($out || $text{'key_efail'});
}

# git_ssh_command(&domain)
# No -i needed: the key is in the standard place and ssh finds it itself.
# BatchMode: fail immediately instead of waiting on a password prompt.
sub git_ssh_command
{
my ($d) = @_;
return "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new".
       " -o ConnectTimeout=10";
}
# ---- running -------------------------------------------------------------
# The git data lives OUTSIDE the web root:
#     ~/.vmkit/repos/<id>.git      (bare)
#         |  git --work-tree=<target> checkout -f <branch>
#         v
#     ~/public_html/...            (files only, no .git)
#
# Cloning straight into the target would create public_html/.git, and one wrong
# Apache setting would publish the repository history. '~/.git' is avoided for
# a different reason: git would treat the home directory as a working copy.
#
# PULL and DEPLOY are two separate operations:
#   pull    fetches from the remote into the bare repository. The site does not
#           change; the Commits page shows what arrived and you decide.
#   deploy  writes the bare repository's branch into the target and runs the
#           post-deploy commands, if any.
# A deployment in automatic mode (and the webhook) uses 'both'. In manual mode
# a pull never triggers a deploy.
sub deploy_repo_path
{
my ($d, $dep) = @_;
return $d->{'home'}."/.vmkit/repos/".$dep->{'id'}.".git";
}

sub deploy_log_path
{
my ($d, $dep) = @_;
return "$module_config_directory/logs/$d->{'id'}-$dep->{'id'}.log";
}

sub deploy_log_read
{
my ($d, $dep) = @_;
return &read_file_contents(&deploy_log_path($d, $dep));
}

# The log directory must exist BEFORE the work starts, because the hook
# redirects the output from the shell; deploy_run's own check would be too late.
sub ensure_log_dir
{
my $dir = "$module_config_directory/logs";
-d $dir || &make_dir($dir, 0700, 1);
return $dir;
}

# ---- post-deploy commands ------------------------------------------------
# They are multi-line and do not fit the key=value format, so like the log they
# live in their own file. The content is whatever shell lines the user wrote -
# there is no fixed list or template.
sub actions_path
{
my ($d, $dep) = @_;
return "$module_config_directory/actions/$d->{'id'}-$dep->{'id'}";
}

sub actions_read
{
my ($d, $dep) = @_;
my $t = &read_file_contents(&actions_path($d, $dep));
return defined($t) ? $t : "";
}

sub actions_write
{
my ($d, $dep, $text) = @_;
my $dir = "$module_config_directory/actions";
-d $dir || &make_dir($dir, 0700, 1);
my $file = &actions_path($d, $dep);
if (!defined($text) || $text !~ /\S/) {
	unlink($file);
	return;
	}
$text =~ s/\r\n/\n/g;
$text .= "\n" if ($text !~ /\n$/);
no strict "subs";
&open_tempfile(ACT, ">".$file);
&print_tempfile(ACT, $text);
&close_tempfile(ACT);
use strict "subs";
}

# domain_php_bin(&domain, absolute-dir) -> (version, php binary)
# Finds the most specific Virtualmin PHP definition for that directory.
# vmkit-composer carries the same logic of its own: the two modules are
# deliberately not shared so either can be installed without the other.
sub domain_php_bin
{
my ($d, $dir) = @_;
my @pd = eval { &virtual_server::list_domain_php_directories($d) };
return (undef, undef) if ($@ || !@pd || !ref($pd[0]));
my $best;
foreach my $p (@pd) {
	next if (index($dir."/", $p->{'dir'}."/") != 0);
	$best = $p if (!$best || length($p->{'dir'}) > length($best->{'dir'}));
	}
return (undef, undef) if (!$best || !$best->{'version'});
# cgimode 2 = the command-line PHP. The default mode also considers
# php<ver>-cgi and can run the CGI SAPI, in which case composer refuses with
# "should be invoked via the CLI version" and does nothing.
return ($best->{'version'},
	&virtual_server::php_command_for_version($best->{'version'}, 2));
}

# ensure_php_path_dir(&domain, dir) -> a directory to prepend to PATH
# It holds a single 'php' symlink pointing at the target directory's Virtualmin
# PHP version, so the user's own commands ('php artisan migrate', and composer,
# whose shebang is 'env php') run with the right version and nobody has to
# write a full path like /usr/bin/php8.3.
sub ensure_php_path_dir
{
my ($d, $dir) = @_;
my (undef, $php) = &domain_php_bin($d, $dir);
return undef if (!$php);
my $bindir = $d->{'home'}."/.vmkit/bin";
my $inner = "mkdir -p ".quotemeta($bindir)." && ".
	    "ln -sfn ".quotemeta($php)." ".quotemeta($bindir."/php");
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my (undef, $timed) = &backquote_with_timeout("$cmd 2>&1", 20);
return $timed || $? ? undef : $bindir;
}

# current_ref(&domain, &deploy) -> the branch tip in the bare repo (short hash)
sub current_ref
{
my ($d, $dep) = @_;
my $repo = &deploy_repo_path($d, $dep);
return undef if (!-d $repo);
my $inner = "git --git-dir=".quotemeta($repo)." rev-parse --short ".
	    quotemeta($dep->{'branch'});
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>/dev/null", 20);
return undef if ($timed || $?);
$out =~ s/\s+//g;
return $out eq '' ? undef : $out;
}

# pending(&domain, &deploy) -> is something pulled but not yet deployed?
sub pending
{
my ($d, $dep) = @_;
return 0 if (!$dep->{'pulled_ref'});
return ($dep->{'deployed_ref'} || '') ne $dep->{'pulled_ref'} ? 1 : 0;
}

# ---- step builders -------------------------------------------------------
# Each returns shell lines; deploy_run runs them all under 'set -e' in a single
# session as the domain user.

sub git_env
{
my ($d) = @_;
return "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=".
       quotemeta(&git_ssh_command($d));
}

# Pull: a bare clone the first time, a fetch afterwards.
# The repository must stay BARE. With core.bare false git treats the repo's own
# directory as a working copy and refuses the fetch with "refusing to fetch
# into branch ... checked out at". Bare plus --work-tree checkout works.
sub pull_steps
{
my ($d, $dep) = @_;
my $R = quotemeta(&deploy_repo_path($d, $dep));
my $B = quotemeta($dep->{'branch'});
my $env = &git_env($d);
# The <pre> holds ONLY the commands' own output - no narrating 'echo' lines.
# The screen is a console transcript, not a summary.
my @steps;
# OLDREF is read BEFORE the clone: 'git clone --bare' already brings every
# commit, so reading it afterwards would make it non-empty even on the first
# pull, the following fetch would bring nothing, and the log would claim "no
# new commits". With no repository yet the command fails, OLDREF stays empty
# and the output is correct.
push(@steps, 'OLDREF=$(git --git-dir='.$R.' rev-parse -q --verify '.$B.
	     ' 2>/dev/null || true)');
push(@steps, "if [ ! -d $R ]; then ".
	     "mkdir -p ".quotemeta($d->{'home'}."/.vmkit/repos")." && ".
	     "$env git clone --bare -- ".quotemeta($dep->{'repo'})." $R; ".
	     "fi");
push(@steps, "git --git-dir=$R remote set-url origin -- ".
	     quotemeta($dep->{'repo'}));
# '-v': with nothing to fetch, git prints NOTHING by default and the screen
# would be blank. The "Already up to date." people know from 'git pull' comes
# from pull's merge half, which we do not run (bare repo plus a separate
# checkout), so the equivalent is fetch's verbose output:
#   = [up to date]      main       -> main
#   4cb4a6e..ed3bea3    main       -> main
# These are git's own lines, not ours.
push(@steps, "$env git --git-dir=$R fetch -v --prune origin ".
	     quotemeta("+refs/heads/*:refs/heads/*"));
push(@steps, 'NEWREF=$(git --git-dir='.$R.' rev-parse '.$B.')');
# On the first pull OLDREF is empty and the range is meaningless; if the
# commit did not move there is nothing to show either. In both cases nothing
# is printed, rather than inventing a line.
push(@steps, 'if [ -n "$OLDREF" ] && [ "$OLDREF" != "$NEWREF" ]; then '.
	     'git --git-dir='.$R.' log --oneline --no-decorate "$OLDREF..$NEWREF"; '.
	     'git --git-dir='.$R.' diff --stat "$OLDREF" "$NEWREF"; fi');
return @steps;
}

# Deploy: write the bare repository's branch into the target.
# checkout -f makes the working copy match the branch: TRACKED files deleted in
# the repository are deleted here too, while UNTRACKED files (uploads, .env) are
# left alone - only 'git clean' would remove those, and it is not used.
# No path is given ('-- .') so that HEAD moves to the branch as well.
sub deploy_steps
{
my ($d, $dep) = @_;
my $R = quotemeta(&deploy_repo_path($d, $dep));
my $T = quotemeta(&deploy_target_dir($d, $dep));
my $B = quotemeta($dep->{'branch'});
my @steps;
push(@steps, "mkdir -p $T");
# checkout's "Already on 'main'" line is kept deliberately. It was measured to
# be identical in all three cases (first write, nothing changed, real change),
# so it says nothing about whether the deploy did anything - the panel already
# says that. Silencing it with '-q' left the deploy section at a single line,
# which read as too bare.
push(@steps, "git --git-dir=$R --work-tree=$T checkout -f $B");
# The commit that went live. '--oneline' is git's OWN format and matches the
# commit list in the pull section; the previous --pretty=format was ours.
push(@steps, "git --git-dir=$R --work-tree=$T log -1 --oneline --no-decorate");
return @steps;
}

# Post-deploy commands. The user's lines run in the target directory with the
# domain's own privileges. Under 'set -e' they stop at the FIRST failure: a
# half-finished deploy is not counted as success.
sub action_steps
{
my ($d, $dep) = @_;
return ( ) if (!$dep->{'actions_on'});
my $cmds = &actions_read($d, $dep);
return ( ) if ($cmds !~ /\S/);
my $target = &deploy_target_dir($d, $dep);

# The user's block is written to a SCRIPT FILE and invoked in one line. The
# reason: a newline cannot survive the command string - command_as_user
# quotemetas it and bash then reads backslash-newline as a line continuation -
# while 'if' and 'for' need newlines. Written to a file, exactly what was typed
# in the box runs.
#
# The file lives in the domain's OWN directory as its OWN user, which also runs
# it - and having it there is useful, since what ran can be inspected over SSH.
my $file = &actions_script_path($d, $dep);
my $script = "set -e
".
	     "cd ".quotemeta($target)."
";
my $bindir = &ensure_php_path_dir($d, $target);
$script .= "PATH=".quotemeta($bindir).":\"\$PATH\"
" if ($bindir);
# The shell's own tracing: every command is logged as it runs, including
# inside loops and conditionals. Echoing by hand would break multi-line blocks.
$script .= "set -x
";
my $body = $cmds;
$body =~ s/
/
/g;
$body .= "
" if ($body !~ /
$/);
$script .= $body;

&write_user_script($d, $file, $script) || return ( );

# The 'set -x' at the top of the script prints '+ command' as each one runs,
# so the screen already reads like a console; no heading is needed.
my @steps;
# The script carries its own 'set -e', so a failure gives a non-zero exit and
# the outer 'set -e' stops the deploy.
push(@steps, "bash ".quotemeta($file));
return @steps;
}

# actions_script_path(&domain, &deploy) -> path of the script that is run
sub actions_script_path
{
my ($d, $dep) = @_;
return $d->{'home'}."/.vmkit/actions-".$dep->{'id'}.".sh";
}

# write_user_script(&domain, path, content) -> success?
# Writes the file owned by the domain's user and readable/executable only by
# them (0700). Root writes it and hands over ownership: other users must not
# see the content, and the domain itself is what runs it.
sub write_user_script
{
my ($d, $file, $text) = @_;
my $dir = $file;
$dir =~ s/\/[^\/]+$//;
if (!-d $dir) {
	&make_dir($dir, 0700, 1) || return 0;
	&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0700, $dir);
	}
eval {
	no warnings 'once';
	local $main::error_must_die = 1;
	&write_file_contents($file, $text);
	};
return 0 if ($@);
&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0700, $file);
return 1;
}

# run_streaming(command, seconds, &callback) -> (output, timed-out, success)
#
# Reads the output LINE BY LINE, passing each to the callback and collecting
# it. backquote_with_timeout cannot do this: it returns nothing until the
# command finishes, so the page would sit blank through a long
# 'composer install'.
#
# On timeout the process is KILLED: merely stopping the read would leave a
# command running in the background.
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

# Timeout for the whole pull and deploy. 900 when unset: every read carries its
# own default, because a module upgrade does not necessarily add new keys to an
# existing config file.
sub deploy_timeout
{
my $t = $config{'timeout'};
return $t && $t =~ /^\d+$/ && $t > 0 ? $t : 900;
}

# deploy_run(&domain, &deploy, op, [&callback]) -> (success?, output)
#
# With a callback the output is sent line by line and the page fills as the
# work proceeds. Without one it is returned in one piece - the webhook and the
# command line use it that way, having no screen to stream to.
#   op 'pull'   pull only
#   op 'deploy' deploy only (something must have been pulled first)
#   op 'both'   pull and deploy
# Every command runs as the domain's own user, in a single shell session, under
# 'set -e'.
sub deploy_run
{
my ($d, $dep, $op, $cb) = @_;
$op ||= 'both';
my @steps;
push(@steps, &pull_steps($d, $dep))   if ($op eq 'pull' || $op eq 'both');
if ($op eq 'deploy' || $op eq 'both') {
	if ($op eq 'deploy' && !-d &deploy_repo_path($d, $dep)) {
		# With a callback the message must also reach the SCREEN: the
		# page prints only streamed lines and ignores the returned
		# $out, so 'Deploy' with nothing pulled showed a blank screen.
		&$cb($text{'err_nopull'}) if ($cb);
		return (0, $text{'err_nopull'});
		}
	push(@steps, &deploy_steps($d, $dep));
	push(@steps, &action_steps($d, $dep));
	}

# The steps are joined into ONE LINE with ';' - a newline CANNOT be used.
# command_as_user quotemetas the command, which turns a newline into
# backslash-newline, and bash then reads that as a LINE CONTINUATION and
# removes it, gluing the whole script into one line: "set -e" + "echo" becomes
# "set -eecho". (Measured; 'bash -c' fails the same way.)
#
# This is why the user's multi-line block is solved differently: it is written
# to its own script FILE and invoked in one line from here - see action_steps.
my $inner = "set -e; ".join("; ", @steps);
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
# Post-deploy commands (composer install and the like) can take a while.
my $secs = &deploy_timeout();
my ($out, $timed, $ok);
if ($cb) {
	($out, $timed, $ok) = &run_streaming("$cmd 2>&1", $secs, $cb);
	}
else {
	($out, $timed) = &backquote_with_timeout("$cmd 2>&1", $secs);
	$ok = !$timed && !$? ? 1 : 0;
	}
# On timeout the output is NOT overwritten: the lines that streamed so far are
# on screen and belong in the log too. The note is appended.
$out .= "\n".$text{'err_timeout'}."\n" if ($timed);

# The log is a separate file: the key=value format cannot hold a multi-line
# value.
#
# ONLY raw output is written - no date or status header. Both already live in
# the deployment record (last_time, last_op, last_status) and deploylog.cgi
# prints them from there. The header used to format the date with make_date,
# which the theme OVERRIDES to return HTML, so the log page showed a literal
# "<span data-filesize-bytes=...>".
&ensure_log_dir();
# Webmin's tempfile functions expect bareword filehandles, which 'use strict'
# forbids; the same pattern Virtualmin's own plugins use turns it off briefly.
no strict "subs";
&open_tempfile(LOG, ">".&deploy_log_path($d, $dep));
&print_tempfile(LOG, $out);
&close_tempfile(LOG);
use strict "subs";

$dep->{'last_time'}   = time();
$dep->{'last_status'} = $ok ? "ok" : "failed";
$dep->{'last_op'}     = $op;
if ($ok) {
	# The pulled and deployed tips are tracked separately: in manual mode
	# that is what shows "pulled but not published yet".
	my $ref = &current_ref($d, $dep);
	$dep->{'pulled_ref'} = $ref if ($ref && $op ne 'deploy');
	$dep->{'deployed_ref'} = ($dep->{'pulled_ref'} || $ref)
		if ($op ne 'pull');
	}
&save_deploy($d, $dep);

return ($ok, $out);
}

sub op_label
{
my ($op) = @_;
return $op eq 'pull'   ? $text{'op_pull'} :
       $op eq 'deploy' ? $text{'op_deploy'} : $text{'op_both'};
}

# deploy_commits(&domain, &deploy) -> (\@commits, error)
# Commits on the branch in the bare repository. The repository only exists
# after the first pull, so its absence gets an explicit message.
#
# Fields are separated by the unit separator (0x1f): a commit subject can
# contain any punctuation, so no textual separator would be safe.
sub deploy_commits
{
my ($d, $dep) = @_;
my $repo = &deploy_repo_path($d, $dep);
return (undef, $text{'commits_norepo'}) if (!-d $repo);

# The WHOLE branch is listed rather than the last N: the page exists for
# looking at history and there is no obvious place to cut. Each record is one
# line, so even thousands of commits stay small.
my $fmt = '%h%x1f%an%x1f%ad%x1f%s';
my $inner = "git --git-dir=".quotemeta($repo).
	    " log --no-decorate --date=short --format=".quotemeta($fmt).
	    " ".quotemeta($dep->{'branch'});
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 30);
return (undef, $text{'err_timeout'}) if ($timed);
return (undef, $out) if ($?);

my @rv;
foreach my $l (split(/\r?\n/, $out)) {
	next if ($l !~ /\S/);
	my ($h, $an, $ad, $s) = split(/\x1f/, $l, 4);
	push(@rv, { 'hash' => $h, 'author' => $an,
		    'date' => $ad, 'subject' => $s });
	}
return (\@rv, undef);
}


# ---- the edit form -------------------------------------------------------
# Drawn in ONE place because two pages show it: edit_deploy.cgi and
# save_deploy.cgi when "Check repository" is pressed.
#
# Why save_deploy.cgi has to draw it too: the only way to send the form to two
# targets was the button's 'formaction' attribute, but the theme handles form
# submission itself and ignores it, so everything went to the form's action -
# the Check button silently SAVED and returned to the list. The form now always
# posts to save_deploy.cgi, which redraws instead of saving when 'check' was
# pressed.

# deploy_from_in(&domain) -> (&deploy, command-text, is-new)
# Merges the submitted form with the stored record.
sub deploy_from_in
{
my ($d) = @_;
my $new = $in{'new'};
my $dep;
if ($new) {
	$dep = { 'branch' => '', 'target' => 'public_html', 'mode' => 'manual' };
	}
else {
	$dep = &get_deploy($d, $in{'id'});
	return ( ) if (!$dep);
	}
foreach my $f ('name', 'repo', 'branch', 'target', 'mode') {
	$dep->{$f} = $in{$f} if (defined($in{$f}) && $in{$f} ne '');
	}
my $actions;
if ($in{'check'} || $in{'regen'}) {
	# Came from a field action, so what the user typed is in %in.
	$dep->{'actions_on'} = $in{'actions_on'} ? 1 : 0;
	$actions = $in{'actions'};
	}
else {
	$actions = &actions_read($d, $dep);
	}

# If the name was left empty, fill it from the last part of the repository URL
# (".../vmin-kit.git" -> "vmin-kit.git"). Typing a name is usually unnecessary,
# and one that was typed is never touched.
if ($dep->{'repo'} && ($dep->{'name'} || '') !~ /\S/) {
	my $n = $dep->{'repo'};
	$n =~ s/\/+$//;
	$n =~ s/^.*[\/:]//;
	$n =~ s/[^A-Za-z0-9._\- ]//g;
	$dep->{'name'} = $n if ($n =~ /\S/);
	}

# The hook URL is visible while ADDING too. The UUID used to be generated only
# on save, so getting the URL meant "save, go back, edit again". It is now
# generated when the form opens, carried in a hidden field and stored on save.
$dep->{'uuid'} = $in{'uuid'}
	if ($in{'uuid'} && $in{'uuid'} =~ /^[a-f0-9]{32}$/);
$dep->{'uuid'} ||= &new_uuid();

return ($dep, $actions, $new);
}

# print_deploy_form(&domain, &deploy, command-text, is-new)
sub print_deploy_form
{
my ($d, $dep, $actions, $new) = @_;

# With a repository URL, query the branches (ls-remote only, no clone).
my ($defbranch, $branches, $rerr);
if ($dep->{'repo'}) {
	($defbranch, $branches, $rerr) = &remote_branches($d, $dep->{'repo'});
	$dep->{'branch'} ||= $defbranch;
	}

if ($rerr) {
	print "<p><b>$text{'edit_echeck'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($rerr),"</pre>\n";
	# For a private repository the domain's SSH key must be added to the
	# GitHub/Gitea ACCOUNT.
	print "<p>",&ui_link("sshkey.cgi?dom=$d->{'id'}&new=$new&id=$dep->{'id'}".
			     "&repo=".&urlize($dep->{'repo'}),
			     $text{'edit_showkey'}),"</p>\n";
	}

print &ui_form_start("save_deploy.cgi", "post");
print &ui_hidden("dom", $d->{'id'});
print &ui_hidden("new", $new);
print &ui_hidden("id", $dep->{'id'});
# The hook UUID is generated before saving; hidden so it survives the round trip.
print &ui_hidden("uuid", $dep->{'uuid'});
print &ui_table_start($text{'edit_header'}, "width=100%", 2);

print &ui_table_row($text{'edit_name'},
	&ui_textbox("name", $dep->{'name'}, 30));

# The Check button sits NEXT TO THE URL: it acts on that field and has nothing
# to do with the save/delete buttons at the bottom. It is a separately named
# submit in the same form, which save_deploy.cgi reads to redraw instead of save.
print &ui_table_row($text{'edit_repo'},
	&ui_textbox("repo", $dep->{'repo'}, 50)." ".
	&ui_submit($text{'edit_check'}, "check")."<br>".
	"<font size=-1>$text{'edit_repo_help'}</font>");

# The branch cannot be chosen until the repository is read - the only field
# that depends on it.
print &ui_table_row($text{'edit_branch'},
	$branches ? &ui_select("branch", $dep->{'branch'}, $branches, 1, 0, 0)
		  : &ui_select("branch", undef, [ ], 1, 0, 0, 1)." ".
		    "<font size=-1>$text{'edit_branch_check'}</font>");

print &ui_table_row($text{'edit_target'},
	"<tt>".&deploy_root($d)."/</tt> ".
	&ui_textbox("target", &target_sub($d, $dep->{'target'}), 25)."<br>".
	"<font size=-1>$text{'edit_target_help'}</font>");

# A dropdown rather than radio buttons: side by side, the two radios did not
# even read as a setting.
print &ui_table_row($text{'edit_mode'},
	&ui_select("mode", $dep->{'mode'} || 'manual',
		   [ [ "manual", $text{'mode_manual_desc'} ],
		     [ "auto",   $text{'mode_auto_desc'} ] ], 1, 0, 0));

print &ui_table_row($text{'edit_actions'},
	&ui_checkbox("actions_on", 1, $text{'edit_actions_on'},
		     $dep->{'actions_on'} ? 1 : 0)."<br>".
	&ui_textarea("actions", $actions, 6, 70)."<br>".
	"<font size=-1>".
	&text('edit_actions_help',
	      "<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>").
	"</font>");

# The hook URL lives in the SAME table. In a form of its own it ended up at the
# bottom of the page, when it is a field of the deployment and belongs with the
# others. Its regenerate button sits beside it - same form, separate submit.
#
# The URL is in a read-only box: it is long and meant to be copied, and as
# plain text among the other text it was both hard to select and easy to miss.
print &ui_table_row($text{'edit_hook'},
	&ui_textbox("hookurl", &hook_url($dep) || '', 60, 0, undef,
		    "readonly onClick='this.select()'")." ".
	&ui_submit($text{'edit_hook_regen'}, "regen")."<br>".
	"<font size=-1>$text{'edit_hook_help'}</font>".
	($new ? "<br><font size=-1>$text{'edit_hook_new'}</font>" : "").
	(&hook_path_registered() ? "" :
		"<br><b>$text{'edit_hook_notready'}</b>"));

print &ui_table_end();

# Only save and delete at the bottom: field-level actions stay on their rows.
# Button array: [ name, label, append, disabled, extra attribute ]
# Save is disabled until the repository is verified - saving without a branch
# means nothing.
my @buttons = ( [ undef, $new ? $text{'create'} : $text{'save'},
		  undef, $branches ? 0 : 1 ] );
push(@buttons, [ "delete", $text{'delete'} ]) if (!$new);
print &ui_form_end(\@buttons);
}

# ---- the webhook ---------------------------------------------------------
# The same model Plesk uses: the UUID in the URL IS the credential. Whoever
# knows the URL can trigger it, whoever does not, cannot.
#
# Deliberately NOT done, and why:
#   - No signature verification (GitHub's X-Hub-Signature-256). It would tie
#     the hook to GitHub and break Gitea, GitLab and a plain 'curl'. The UUID
#     works everywhere.
#   - The request body is NEVER READ. Repository, branch and target are already
#     stored; the payload tells us nothing new.
#
# The cost: since the URL is a credential it appears in the server's access
# logs, and sharing the URL is sharing the credential. If it leaks, regenerate
# it from the form and the old one dies immediately. Plesk is no different.

# new_uuid() -> a 128-bit random id (32 hex characters)
sub new_uuid
{
my $h;
if (open($h, "<", "/dev/urandom")) {
	my $b;
	my $n = read($h, $b, 16);
	close($h);
	return unpack("H*", $b) if ($n == 16);
	}
# /dev/urandom exists on every Linux, so this should never be reached - but a
# weak id beats silently producing an empty one.
return sprintf("%08x%08x%08x%08x", time(), $$, int(rand(0xffffffff)),
	       int(rand(0xffffffff)));
}

# find_by_uuid(uuid) -> (&domain, &deploy), or empty
# Every domain's deployments are scanned: the hook runs without authentication,
# so the UUID is the only thing that says which domain this is.
sub find_by_uuid
{
my ($uuid) = @_;
return ( ) if (!$uuid || $uuid !~ /^[a-f0-9]{16,64}$/);
foreach my $dep (&list_deploys()) {
	next if (($dep->{'uuid'} || '') ne $uuid);
	my $d = &virtual_server::get_domain($dep->{'dom'});
	next if (!$d || !$d->{'vmkit-deploy'});
	return ($d, $dep);
	}
return ( );
}

# hook_url(&deploy) -> the full URL
# The host name is never GUESSED: whatever address the page was opened from is
# the hook's address too. Behind the proxy, ProxyPreserveHost already makes
# that the external name (webmin.<domain>).
sub hook_url
{
my ($dep) = @_;
return undef if (!$dep->{'uuid'});
my $host = $ENV{'HTTP_HOST'} || $ENV{'SERVER_NAME'} || "";
return undef if (!$host);
return "https://$host/$module_name/hook.cgi?uuid=$dep->{'uuid'}";
}

# ---- miniserv: the path that needs no login ------------------------------
# The hook URL has to be reachable without signing in, which is a Webmin
# setting. Its NAME is never guessed: the installed miniserv source is read to
# find which key it uses, so a rename between versions is picked up here.
sub miniserv_source
{
my $src = "";
foreach my $f ("miniserv-lib.pl", "miniserv.pl") {
	my $p = "$root_directory/$f";
	$src .= &read_file_contents($p) if (-r $p);
	}
return $src;
}

# unauth_key() -> the miniserv key the hook path is written to
#
# 'unauthcgi', NOT 'unauth'. They share a mechanism but mean different things:
#
#   foreach my $u (@unauth)    { $unauth = 4 if ($simple =~ /$u/); }
#   foreach my $u (@unauthcgi) { $unauth = 3 if ($simple =~ /$u/); }
#
# and the execution gate:
#
#   if (&get_type($full) eq "internal/cgi" && $validated != 4) { ... CGI ... }
#
# So a .cgi listed in 'unauth' is NOT EXECUTED - its source is sent as a file.
# Measured: a session-less request returned '200 internal/cgi' and the Perl
# source of hook.cgi, and the hook never fired. From a logged-in browser it
# looked like it worked, because then the list is never consulted at all.
#
# 'unauthcgi' gives $validated=3, executes the CGI and sets ANONYMOUS_USER=1,
# which is what we want.
#
# Returns undef when the key is absent from the installed source: not
# registering the hook is better than writing to the wrong place, and falling
# back to 'unauth' would serve the source code.
sub unauth_key
{
my $src = &miniserv_source();
return $src =~ /["']unauthcgi["']/ ? "unauthcgi" : undef;
}

# unauth_default(key) -> the default list compiled into miniserv
#
# WITHOUT THIS FUNCTION THE PLUGIN BROKE WEBMIN. The default lists are not in
# miniserv.conf but in miniserv's %vital table, and they apply only while the
# key is absent from the file:
#
#   foreach my $v (keys %vital) { if (!$config{$v}) { $config{$v} = $vital{$v} } }
#
# So "append to the value in the file" REPLACED the list with our single path,
# because the file had no value. For 'unauthcgi' that default is Webmin's
# password-recovery pages, which must not be deleted either.
#
# The list is NEVER COPIED BY HAND: it is read from the installed source so it
# cannot drift when Webmin changes. The string there is double-quoted, so
# escapes like '\$' are resolved by Perl and are resolved here too - in a regex
# '\$' and '$' are not the same thing.
sub unauth_default
{
my ($key) = @_;
my $src = &miniserv_source();
return "" if (!$src || !$key);
return "" if ($src !~ /["']\Q$key\E["']\s*,\s*"((?:[^"\\]|\\.)*)"/);
my $def = $1;
$def =~ s/\\([\$\@\\"])/$1/g;
return $def;
}

# wanted_unauth_list(key, current) -> what the list should be
# The default, plus whatever is already in the file, plus our path, in order
# and without duplicates. Entries already in the file are kept: if something
# else added a path, removing it is not ours to do.
sub wanted_unauth_list
{
my ($key, $cur) = @_;
my @want;
my %seen;
foreach my $p (split(/\s+/, &unauth_default($key)),
	       split(/\s+/, $cur || ''),
	       &hook_path()) {
	next if ($p eq '' || $seen{$p}++);
	push(@want, $p);
	}
return join(" ", @want);
}

# List entries are evaluated as REGEXES ($simple =~ /$u/), not as literals.
# Unanchored, the path would match anywhere in a URL.
sub hook_path
{
return "^/$module_name/hook\\.cgi\$";
}

sub miniserv_conf
{
return "$ENV{'WEBMIN_CONFIG'}/miniserv.conf";
}

# hook_path_registered() -> is the path in the list?
sub hook_path_registered
{
my $conf = &miniserv_conf();
return 0 if (!-r $conf);
my $key = &unauth_key();
return 0 if (!$key);
my $cur = "";
foreach my $l (split(/\n/, &read_file_contents($conf))) {
	$cur = $1 if ($l =~ /^\Q$key\E=(.*)$/);
	}
my $p = &hook_path();
return (grep { $_ eq $p } split(/\s+/, $cur)) ? 1 : 0;
}

# ensure_hook_path() -> (changed?, error)
# Adds the path to the list and reloads miniserv. Idempotent: does nothing when
# it is already right, so it can be called on every install.
sub ensure_hook_path
{
my $conf = &miniserv_conf();
return (0, undef) if (!-r $conf);
my $key = &unauth_key();
return (0, &text('hook_econf', $conf)) if (!$key);
my %mc;
&read_file($conf, \%mc);
my $cur = $mc{$key};

# If the default cannot be read, nothing is written: an incomplete list would
# break Webmin's own pages. Appending to an existing value is safe, because
# then there is no default being overwritten.
my $def = &unauth_default($key);
if ($def eq '' && ($cur || '') eq '') {
	return (0, &text('hook_econf', $conf));
	}

my $want = $def eq '' ? join(" ", grep { $_ ne '' }
				  (split(/\s+/, $cur || ''), &hook_path()))
		      : &wanted_unauth_list($key, $cur);
# Compared by content, not by "is our path there": on installs an older version
# broke, our path was present but the defaults were missing, and this is what
# repairs them.
return (0, undef) if (($cur || '') eq $want);
return (0, &text('hook_econf', $conf)) if (!-w $conf);
$mc{$key} = $want;
&lock_file($conf);
&write_file($conf, \%mc);
&unlock_file($conf);
# The setting only takes effect once miniserv reloads. Webmin's own function
# does that without killing the request in flight - the same call its
# Configuration pages use.
if (defined(&restart_miniserv)) {
	eval { &restart_miniserv(1); };
	}
return (1, undef);
}

# remove_hook_path() - removes the path from the list when the module is removed.
sub remove_hook_path
{
my $conf = &miniserv_conf();
return 0 if (!-w $conf);
my $key = &unauth_key();
return 0 if (!$key);
my %mc;
&read_file($conf, \%mc);
my $p = &hook_path();
my @keep = grep { $_ ne '' && $_ ne $p } split(/\s+/, $mc{$key} || '');
return 0 if (join(" ", @keep) eq ($mc{$key} || ''));
# If only the default remains, the key is deleted entirely: miniserv then uses
# its built-in list and no copy of ours is left in miniserv.conf.
if (join(" ", @keep) eq &unauth_default($key)) {
	delete($mc{$key});
	}
else {
	$mc{$key} = join(" ", @keep);
	}
&lock_file($conf);
&write_file($conf, \%mc);
&unlock_file($conf);
if (defined(&restart_miniserv)) {
	eval { &restart_miniserv(1); };
	}
return 1;
}

1;
