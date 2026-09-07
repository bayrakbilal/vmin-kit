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
#
# TXT ve tirnaklar: Cloudflare'e GONDERIRKEN de tirnaksiz gonderiyoruz.
# Dokumantasyon "tirnaksiz kaydedilirse Cloudflare kendisi ekler" diyor;
# tirnakli gonderip Cloudflare bunu fark etmezse ""deger"" gibi cift
# tirnaklanmis bozuk bir kayit olusurdu. Tirnaksiz gondermek o riski
# tamamen ortadan kaldiriyor.
#
# BIND 255 karakterden uzun TXT degerlerini parcalara bolup her parcayi
# tirnaklar ("aaa" "bbb"). Asagidaki ilk ikame parcalari birlestiriyor;
# olmasa DKIM anahtarlari yarim gonderilirdi.
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

# short_value(deger) -> uzunsa kisaltilmis, tamami title'da
# DKIM anahtarlari gibi cok uzun TXT degerleri tabloyu bozuyor.
sub short_value
{
my ($v, $max) = @_;
$max ||= 60;
return &html_escape($v) if (length($v) <= $max);
return "<span title=\"".&quote_escape($v)."\">".
       &html_escape(substr($v, 0, $max))."...</span>";
}

# cf_api_req(&domain, metot, yol, [govde-hashref]) -> (json, hata)
# GET disindaki metotlar icin de calisir. Token yine yalnizca baslikta:
# komut satirina ya da gecici dosyaya hic yazilmiyor.
sub cf_api_req
{
my ($d, $method, $path, $data) = @_;
my $cf = &get_cf($d);
return (undef, $text{'err_notoken'}) if (!$cf->{'token'});

my $host = "api.cloudflare.com";
my $body = defined($data) ? &convert_to_json($data) : undef;
my @headers = ( [ "Host", $host ],
		[ "User-Agent", "vmkit" ],
		[ "Authorization", "Bearer ".$cf->{'token'} ],
		[ "Accept", "application/json" ] );
if (defined($body)) {
	push(@headers, [ "Content-Type", "application/json" ],
		       [ "Content-Length", length($body) ]);
	}

my $h = &make_http_connection($host, 443, 1, $method, "/client/v4".$path,
			      \@headers);
return (undef, ref($h) ? $text{'err_apifail'} : ($h || $text{'err_apifail'}))
	if (!ref($h));
&write_http_connection($h, $body) if (defined($body));

my ($out, $err);
&complete_http_download($h, \$out, \$err, undef, 0, $host, 443, \@headers,
			1, 1, 30);
# Cloudflare hata durumunda da JSON gonderiyor; once govdeyi cozmeyi dene ki
# "400 Bad Request" yerine gercek sebebi gosterebilelim.
my $json = eval { &convert_from_json($out) };
if (!$@ && ref($json)) {
	return ($json, undef) if ($json->{'success'});
	my @m = map { $_->{'message'} } @{$json->{'errors'} || []};
	return (undef, @m ? join("; ", @m) : $text{'err_apifail'});
	}
return (undef, $err || $text{'err_badjson'});
}

# ---- islemler -------------------------------------------------------------

# cf_to_bind(&cf-kaydi) -> (\@degerler, hata)
# Cloudflare kaydini BIND'in bekledigi deger dizisine cevirir. Tipe gore
# farkli: MX'te oncelik ayri alanda, SRV ve CAA parcalari 'data' icinde.
sub cf_to_bind
{
my ($r) = @_;
my $t = uc($r->{'type'});
my $dt = $r->{'data'} || { };
my $dot = sub { my ($v) = @_; $v .= "." if ($v !~ /\.$/); return $v; };
return ([ $r->{'content'} ], undef)                    if ($t eq 'A');
return ([ $r->{'content'} ], undef)                    if ($t eq 'AAAA');
return ([ &$dot($r->{'content'}) ], undef)             if ($t eq 'CNAME');
return ([ $r->{'content'} ], undef)                    if ($t eq 'TXT');
return ([ $r->{'priority'}, &$dot($r->{'content'}) ], undef) if ($t eq 'MX');
if ($t eq 'SRV' && defined($dt->{'target'})) {
	return ([ $dt->{'priority'}, $dt->{'weight'}, $dt->{'port'},
		  &$dot($dt->{'target'}) ], undef);
	}
if ($t eq 'CAA' && defined($dt->{'value'})) {
	return ([ $dt->{'flags'}, $dt->{'tag'}, '"'.$dt->{'value'}.'"' ], undef);
	}
return (undef, $text{'err_noconv'});
}

# cf_find_record(&domain, kayit-id) -> (&kayit, hata)
sub cf_find_record
{
my ($d, $id) = @_;
my ($recs, $err) = &cf_records($d);
return (undef, $err) if ($err);
my ($r) = grep { $_->{'id'} eq $id } @$recs;
return (undef, $text{'err_norec'}) if (!$r);
return ($r, undef);
}

# cf_tag_record(&domain, &kayit) -> hata
# Kaydi bizim etiketimize alir; bundan sonra senkron onu yonetir.
sub cf_tag_record
{
my ($d, $r) = @_;
my ($zid, $err) = &cf_zone_id($d);
return $err if ($err);
(undef, $err) = &cf_api_req($d, "PATCH",
	"/zones/$zid/dns_records/$r->{'id'}", { 'comment' => &cf_tag() });
return $err;
}

# cf_delete_record(&domain, &kayit) -> hata
sub cf_delete_record
{
my ($d, $r) = @_;
my ($zid, $err) = &cf_zone_id($d);
return $err if ($err);
(undef, $err) = &cf_api_req($d, "DELETE",
	"/zones/$zid/dns_records/$r->{'id'}");
return $err;
}

# import_record(&domain, &cf-kaydi) -> hata
# Kaydi yerel BIND zone'una yazar. CLI yerine Virtualmin'in kendi
# fonksiyonlarini kullaniyoruz: 'modify-dns --add-record' degeri bosluklardan
# bolduyor icin icinde bosluk olan TXT kayitlari bozulurdu.
sub import_record
{
my ($d, $r) = @_;
my ($vals, $err) = &cf_to_bind($r);
return $err if ($err);
my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
return $text{'err_nozonefile'} if (!$file);
my $name = $r->{'name'};
$name .= "." if ($name !~ /\.$/);
# Cloudflare'de ttl=1 "otomatik" demek, BIND'e gecirilecek bir sayi degil.
my $ttl = ($r->{'ttl'} && $r->{'ttl'} != 1) ? $r->{'ttl'} : undef;
&virtual_server::create_dns_record($recs, $file,
	{ 'name'   => $name,
	  'type'   => uc($r->{'type'}),
	  'class'  => 'IN',
	  'ttl'    => $ttl,
	  'values' => $vals });
my $perr = &virtual_server::post_records_change($d, $recs, $file);
return $perr if ($perr);
return undef;
}

1;
