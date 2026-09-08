#!/usr/bin/perl
# Web kancasi: adresteki UUID dogruysa deployment'i tetikler.
#
# BU SAYFA GIRIS ISTEMEZ - yolu miniserv'in kimlik dogrulamasi istemeyen
# listesine ekliyoruz (ensure_hook_path). Yetkilendirme UUID'nin kendisidir.
#
# Iki kural:
#   1. Cevabi HEMEN dondururuz. Deploy'u burada calistirsaydik GitHub ~10
#      saniyede baglantiyi keserdi; 'composer install' tek basina bundan
#      uzun surebiliyor. Is ayri bir surece veriliyor (hook-run.pl).
#   2. Gelen govde HIC OKUNMAZ. Repo, dal ve hedef zaten kayitli. Boylece
#      kanca GitHub'a ozel olmuyor: Gitea, GitLab ya da elle 'curl' de calisir.
use strict;
use warnings;

# Giris yapilmadan calistigi icin ACL baglami yok.
BEGIN { $main::no_acl_check++; }
our (%in, $module_root_directory);

require './vmkit-deploy-lib.pl';
&ReadParse();

# Duz metin cevap: bu sayfayi bir insan degil bir servis okuyor.
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
	# Bilinmeyen kimlikte hicbir ipucu vermiyoruz: var olan bir deployment'in
	# adresini aramak ile bulmak arasindaki farki disariya sizdirmayalim.
	&reply("404 Not Found", "not found");
	exit(0);
	}

# Ne yapilacagi deployment'in MODUNA bagli: otomatikse cek+dagit, manuelse
# yalnizca cek (dagitimi panelden sen baslatirsin).
my $op = ($dep->{'mode'} || 'manual') eq 'auto' ? 'both' : 'pull';

# Isi arka plana ver ve hemen cevap don. Surec kabuktan '&' ile ayriliyor,
# cikti /dev/null'a gidiyor: bu CGI bittiginde is olmuyor, init'e devrediliyor.
my $runner = "$module_root_directory/hook-run.pl";
my $cmd = "$runner ".quotemeta($d->{'id'})." ".quotemeta($dep->{'id'}).
	  " ".quotemeta($op);
system("$cmd </dev/null >/dev/null 2>&1 &");

&reply("202 Accepted", "accepted: $op");
