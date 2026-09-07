#!/usr/bin/perl
# Komut satirindan senkron. Zamanlayici (ve varsa dosya izleyici) bunu calistirir.
#
#   sync-all.pl            yalnizca zone'u degismis domainleri senkronlar
#   sync-all.pl --force    hepsini senkronlar
#   sync-all.pl --list     ne yapacagini yazar, hicbir sey degistirmez
#
# Zone degismediyse hicbir API cagrisi yapilmaz: zamanlayici sik calissa bile
# Cloudflare'e gereksiz istek gitmez.
use strict;
use warnings;

$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
$main::no_acl_check++;
if ($0 =~ /^(.*)\/[^\/]+$/) { chdir($1); }
require './vmkit-cloudflare-lib.pl';

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
		       $due ? "senkron gerekiyor" : "degisiklik yok");
		next;
		}
	next if (!$due);
	print "== $d->{'dom'}\n";
	my ($ok, $err) = &run_sync($d, sub { print "   ".$_[0]."\n"; });
	if ($err) {
		print "   HATA: $err\n";
		$rc = 1;
		}
	else {
		# Yalnizca basarili turdan sonra isaretliyoruz; hata olursa
		# bir sonraki calismada yeniden denensin.
		&mark_synced($d) if ($ok);
		$rc = 1 if (!$ok);
		}
	}
exit($rc);
