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

# Iki KONTROLUN DISINDA kalmamiz gerekiyor ve ikisi ayri seyler:
#
#   no_acl_check           Giris yapilmadan calistigimiz icin ACL baglami yok.
#                          Yolun giris istememesi ayrica miniserv'de ayarli
#                          (ensure_hook_path).
#
#   trust_unknown_referers Webmin her istegin Referer basligini kendi adresiyle
#                          karsilastiriyor; referer hic yoksa referers_none
#                          kurali devreye girip istegi "Security Warning" ile
#                          reddediyor. Kancayi cagiran GitHub'in (ya da adresi
#                          adres cubuguna yapistiran kisinin) referer'i yok,
#                          dolayisiyla bu sayfa o kontrolun disinda kalmali.
#
# Guvenligi ZAYIFLATMIYOR: referer kontrolu CSRF'e karsidir, yani giris yapmis
# bir yoneticinin tarayicisinin kandirilmasina. Burada yetki oturumdan degil
# adresteki UUID'den geliyor; UUID'yi bilen zaten dogrudan cagirabilir.
# Ayarin kendisi (referers_none) sunucu genelinde ACIK kaliyor, yalnizca bu
# sayfa muaf.
# Webmin surumleri bu muafiyeti iki farkli adla tasidi; ikisini de
# yaziyoruz. Kullanilmayan bir global zararsiz, eksik olani ise sayfayi
# calismaz kilardi.
BEGIN {
	no warnings 'once';
	$main::no_acl_check++;
	$main::trust_unknown_referers = 1;
	$main::no_referers_check = 1;
	}
our (%in, %text, $module_root_directory);

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

# Isi arka plana ver ve hemen cevap don. Surec kabuktan '&' ile ayriliyor:
# bu CGI bittiginde is olmuyor, init'e devrediliyor.
my $runner = "$module_root_directory/hook-run.pl";
if (!-r $runner) {
	# Sessizce "accepted" deyip hicbir sey yapmamak en kotusu: cagiran
	# taraf basarili sandi, panelde de iz yok.
	&reply("500 Internal Server Error", "runner missing: $runner");
	exit(0);
	}

# Cikti /dev/null'a DEGIL deployment'in KENDI loguna gidiyor - ve ekleyerek
# degil, USTUNE yazarak ('>'), yani her cagrida buyuyen bir dosya olusmuyor.
#
# Ayri bir kutuk (hook.log) da dogru degildi: sonsuza kadar buyuyor ve hatayi
# panelde bakilan yerden baska bir yere koyuyordu. Is deploy_run'a kadar
# gelirse o zaten bu dosyayi bastan yaziyor; gelemezse dosyada hic baslamama
# sebebi kaliyor - ki bakilacak yer yine ayni: deployment'in logu.
&ensure_log_dir();
my $log = &deploy_log_path($d, $dep);

# Kabuk yerine dogrudan perl: betigin calistirilabilir biti eksikse ya da
# shebang'i bu sistemde yoksa is sessizce hic baslamazdi. Yorumlayici olarak
# $^X, yani SU ANDA calisan perl - PATH'e bagli kalmiyoruz.
my $cmd = quotemeta($^X)." ".quotemeta($runner)." ".quotemeta($d->{'id'})." ".
	  quotemeta($dep->{'id'})." ".quotemeta($op);
system("$cmd </dev/null >".quotemeta($log)." 2>&1 &");

&reply("202 Accepted", "accepted: $op");
