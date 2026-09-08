#!/usr/bin/perl
# Web kancasinin arka planda calistirdigi is.
#   hook-run.pl <domain-id> <deploy-id> <pull|deploy|both>
#
# Ayri bir surec olmasinin sebebi: hook.cgi cevabi hemen dondurmek zorunda
# (GitHub ~10 saniyede baglantiyi keser), oysa dagitim ve dagitim sonrasi
# komutlar dakikalar surebiliyor.
#
# Cikti deployment'in KENDI loguna gidiyor (hook.cgi ustune yazarak
# yonlendiriyor): ayri bir kutuk tutup her cagrida sisirmiyoruz, hataya da
# panelde her zaman bakilan yerden bakiliyor.
use strict;
use warnings;

# TAMPONSUZ YAZ. Ciktimiz deployment'in log dosyasina yonlendirilmis durumda
# ve perl, dosyaya yazarken satir tamponlamasi yerine blok tamponlamasi
# kullaniyor: baslangic satiri tamponda bekler, deploy_run ayni dosyayi bastan
# yazar, sonra surec cikarken tampon bosalir ve YAZILMIS LOGUN BASINI EZER.
# Olculdu: log "igi burada" gibi ortasindan kirpilmis halde kaliyordu.
$| = 1;

# CGI ORTAMINI TEMIZLE - bu satirlar kutuphaneden ONCE gelmek zorunda.
#
# Betik hook.cgi'nin icinden system() ile calistiriliyor ve system() cagiran
# surecin ortamini oldugu gibi devrediyor. Icinde REQUEST_METHOD, HTTP_HOST,
# SCRIPT_NAME gibi CGI degiskenleri var; Webmin'in init_config'i bunlari
# gorunce kendini bir WEB ISTEGI saniyor ve referer kontrolunu uyguluyor.
# Referer yok, dolayisiyla "Security Warning" sayfasini basip cikiyordu:
# kanca "accepted" diyor, arka plandaki is ise hic baslamiyordu.
#
# PATH silinmiyor; PATH_INFO ve PATH_TRANSLATED birer CGI degiskeni oldugu
# icin acikca sayiliyorlar.
foreach my $k (keys %ENV) {
	delete($ENV{$k}) if ($k =~ /^(HTTP_|CONTENT_|REQUEST_|SCRIPT_|SERVER_|
				      QUERY_|REMOTE_|GATEWAY_|AUTH_|REDIRECT_|
				      PATH_INFO$|PATH_TRANSLATED$|
				      DOCUMENT_ROOT$|HTTPS$)/x);
	}

$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
# Webmin'in kendi degiskenleri; bir kez atandiklari icin 'used only once'
# uyarisi veriyorlar.
no warnings 'once';
$main::no_acl_check++;
# Ortami temizledigimiz icin gerekmemeli, ama referer kontrolunun bu betige
# hicbir yoldan bulasmamasini garantiye aliyoruz.
$main::trust_unknown_referers = 1;
$main::no_referers_check = 1;
use warnings 'once';
if ($0 =~ /^(.*)\/[^\/]+$/) { chdir($1); }
require './vmkit-deploy-lib.pl';

my ($domid, $depid, $op) = @ARGV;

# Bu betigin ciktisi DEPLOYMENT'IN LOGUNA gidiyor: hook.cgi oraya yonlendirdi,
# ustune yazarak. Yalnizca deploy_run'a GELENE KADAR olanlari yaziyoruz -
# oraya varirsa deploy_run ayni dosyayi zaten bastan yaziyor. Isin bittigini
# burada bir daha yazmiyoruz: ayni dosyaya iki yerden yazmak, deploy_run
# dosyayi kisalttiktan sonra bu surecin eski konumundan devam etmesi olurdu.
#
# Basladigini yazmak yine de sart: is deploy_run'a hic ulasamazsa ortada
# baska hicbir iz kalmaz - kanca "accepted" der, panelde bir sey gorunmez.
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
exit($ok ? 0 : 1);
