# vmkit-cloudflare yardimci fonksiyonlari.
#
# Tasarim: yerel BIND zone'u MODEL, Cloudflare YAYIN kopyasidir. Virtualmin
# kayitlari (www, MX, SPF, DKIM, alt domain A kayitlari) zaten dogru uretip
# guncelliyor; biz o zone'u Cloudflare'e basiyoruz. SOA ve NS gonderilmez,
# onlarin sahibi Cloudflare'dir.
#
# Tetikleme: zone dosyalarini izleyen bir arka plan servisi. Her degisiklikte
# SOA serial'i artiyor (feature-dns.pl icindeki post_records_change), dolayisiyla
# zone dosyasi degistiyse gercekten bir sey degismistir. Virtualmin'in DNS kod
# yolunda plugin kancasi YOK, o yuzden dosya izleme en saglam yontem.
# Bu modul o servisin kontrol panelidir; servisin kendisi ayri gelecek.
#
# Ayarlar DOMAIN BASINA tutulur. Global token yoktur: her domain baska bir
# Cloudflare hesabinda olabilir, token da hesap/zone bazlidir.
#   /etc/webmin/vmkit-cloudflare/domains/<domain-id>
# Dosyalar token icerdigi icin 0600.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, $module_name, $module_config_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

sub domains_dir
{
return "$module_config_directory/domains";
}

sub domain_file
{
my ($d) = @_;
return &domains_dir()."/$d->{'id'}";
}

# get_cf(&domain) -> ayar hash'i (yoksa varsayilanlar)
sub get_cf
{
my ($d) = @_;
my %cf;
&read_file(&domain_file($d), \%cf);
$cf{'proxy'} = 0 if (!defined($cf{'proxy'}));
return \%cf;
}

# save_cf(&domain, &cf)
sub save_cf
{
my ($d, $cf) = @_;
my $dir = &domains_dir();
-d $dir || &make_dir($dir, 0700, 1);
my $file = &domain_file($d);
&lock_file($file);
&write_file($file, $cf);
&unlock_file($file);
# Token bir sirdir.
chmod(0600, $file);
}

# delete_cf(&domain)
sub delete_cf
{
my ($d) = @_;
my $file = &domain_file($d);
&lock_file($file);
unlink($file);
&unlock_file($file);
}

# can_edit_domain(&domain)
# Virtualmin'in yetki kontrolu: root hepsini, domain sahibi kendisininkini.
sub can_edit_domain
{
my ($d) = @_;
return &virtual_server::can_edit_domain($d);
}

# Token'in ekranda gosterilecek maskeli hali.
sub masked_token
{
my ($t) = @_;
return '' if (!$t);
return length($t) <= 8 ? ('*' x length($t))
		       : substr($t, 0, 4).('*' x 8).substr($t, -4);
}

# ISKELET: gercek uygulamada Cloudflare API'sine sorup zone kimligini ve
# son senkron durumunu dondurur.
sub zone_status
{
my ($d) = @_;
my $cf = &get_cf($d);
return $text{'status_notoken'} if (!$cf->{'token'});
return $cf->{'last_status'} || $text{'status_unknown'};
}

# ---- Cloudflare API ------------------------------------------------------
# Token komut satirina ASLA konmaz: argv /proc uzerinden butun kullanicilara
# gorunur. Webmin'in kendi HTTP istemcisini kullanip token'i baslikta
# gonderiyoruz.
sub cf_api_get
{
my ($d, $path) = @_;
my $cf = &get_cf($d);
return (undef, $text{'err_notoken'}) if (!$cf->{'token'});
my ($out, $err);
my %headers = ( 'Authorization' => 'Bearer '.$cf->{'token'},
		'Accept'        => 'application/json' );
&http_download("api.cloudflare.com", 443, "/client/v4".$path, \$out, \$err,
	       undef, 1, undef, undef, 30, 0, 0, \%headers);
return (undef, $err) if ($err);
my $json = eval { &convert_from_json($out) };
return (undef, $text{'err_badjson'}) if ($@ || !ref($json));
if (!$json->{'success'}) {
	my @m = map { $_->{'message'} } @{$json->{'errors'} || []};
	return (undef, @m ? join("; ", @m) : $text{'err_apifail'});
	}
return ($json, undef);
}

# cf_zone_id(&domain) -> (zone-id, hata)
# Bulunan kimlik domainin kaydina yazilir, her seferinde aranmaz.
sub cf_zone_id
{
my ($d) = @_;
my $cf = &get_cf($d);
return ($cf->{'zone_id'}, undef) if ($cf->{'zone_id'});
my ($json, $err) = &cf_api_get($d, "/zones?name=".&urlize($d->{'dom'}));
return (undef, $err) if ($err);
my $z = $json->{'result'}->[0];
return (undef, &text('err_nozone', $d->{'dom'})) if (!$z);
$cf->{'zone_id'} = $z->{'id'};
&save_cf($d, $cf);
return ($z->{'id'}, undef);
}

# cf_records(&domain) -> (\@kayitlar, hata)
# Sayfalama takip edilir; 100'den fazla kayit olan zone'lar eksik gelmesin.
sub cf_records
{
my ($d) = @_;
my ($zid, $err) = &cf_zone_id($d);
return (undef, $err) if ($err);
my @rv;
my $page = 1;
while(1) {
	my ($json, $err) = &cf_api_get($d,
		"/zones/$zid/dns_records?per_page=100&page=$page");
	return (undef, $err) if ($err);
	push(@rv, @{$json->{'result'}});
	my $ri = $json->{'result_info'} || {};
	last if (!$ri->{'total_pages'} || $page >= $ri->{'total_pages'});
	$page++;
	}
return (\@rv, undef);
}

# ---- kayit eslestirme ----------------------------------------------------
# Cloudflare'e gonderdigimiz tipler. SOA ve NS bilerek yok: onlarin sahibi
# Cloudflare, biz yerel zone'daki degerleri gondermeyiz.
sub synced_types
{
return ( "A", "AAAA", "CNAME", "MX", "TXT", "SRV", "CAA" );
}

# Kendi olusturdugumuz kayitlari boyle isaretliyoruz. Etiketsiz hicbir kayda
# dokunmuyoruz - Cloudflare tunelleri, Email Routing MX'leri ve elle eklenen
# her sey bu sayede guvende.
sub cf_tag
{
return "vmkit";
}

sub cf_is_ours
{
my ($r) = @_;
return ($r->{'comment'} || '') eq &cf_tag() ? 1 : 0;
}

# local_records(&domain) -> [ { name, type, value, ttl } ]
# Yerel BIND zone'undan, gonderdigimiz tiplerle sinirli.
sub local_records
{
my ($d) = @_;
my %ok = map { $_, 1 } &synced_types();
my @rv;
foreach my $r (&virtual_server::get_domain_dns_records($d)) {
	next if (!$ok{uc($r->{'type'})});
	my $name = $r->{'name'};
	$name =~ s/\.$//;
	push(@rv, { 'name'  => lc($name),
		    'type'  => uc($r->{'type'}),
		    'value' => join(" ", @{$r->{'values'}}),
		    'ttl'   => $r->{'ttl'} });
	}
return @rv;
}

# norm_value(tip, deger) -> karsilastirilabilir bicim
# BIND ve Cloudflare ayni kaydi farkli yaziyor: BIND sonda nokta koyuyor,
# TXT degerlerini tirnak icinde tutuyor; Cloudflare ikisini de yapmiyor.
sub norm_value
{
my ($type, $v) = @_;
$v = '' if (!defined($v));
$v =~ s/^\s+//; $v =~ s/\s+$//;
if ($type eq 'TXT') {
	# BIND uzun TXT'leri parcalara bolup tirnaklar - birlestir.
	$v =~ s/"\s+"//g;
	$v =~ s/^"//; $v =~ s/"$//;
	return $v;
	}
$v =~ s/\.$//;
return lc($v);
}

# cf_value(&cf-kaydi) -> karsilastirilabilir deger
# MX'te oncelik ayri alanda geliyor, BIND'de degerin parcasi.
sub cf_value
{
my ($r) = @_;
my $t = uc($r->{'type'});
return &norm_value($t, $r->{'priority'}." ".$r->{'content'}) if ($t eq 'MX');
return &norm_value($t, $r->{'content'});
}

1;
