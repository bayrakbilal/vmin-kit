#!/usr/bin/perl
# Syncing from the command line. The timer (and the file watcher, where there
# is one) runs this.
#
#   sync-all.pl            syncs only domains whose zone has changed
#   sync-all.pl --force    syncs all of them
#   sync-all.pl --list     prints what it would do and changes nothing
#
# An unchanged zone makes no API call at all, so a frequent timer does not mean
# needless requests to Cloudflare.
use strict;
use warnings;

$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
# Webmin's own global; assigned once, so it triggers 'used only once' and that
# warning landed in the log on every run.
no warnings 'once';
$main::no_acl_check++;
use warnings 'once';
if ($0 =~ /^(.*)\/[^\/]+$/) { chdir($1); }
require './vmkit-cloudflare-lib.pl';

# The service watches itself: if the instant trigger (.path) has stopped, it is
# brought back up here, so the sync recovers without anyone opening the panel.
# With everything in place this does nothing.
{
my $st = &sync_units_status();
if ($st->{'systemd'} && !&sync_units_healthy($st)) {
	my ($done, $err) = &ensure_sync_units();
	print "units: ", ($err ? "ERROR: $err" : join(", ", @$done)), "\n"
		if ($err || @$done);
	}
}

my ($force, $list);
foreach my $a (@ARGV) {
	if    ($a eq '--force') { $force = 1; }
	elsif ($a eq '--list')  { $list = 1; }
	else { print STDERR "usage: sync-all.pl [--force] [--list]\n"; exit(2); }
	}

my $rc = 0;
foreach my $d (&sync_domains()) {
	my $due = $force || &needs_sync($d);
	if ($list) {
		printf("%-30s %s\n", $d->{'dom'},
		       $due ? "sync needed" : "no change");
		next;
		}
	next if (!$due);
	print "== $d->{'dom'}\n";
	my ($ok, $err) = &run_sync($d, sub { print "   ".$_[0]."\n"; });
	if ($err) {
		print "   ERROR: $err\n";
		$rc = 1;
		}
	else {
		# Only a successful run is marked, so a failure is retried on
		# the next one.
		&mark_synced($d) if ($ok);
		$rc = 1 if (!$ok);
		}
	}
exit($rc);
