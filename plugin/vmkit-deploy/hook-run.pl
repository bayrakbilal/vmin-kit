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

# Bu betigin ciktisi hook.log'a gidiyor. Basladigini ve bittigini YAZIYORUZ:
# "kanca calisti mi hic" sorusunun cevabi baska hicbir yerde yok - islem
# basarisiz olsa bile deployment logu yazilir ama is hic BASLAMADIYSA ortada
# tek bir iz olmaz.
sub hlog { print scalar(localtime()), " hook-run: ", @_, "\n"; }
sub hbail { &hlog("HATA: ", @_); exit(2); }

&hlog("basladi dom=", $domid || '?', " dep=", $depid || '?',
     " op=", $op || '?');
$domid && $depid || &hbail("eksik parametre");
$op = 'pull' if (!$op || $op !~ /^(pull|deploy|both)$/);

my $d = &virtual_server::get_domain($domid);
$d || &hbail("domain bulunamadi: $domid");
$d->{'vmkit-deploy'} || &hbail("git deploy bu domainde kapali: $d->{'dom'}");
my $dep = &get_deploy($d, $depid);
$dep || &hbail("deployment bulunamadi: $depid");

# Kimin tetikledigi listede gorunsun: elle mi, kancadan mi.
$dep->{'last_trigger'} = 'hook';
my ($ok, undef) = &deploy_run($d, $dep, $op);
&hlog("bitti ", $ok ? "OK" : "BASARISIZ", " - ayrinti deployment logunda");
exit($ok ? 0 : 1);
