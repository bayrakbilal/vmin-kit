#!/usr/bin/perl
# The job the webhook runs in the background.
#   hook-run.pl <domain-id> <deploy-id> <pull|deploy|both>
#
# It is a separate process because hook.cgi must answer immediately (GitHub
# drops the connection after ~10 seconds) while a deploy and its post-deploy
# commands can take minutes.
#
# Output goes to the deployment's OWN log - hook.cgi redirects it there,
# truncating - so there is no second log file to grow and errors stay where
# the panel already looks.
use strict;
use warnings;

# UNBUFFERED. Our output is redirected into the deployment's log file, and
# perl block-buffers when writing to a file: the start line would sit in the
# buffer, deploy_run would rewrite the same file, and the buffer flush at exit
# would then OVERWRITE THE BEGINNING OF THE WRITTEN LOG. Observed as a log
# truncated in the middle.
$| = 1;

# CLEAR THE CGI ENVIRONMENT - these lines must come BEFORE the library.
#
# hook.cgi starts this script with system(), which passes its environment on
# unchanged, CGI variables included (REQUEST_METHOD, HTTP_HOST, SCRIPT_NAME).
# Webmin's init_config sees them, believes it is serving a WEB REQUEST and
# applies the referer check. There is no referer, so it printed the "Security
# Warning" page and exited: the hook answered "accepted" while the background
# job never started.
#
# PATH is kept; PATH_INFO and PATH_TRANSLATED are listed explicitly because
# they are CGI variables.
foreach my $k (keys %ENV) {
	delete($ENV{$k}) if ($k =~ /^(HTTP_|CONTENT_|REQUEST_|SCRIPT_|SERVER_|
				      QUERY_|REMOTE_|GATEWAY_|AUTH_|REDIRECT_|
				      PATH_INFO$|PATH_TRANSLATED$|
				      DOCUMENT_ROOT$|HTTPS$)/x);
	}

$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
# Webmin's own globals; assigned once, hence the 'used only once' warning.
no warnings 'once';
$main::no_acl_check++;
# Should be unnecessary now the environment is clean, but it guarantees the
# referer check cannot reach this script by any route.
$main::trust_unknown_referers = 1;
$main::no_referers_check = 1;
use warnings 'once';
if ($0 =~ /^(.*)\/[^\/]+$/) { chdir($1); }
require './vmkit-deploy-lib.pl';

my ($domid, $depid, $op) = @ARGV;

# Only what happens BEFORE deploy_run is logged here - once it is reached,
# deploy_run rewrites the same file itself. Completion is not logged again:
# writing to one file from two places would leave this process appending at
# its old offset after deploy_run truncated it.
#
# Logging the start is still required: if the work never reaches deploy_run
# there is no other trace - the hook said "accepted" and the panel shows
# nothing.
sub hlog { print scalar(localtime()), " hook-run: ", @_, "\n"; }
sub hbail { &hlog("ERROR: ", @_); exit(2); }

&hlog("started dom=", $domid || '?', " dep=", $depid || '?',
     " op=", $op || '?');
$domid && $depid || &hbail("missing parameter");
$op = 'pull' if (!$op || $op !~ /^(pull|deploy|both)$/);

my $d = &virtual_server::get_domain($domid);
$d || &hbail("domain not found: $domid");
$d->{'vmkit-deploy'} || &hbail("git deploy is off for this domain: $d->{'dom'}");
my $dep = &get_deploy($d, $depid);
$dep || &hbail("deployment not found: $depid");

# Record what triggered the run so the list can show it: manual or hook.
$dep->{'last_trigger'} = 'hook';
my ($ok, undef) = &deploy_run($d, $dep, $op);
exit($ok ? 0 : 1);
