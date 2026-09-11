#!/usr/bin/perl
# The webhook: triggers a deployment when the UUID in the URL is valid.
#
# THIS PAGE REQUIRES NO LOGIN - its path is registered in miniserv's list of
# paths that run without authentication (ensure_hook_path). The UUID is the
# authorisation.
#
# Two rules:
#   1. Answer IMMEDIATELY. Running the deploy here would exceed GitHub's ~10
#      second timeout - 'composer install' alone can take longer. The work is
#      handed to a separate process (hook-run.pl).
#   2. The request body is NEVER READ. Repository, branch and target are
#      already stored, which keeps the hook provider-agnostic: Gitea, GitLab
#      and a plain 'curl' work just as well.
use strict;
use warnings;

# Two separate checks are bypassed here:
#
#   no_acl_check           We run without a login, so there is no ACL context.
#
#   trust_unknown_referers Webmin rejects a request with no Referer header
#                          ("Security Warning"), and the caller - GitHub, or
#                          someone pasting the URL - sends none. Exempting
#                          this page does not weaken anything: the referer
#                          check defends against CSRF, and here the
#                          authorisation is the UUID, not a session. The
#                          setting stays on server-wide.
#
# Webmin carried this exemption under two names; both are set, because an
# unused global is harmless while a missing one would break the page.
BEGIN {
	no warnings 'once';
	$main::no_acl_check++;
	$main::trust_unknown_referers = 1;
	$main::no_referers_check = 1;
	}
our (%in, %text, $module_root_directory);

require './vmkit-deploy-lib.pl';
&ReadParse();

# Plain text: a service reads this page, not a person.
sub reply
{
my ($status, $body) = @_;
print "Status: $status\r\n";
print "Content-type: text/plain; charset=utf-8\r\n";
print "\r\n";
print "$body\n";
}

my ($d, $dep) = &find_by_uuid($in{'uuid'});
if (!$dep) {
	# An unknown UUID gives nothing away: guessing a deployment URL must not
	# be distinguishable from hitting an existing one.
	&reply("404 Not Found", "not found");
	exit(0);
	}

# What happens depends on the deployment's MODE: automatic means pull+deploy,
# manual means pull only (the deploy is started from the panel).
my $op = ($dep->{'mode'} || 'manual') eq 'auto' ? 'both' : 'pull';

# Hand the work to the background and answer at once. The process is detached
# with '&', so it is not killed when this CGI exits - init adopts it.
my $runner = "$module_root_directory/hook-run.pl";
if (!-r $runner) {
	# Answering "accepted" and doing nothing would be the worst outcome: the
	# caller believes it succeeded and the panel shows no trace.
	&reply("500 Internal Server Error", "runner missing: $runner");
	exit(0);
	}

# Output goes to the deployment's OWN log, not /dev/null, and it TRUNCATES
# ('>') rather than appends, so no file grows without bound.
#
# A separate hook.log would put the error somewhere other than where the panel
# looks. If the work reaches deploy_run it rewrites this file anyway; if it
# does not, the reason for never starting is left here - the same place to
# look either way.
&ensure_log_dir();
my $log = &deploy_log_path($d, $dep);

# Perl is invoked directly instead of relying on the script being executable:
# a missing execute bit or a shebang that does not exist on this system would
# silently stop the job from ever starting. The interpreter is $^X, the perl
# running right now, so the result does not depend on PATH.
my $cmd = quotemeta($^X)." ".quotemeta($runner)." ".quotemeta($d->{'id'})." ".
	  quotemeta($dep->{'id'})." ".quotemeta($op);
system("$cmd </dev/null >".quotemeta($log)." 2>&1 &");

&reply("202 Accepted", "accepted: $op");
