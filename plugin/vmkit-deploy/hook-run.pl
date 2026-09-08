#!/usr/bin/perl
# Web kancasinin arka planda calistirdigi is.
#   hook-run.pl <domain-id> <deploy-id> <pull|deploy|both>
#
# Ayri bir surec olmasinin sebebi: hook.cgi cevabi hemen dondurmek zorunda
# (GitHub ~10 saniyede baglantiyi keser), oysa dagitim ve dagitim sonrasi
# komutlar dakikalar surebiliyor.
#
# Ciktiyi kimse okumuyor; sonuc her zamanki yere, deployment'in kendi loguna
# yaziliyor (deploy_run) ve panelden gorunuyor.
use strict;
use warnings;

$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
# Webmin'in kendi degiskeni; bir kez atandigi icin 'used only once' uyarisi
# veriyor.
no warnings 'once';
$main::no_acl_check++;
use warnings 'once';
if ($0 =~ /^(.*)\/[^\/]+$/) { chdir($1); }
require './vmkit-deploy-lib.pl';

my ($domid, $depid, $op) = @ARGV;
$domid && $depid || die "usage: hook-run.pl <domain-id> <deploy-id> [op]\n";
$op = 'pull' if (!$op || $op !~ /^(pull|deploy|both)$/);

my $d = &virtual_server::get_domain($domid);
$d || die "domain not found: $domid\n";
$d->{'vmkit-deploy'} || die "git deploy not enabled for $d->{'dom'}\n";
my $dep = &get_deploy($d, $depid);
$dep || die "deployment not found: $depid\n";

# Kimin tetikledigi listede gorunsun: elle mi, kancadan mi.
$dep->{'last_trigger'} = 'hook';
my ($ok, undef) = &deploy_run($d, $dep, $op);
exit($ok ? 0 : 1);
