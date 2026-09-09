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
# Servisi (systemd .path + .timer + .service) bu modulun kendisi kuruyor ve
# denetliyor - bkz. dosyanin sonundaki "otomatik senkron servisi" bolumu.
#
# Ayarlar DOMAIN BASINA tutulur. Global token yoktur: her domain baska bir
# Cloudflare hesabinda olabilir, token da hesap/zone bazlidir.
#   /etc/webmin/vmkit-cloudflare/domains/<domain-id>
# Dosyalar token icerdigi icin 0600.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, $module_name, $module_config_directory,
     $module_root_directory);

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

# ---------------------------------------------------------------------------
# TOKEN'IN DISKTE SAKLANMASI
#
# BU BIR GUVENLIK KATMANI DEGIL, OKUNAKSIZLASTIRMADIR. Anahtar asagida,
# eklentinin kaynak kodunda duruyor; kodu okuyan herkes cozer. Bilerek boyle:
# token zaten o domainin sahibine ait, ondan gizlemeye calismiyoruz.
#
# Amac, token'in DUZ METIN olarak durdugu yerleri azaltmak:
#   - Virtualmin'in domain yedegi (yedek dosyasi elden ele gezebiliyor)
#   - /etc yedekleri
#   - etckeeper: /etc bir git deposu, yani her degisiklik GECMISE de yaziliyor
#   - hata ayiklarken kopyalanan dosya iceriKleri
# Eline yedek gecen biri anlamsiz bir hex dizisi gorur; bizim icin yeterli.
#
# Bicim:  v1:<hex>   ->  hex = 8 bayt tuz + tuzla uretilen anahtar akisiyla
#                        XOR'lanmis token
# Onek YOKSA deger duz metindir (eski kayitlar) ve oldugu gibi donuyor; bir
# sonraki save_cf'te kendiliginden sifreli bicime geciyor.
#
# Base64 yerine hex: MIME::Base64'u Webmin bile 'eval "use ..."' ile istege
# bagli yukluyor, oysa unpack("H*") hicbir sey gerektirmiyor. Token kisa,
# boyutun iki katina cikmasi onemsiz.
# ---------------------------------------------------------------------------

# Sabit anahtar. Degistirilirse ESKI KAYITLAR COZULEMEZ - degistirme.
sub obf_secret
{
return 'vmkit-cloudflare/v1/8c1f4a6b2e9d70335af8c264d1b0e97a';
}

# Digest::SHA cekirdek Perl'in parcasi ama Webmin'in kendisi kullanmiyor, yani
# "kesin vardir" diyemiyoruz. Yoksa Digest::MD5'e, o da yoksa hicbir seye
# dusmuyoruz: token eskisi gibi duz metin yazilir ve modul calismaya devam
# eder. Sessizce bozulmaktansa sessizce eski davranisa donmek yeglenir.
my $obf_digest;
sub obf_digest_kind
{
return $obf_digest if (defined($obf_digest));
if (eval { require Digest::SHA; 1 })    { $obf_digest = 'sha'; }
elsif (eval { require Digest::MD5; 1 }) { $obf_digest = 'md5'; }
else                                    { $obf_digest = ''; }
return $obf_digest;
}

sub obf_hash
{
my ($data) = @_;
my $k = &obf_digest_kind();
return $k eq 'sha' ? Digest::SHA::sha256($data) :
       $k eq 'md5' ? Digest::MD5::md5($data) : undef;
}

# Tuzdan istenen uzunlukta anahtar akisi: hash(anahtar + tuz + sayac) bloklari.
sub obf_stream
{
my ($salt, $len) = @_;
my ($out, $i) = ("", 0);
while (length($out) < $len) {
	$out .= &obf_hash(&obf_secret().$salt.pack("N", $i));
	$i++;
	}
return substr($out, 0, $len);
}

sub obf_encrypt
{
my ($plain) = @_;
return $plain if (!defined($plain) || $plain eq '');
return $plain if (!&obf_digest_kind());
# Tuz her kayitta yeni: ayni token iki domainde ayni hex'i uretmesin.
my $salt = '';
if (open(my $RND, "<", "/dev/urandom")) {
	binmode($RND);
	read($RND, $salt, 8);
	close($RND);
	}
if (!defined($salt) || length($salt) != 8) {
	$salt = '';
	$salt .= chr(int(rand(256))) for (1..8);
	}
my $ct = $plain ^ &obf_stream($salt, length($plain));
return "v1:".unpack("H*", $salt.$ct);
}

sub obf_decrypt
{
my ($v) = @_;
return $v if (!defined($v) || $v !~ /^v1:([0-9a-f]+)$/);
# Onekli ama cozecek modul yok: bos don. Yanlis bir dizeyi token diye
# kullanip Cloudflare'e gondermekten iyidir.
return "" if (!&obf_digest_kind());
my $raw = pack("H*", $1);
return "" if (length($raw) <= 8);
my $salt = substr($raw, 0, 8);
my $ct   = substr($raw, 8);
return $ct ^ &obf_stream($salt, length($ct));
}

# get_cf(&domain) -> ayar hash'i (yoksa varsayilanlar)
sub get_cf
{
my ($d) = @_;
my %cf;
&read_file(&domain_file($d), \%cf);
# Disk sifreli, bellek duz: cagiran taraf token'i her zaman kullanilabilir
# halde goruyor. Eski (oneksiz) kayitlar oldugu gibi geri geliyor.
$cf{'token'} = &obf_decrypt($cf{'token'}) if (defined($cf{'token'}));
$cf{'proxy'} = 0 if (!defined($cf{'proxy'}));
# Otomatik senkron varsayilan ACIK. Anahtar yoksa (eski kayitlar) da acik
# sayiliyor - davranis degismesin diye.
$cf{'enabled'} = 1 if (!defined($cf{'enabled'}));
return \%cf;
}

# save_cf(&domain, &cf)
sub save_cf
{
my ($d, $cf) = @_;
my $dir = &domains_dir();
-d $dir || &make_dir($dir, 0700, 1);
my $file = &domain_file($d);
# KOPYA uzerinde calisiyoruz: cagiranin elindeki hash'i sifreli degerle
# kirletirsek, ayni istekte token'i tekrar kullanan kod bozulur (ornegin
# cf_zone_id once kaydedip sonra API'ye gidiyor).
my %out = %$cf;
$out{'token'} = &obf_encrypt($out{'token'}) if (defined($out{'token'}));
&lock_file($file);
&write_file($file, \%out);
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

# Domainin ekranda gosterilecek durumu. API'ye SORMAZ: son senkron turunun
# biraktigi sonucu okur, boylece sayfa acmak Cloudflare'e istek uretmez.
sub zone_status
{
my ($d) = @_;
my $cf = &get_cf($d);
return $text{'status_notoken'} if (!$cf->{'token'});

# Diskte KOD duruyor ('ok' / 'partial'), cevrilmis metin degil: dil
# degistiginde eski kayitlar eski dilde gorunuyordu. Ceviri burada, gosterim
# aninda yapiliyor. Taninmayan bir deger (eski surumden kalan cumleler)
# "bilinmiyor" sayiliyor ve ilk senkronda kendiliginden duzeliyor.
my $st = $cf->{'last_status'} || '';
return $text{'status_ok'}      if ($st eq 'ok');
return $text{'status_partial'} if ($st eq 'partial');
return $text{'status_unknown'};
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
# Cloudflare'e GONDERILMEYEN adlar. Zone'da kaliyorlar, yalnizca yayinlanan
# kopyaya girmiyorlar.
#
# ns1/ns2: yerel zone her zaman "NS yonetimi bizde" modeline gore uretiliyor,
# bu yuzden kendi nameserver ciftimizin A kayitlarini tasiyor. Delegasyon
# Cloudflare'deyse o kayitlarin yayinlanan kopyada isi yok.
sub skip_name
{
my ($label) = @_;
return $label =~ /^ns\d*$/ ? 1 : 0;
}

# Kaydin domaine gore etiketi: ns1.ornek.com -> ns1, ornek.com -> @
sub record_label
{
my ($d, $name) = @_;
my $dom = lc($d->{'dom'});
my $lc = lc($name);
$lc =~ s/\.$//;
return '@' if ($lc eq $dom);
return $1 if ($lc =~ /^(.*)\.\Q$dom\E$/);
return $lc;
}

# Varsayilan proxy tercihi ACIK olsa bile proxy'lenmemesi gereken adlar.
# Cloudflare proxy'si yalnizca HTTP/HTTPS tasiyor; posta ve otomatik
# yapilandirma adlari proxy'lenirse SMTP/IMAP baglantisi ve istemci kesfi
# kirilir. Kullanici bir kaydi elle proxy'ye alirsa ona dokunmuyoruz - bu
# liste yalnizca BIZ yeni kayit olustururken uygulaniyor.
sub never_proxy
{
my ($label) = @_;
return $label =~ /^(mail|smtp|imap|pop|pop3|mta-sts|autoconfig|autodiscover)$/ ? 1 : 0;
}

sub local_records
{
my ($d) = @_;
my %ok = map { $_, 1 } &synced_types();
my @rv;
foreach my $r (&virtual_server::get_domain_dns_records($d)) {
	# Webmin'in bind8 cozumleyicisi bazi TXT kayitlarini ANLAMLARINA gore
	# etiketliyor: SPF ve DMARC diye ayri tip donuyor. Zone dosyasinda ikisi
	# de TXT ve Cloudflare'de de TXT olmalari gerekiyor - Cloudflare'de SPF
	# ya da DMARC diye bir kayit tipi yok. Cevirmezsek bu iki kayit hic
	# senkronlanmiyor (tip listesinde olmadiklari icin sessizce eleniyorlar).
	my $type = uc($r->{'type'});
	$type = "TXT" if ($type eq "SPF" || $type eq "DMARC");
	next if (!$ok{$type});
	my $name = $r->{'name'};
	$name =~ s/\.$//;
	next if (&skip_name(&record_label($d, $name)));
	push(@rv, { 'name'  => lc($name),
		    'type'  => $type,
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
if ($type eq 'CAA') {
	# Webmin'in bind8 ayristirmasi CAA degerinin tirnaklarini soyuyor,
	# Cloudflare ise tirnakli donduruyor. Esitlemezsek kayit her senkronda
	# "farkli" gorunup yeniden yazilirdi.
	$v =~ s/"//g;
	$v =~ s/\s+/ /g;
	return lc($v);
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
my $dt = $r->{'data'};
return &norm_value($t, $r->{'priority'}." ".$r->{'content'}) if ($t eq 'MX');
# SRV ve CAA'da parcalar 'data' icinde; 'content' tek basina eksik ya da
# farkli bicimde geliyor. Varsa data'dan kuruyoruz.
if ($t eq 'SRV' && ref($dt) && defined($dt->{'target'})) {
	return &norm_value($t, join(" ", $dt->{'priority'}, $dt->{'weight'},
					 $dt->{'port'}, $dt->{'target'}));
	}
if ($t eq 'CAA' && ref($dt) && defined($dt->{'value'})) {
	return &norm_value($t, join(" ", $dt->{'flags'}, $dt->{'tag'},
					 $dt->{'value'}));
	}
return &norm_value($t, $r->{'content'});
}

# short_value(deger) -> uzunsa kisaltilmis, tamami title'da
# DKIM anahtarlari gibi cok uzun TXT degerleri tabloyu bozuyor.
sub short_value
{
my ($v, $max) = @_;
# 40 karakter: tablo yedi sutunlu, uzun degerler satirlari sisiriyordu.
# Tamami zaten title'da - uzerine gelince gorunuyor.
$max ||= 40;
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

# cf_set_proxy(&domain, &cfrecord, 1|0)
# Tek bir kaydin proxy durumunu degistirir. Yalnizca A, AAAA ve CNAME'de
# anlamli; digerlerinde Cloudflare alani zaten kabul etmiyor.
sub cf_set_proxy
{
my ($d, $r, $on) = @_;
my ($zid, $err) = &cf_zone_id($d);
return $err if ($err);
return $text{'err_noproxytype'}
	if (uc($r->{'type'}) !~ /^(A|AAAA|CNAME)$/);
my ($out, $e) = &cf_api_req($d, "PATCH",
			    "/zones/$zid/dns_records/$r->{'id'}",
			    { 'proxied' => $on ? \1 : \0 });
return $e;
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

# ---- senkron plani --------------------------------------------------------
# Karsilastirmanin TEK kaynagi. Hem onizleme sayfasi hem senkron motoru bunu
# kullanir; ayri ayri siniflandirsalardi tablo bir sey gosterip motor baska
# sey yapabilirdi.
#
# Her girdi: name, type, lvals, crecs, cvals, op, why
#   op: create | update | delete | adopt | none | skip
sub sync_plan
{
my ($d) = @_;
my ($cfrecs, $err) = &cf_records($d);
return (undef, $err) if ($err);

my (%lg, %cg, %cfcname);
foreach my $r (&local_records($d)) {
	push(@{$lg{lc($r->{'name'})."|".$r->{'type'}}}, $r);
	}
foreach my $r (@$cfrecs) {
	push(@{$cg{lc($r->{'name'})."|".uc($r->{'type'})}}, $r);
	# Cloudflare bir adda CNAME tutarken ayni ada baska tip kabul etmez.
	$cfcname{lc($r->{'name'})} = $r if (uc($r->{'type'}) eq 'CNAME');
	}

my %allk = map { $_ => 1 } (keys %lg, keys %cg);
my @plan;
foreach my $k (sort keys %allk) {
	my ($n, $t) = split(/\|/, $k, 2);
	my @lr = @{$lg{$k} || [ ]};
	my @cr = @{$cg{$k} || [ ]};
	my @lv = map { &norm_value($t, $_->{'value'}) } @lr;
	my @cv = map { &cf_value($_) } @cr;
	my $ours    = @cr && !(grep { !&cf_is_ours($_) } @cr);
	my $proxied = (grep { $_->{'proxied'} } @cr) ? 1 : 0;
	my $same    = join("\n", sort @lv) eq join("\n", sort @cv);

	my $e = { 'name' => $n, 'type' => $t, 'lvals' => \@lv,
		  'crecs' => \@cr, 'cvals' => \@cv, 'lttl' => $lr[0]->{'ttl'},
		  'ours' => $ours, 'proxied' => $proxied };
	# Proxy bir 'atla' sebebi DEGIL: kaydi kimin yonettigine sahiplik karar
	# veriyor. Tuneli koruyan sey de zaten sahiplik ('notours'), proxy degil.
	# Proxy yalnizca gosterilen ve guncellemede korunan bir nitelik.
	if (@lv && !@cr) {
		if ($t ne 'CNAME' && $cfcname{$n}) {
			$e->{'op'} = 'skip'; $e->{'why'} = 'cnameclash';
			$e->{'blocker'} = $cfcname{$n};
			}
		else { $e->{'op'} = 'create'; }
		}
	elsif (!@lv && @cr) {
		if ($ours) { $e->{'op'} = 'delete'; }
		else { $e->{'op'} = 'skip'; $e->{'why'} = 'notours'; }
		}
	elsif ($same) {
		$e->{'op'} = $ours ? 'none' : 'adopt';
		}
	else {
		if ($ours) { $e->{'op'} = 'update'; }
		else { $e->{'op'} = 'skip'; $e->{'why'} = 'conflict'; }
		}
	push(@plan, $e);
	}
return (\@plan, undef);
}

# cf_body(ad, tip, deger, ttl, proxy) -> Cloudflare kayit govdesi
# MX'te oncelik, SRV ve CAA'da parcalar ayri alanlara gidiyor.
sub cf_body
{
my ($name, $type, $value, $ttl, $proxy) = @_;
# Cloudflare'de ttl=1 "otomatik" demek; yerelde TTL yoksa onu kullaniyoruz.
my %r = ( 'type' => $type, 'name' => $name,
	  'ttl' => ($ttl && $ttl >= 60 ? int($ttl) : 1),
	  'comment' => &cf_tag() );
if ($type eq 'MX') {
	return undef if ($value !~ /^(\d+)\s+(\S+)$/);
	$r{'priority'} = int($1);
	$r{'content'}  = $2;
	}
elsif ($type eq 'SRV') {
	my @p = split(/\s+/, $value);
	return undef if (@p != 4);
	$r{'data'} = { 'priority' => int($p[0]), 'weight' => int($p[1]),
		       'port' => int($p[2]), 'target' => $p[3] };
	}
elsif ($type eq 'CAA') {
	my @p = split(/\s+/, $value, 3);
	return undef if (@p != 3);
	my $v = $p[2];
	$v =~ s/^"//; $v =~ s/"$//;
	$r{'data'} = { 'flags' => int($p[0]), 'tag' => $p[1], 'value' => $v };
	}
else {
	$r{'content'} = $value;
	}
# Proxy yalnizca A, AAAA ve CNAME icin gecerli; digerlerinde alan gonderilmez.
if ($type eq 'A' || $type eq 'AAAA' || $type eq 'CNAME') {
	$r{'proxied'} = $proxy ? \1 : \0;
	}
return \%r;
}

# run_sync(&domain, &geri-cagirma) -> (basarili?, hata)
# Plandaki islemleri uygular. Her satiri geri cagirmaya verir ki sayfa ne
# yapildigini tek tek gosterebilsin.
sub run_sync
{
my ($d, $cb) = @_;
my ($plan, $err) = &sync_plan($d);
return (0, $err) if ($err);
my ($zid, $zerr) = &cf_zone_id($d);
return (0, $zerr) if ($zerr);
my $cf = &get_cf($d);
my $base = "/zones/$zid/dns_records";
my $ok = 1;
my $n = 0;

foreach my $e (@$plan) {
	my $op = $e->{'op'};
	next if ($op eq 'none' || $op eq 'skip');
	my $what = $e->{'name'}." ".$e->{'type'};

	if ($op eq 'adopt') {
		# Deger zaten ayni; yalnizca etiketi koyuyoruz.
		foreach my $r (@{$e->{'crecs'}}) {
			next if (&cf_is_ours($r));
			my (undef, $aerr) = &cf_api_req($d, "PATCH",
				"$base/$r->{'id'}", { 'comment' => &cf_tag() });
			$n++;
			&$cb($aerr ? &text('sync_efail', $what, $aerr)
				   : &text('sync_adopted', $what));
			$ok = 0 if ($aerr);
			}
		next;
		}

	if ($op eq 'delete') {
		foreach my $r (@{$e->{'crecs'}}) {
			my (undef, $derr) = &cf_api_req($d, "DELETE",
							"$base/$r->{'id'}");
			$n++;
			&$cb($derr ? &text('sync_efail', $what, $derr)
				   : &text('sync_deleted', $what));
			$ok = 0 if ($derr);
			}
		next;
		}

	# create ve update: yerel degerlerle Cloudflare kayitlarini birebir
	# eslestiriyoruz. Fazla kayit silinir, eksik olan olusturulur. Hepsini
	# silip yeniden olusturmak daha basit olurdu ama kaydin kisa sureligine
	# hic var olmadigi bir aralik dogardi.
	my @lv = @{$e->{'lvals'}};
	my @cr = @{$e->{'crecs'}};
	my $max = @lv > @cr ? @lv : @cr;
	for(my $i = 0; $i < $max; $i++) {
		if ($i < @lv && $i < @cr) {
			# Mevcut kaydin proxy durumuna DOKUNMUYORUZ: elle
			# ayarlanmis bir tercihi bozmayalim.
			my $body = &cf_body($e->{'name'}, $e->{'type'}, $lv[$i],
					    $e->{'lttl'}, $cr[$i]->{'proxied'});
			if (!$body) { &$cb(&text('sync_ebody', $what)); $ok = 0; next; }
			my (undef, $uerr) = &cf_api_req($d, "PUT",
					"$base/$cr[$i]->{'id'}", $body);
			$n++;
			&$cb($uerr ? &text('sync_efail', $what, $uerr)
				   : &text('sync_updated', $what, $lv[$i]));
			$ok = 0 if ($uerr);
			}
		elsif ($i < @lv) {
			# Yeni kayit: varsayilan proxy tercihi burada uygulanir
			# (posta adlari haric - never_proxy).
			my $px = $cf->{'proxy'} &&
				 !&never_proxy(&record_label($d, $e->{'name'}))
					? 1 : 0;
			my $body = &cf_body($e->{'name'}, $e->{'type'}, $lv[$i],
					    $e->{'lttl'}, $px);
			if (!$body) { &$cb(&text('sync_ebody', $what)); $ok = 0; next; }
			my (undef, $cerr) = &cf_api_req($d, "POST", $base, $body);
			$n++;
			&$cb($cerr ? &text('sync_efail', $what, $cerr)
				   : &text('sync_created', $what, $lv[$i]));
			$ok = 0 if ($cerr);
			}
		else {
			my (undef, $derr) = &cf_api_req($d, "DELETE",
					"$base/$cr[$i]->{'id'}");
			$n++;
			&$cb($derr ? &text('sync_efail', $what, $derr)
				   : &text('sync_deleted', $what));
			$ok = 0 if ($derr);
			}
		}
	}

&$cb($text{'sync_nothing'}) if (!$n);
# Kod saklaniyor, metin degil - ceviri zone_status'ta yapiliyor.
$cf->{'last_status'} = $ok ? "ok" : "partial";
$cf->{'last_time'} = time();
&save_cf($d, $cf);
return ($ok, undef);
}

# zone_mtime(&domain) -> zone dosyasinin son degisiklik zamani (yoksa 0)
# Senkronu tetikleyen sinyal bu. Her DNS degisikliginde Virtualmin SOA
# serial'ini artirip dosyayi yeniden yaziyor, dolayisiyla mtime degistiyse
# gercekten bir sey degismistir.
sub zone_mtime
{
my ($d) = @_;
my $file = eval { &virtual_server::get_domain_dns_file($d) };
return 0 if ($@ || !$file);
# BIND chroot altinda calisiyorsa gercek yol farkli olabilir.
$file = &virtual_server::bind_chroot_file($file)
	if (defined(&virtual_server::bind_chroot_file));
my @st = stat($file);
return @st ? $st[9] : 0;
}

# needs_sync(&domain) -> zone son senkrondan sonra degismis mi
sub needs_sync
{
my ($d) = @_;
my $cf = &get_cf($d);
return 0 if (!$cf->{'token'});
my $m = &zone_mtime($d);
return 0 if (!$m);
return ($cf->{'synced_mtime'} || 0) < $m ? 1 : 0;
}

# mark_synced(&domain)
sub mark_synced
{
my ($d) = @_;
my $cf = &get_cf($d);
$cf->{'synced_mtime'} = &zone_mtime($d);
&save_cf($d, $cf);
}

# sync_domains() -> OTOMATIK senkrona giren domainler: ozelligi acik, token'i
# olan ve otomatik senkronu kapatilmamis olanlar.
#
# 'enabled' yalnizca otomatik yolu (path/timer -> sync-all.pl) durdurur;
# paneldeki "Simdi senkronla" dugmesi calismaya devam eder, cunku o acik bir
# kullanici eylemidir. Token silinmez: kapatip acmak tek tik.
sub sync_domains
{
my @rv;
foreach my $d (&virtual_server::list_domains()) {
	next if (!$d->{'vmkit-cloudflare'});
	my $cf = &get_cf($d);
	next if (!$cf->{'token'} || !$cf->{'enabled'});
	push(@rv, $d);
	}
return @rv;
}


# ---- otomatik senkron servisi -------------------------------------------
# Birimleri BU MODUL uretir ve yonetir. Eskiden install-plugins.sh
# olusturuyordu; modul .wbm.gz olarak standart yoldan kurulunca o script hic
# calismayacagi icin servis de hic kurulmuyordu. Artik tek kaynak burasi ve
# uc yerden cagriliyor:
#   postinstall.pl   modul kurulunca (Webmin'in standart kancasi)
#   feature_setup    ozellik bir domainde acilinca
#   index.cgi        sayfa her acildiginda - durmussa geri kaldirir
#
# Birimler:
#   .path     zone dosyasi degistigi anda senkronu tetikler (asil tetikleyici)
#   .timer    15 dakikada bir - kacan olay ya da basarisiz tur icin guvenlik agi
#   .service  ikisinin de calistirdigi tek seferlik is

sub sync_service
{
return "vmkit-cloudflare-sync";
}

sub sync_unit_dir
{
return "/etc/systemd/system";
}

# systemd calisiyor mu? Calismiyorsa hicbir sey kurmaz, panelde de bunu
# soyleriz - sessizce basarisiz olmaktansa.
sub have_systemd
{
return &has_command("systemctl") && -d "/run/systemd/system" ? 1 : 0;
}

# systemctl(args...) -> (basarili mi, cikti)
sub systemctl
{
my @args = @_;
my $cmd = "systemctl ".join(" ", map { quotemeta($_) } @args)." 2>&1 </dev/null";
my $out = &backquote_command($cmd);
return ($? ? 0 : 1, $out);
}

# Izlenecek zone dizini. Tahmin etmiyoruz: olmayan bir dizini izleyen .path
# birimi basarisiz oluyor. Once BIND'in kendi yapilandirmasina bakiyoruz,
# bulunamazsa yaygin iki konuma.
sub zone_watch_dirs
{
my @dirs;
eval {
	local $main::error_must_die = 1;
	&foreign_require("bind8");
	my %bconfig = &foreign_config("bind8");
	my $base = $bconfig{'master_dir'} ||
		   &bind8::base_directory(&bind8::get_config());
	push(@dirs, &bind8::make_chroot($base)) if ($base);
	};
push(@dirs, "/var/lib/bind", "/var/cache/bind");
my %seen;
return grep { -d $_ && !$seen{$_}++ } @dirs;
}

# sync_unit_files() -> ( dosya adi => olmasi gereken icerik )
# Kurulum da denetim de ayni metni uretir; "degismis mi" karsilastirmasi bu
# yuzden guvenilir. Zone dizini bulunamazsa .path uretilmez.
sub sync_unit_files
{
my $svc = &sync_service();
my $exec = "$module_root_directory/sync-all.pl";
my %f;

$f{$svc.".service"} =
"[Unit]\n".
"Description=VminKit Cloudflare DNS sync\n".
"After=network-online.target bind9.service\n".
"Wants=network-online.target\n".
"\n".
"[Service]\n".
"Type=oneshot\n".
"# Zone degismediyse script hicbir API cagrisi yapmadan cikar.\n".
"ExecStart=$exec\n".
"# Bekleme YOK: DNS-01 dogrulamasinda challenge kaydinin Cloudflare tarafina\n".
"# saniyeler icinde ulasmasi gerekiyor.\n".
"Nice=10\n";

$f{$svc.".timer"} =
"[Unit]\n".
"Description=VminKit Cloudflare DNS sync (safety net)\n".
"\n".
"[Timer]\n".
"# Asil tetikleyici .path birimi; zone dosyasi degistigi anda calisiyor.\n".
"# Bu zamanlayici yalnizca kacan bir olayi ya da basarisiz bir turu yakalar.\n".
"OnBootSec=3min\n".
"OnUnitActiveSec=15min\n".
"AccuracySec=1min\n".
"Unit=$svc.service\n".
"\n".
"[Install]\n".
"WantedBy=timers.target\n";

my @wd = &zone_watch_dirs();
if (@wd) {
	$f{$svc.".path"} =
	"[Unit]\n".
	"Description=VminKit Cloudflare DNS sync on zone change\n".
	"\n".
	"[Path]\n".
	join("", map { "PathChanged=$_\n" } @wd).
	"Unit=$svc.service\n".
	"\n".
	"[Install]\n".
	"WantedBy=multi-user.target\n";
	}
return %f;
}

# sync_units_status() -> durum hash'i
#   systemd  systemd var mi
#   nowatch  izlenecek zone dizini yok - anlik tetikleme kurulamaz
#   path,timer,service  her biri { exists, current, enabled, active }
#   lastrun, lastresult  servisin son turu
#   ok       otomatik senkron gercekten ayakta mi
sub sync_units_status
{
my $svc = &sync_service();
my %st = ( 'systemd' => &have_systemd() );
return \%st if (!$st{'systemd'});

my %want = &sync_unit_files();
$st{'nowatch'} = $want{$svc.".path"} ? 0 : 1;

foreach my $k ("path", "timer", "service") {
	my $u = "$svc.$k";
	my $file = &sync_unit_dir()."/$u";
	my $cur = -r $file ? &read_file_contents($file) : undef;
	my %u = ( 'name'    => $u,
		  'exists'  => defined($cur) ? 1 : 0,
		  'current' => (defined($cur) && defined($want{$u}) &&
				$cur eq $want{$u}) ? 1 : 0 );
	if ($u{'exists'}) {
		my ($e) = &systemctl("is-enabled", $u);
		my ($a) = &systemctl("is-active", $u);
		$u{'enabled'} = $e;
		$u{'active'} = $a;
		}
	$st{$k} = \%u;
	}

# .service tek seferlik (Type=oneshot): bosta iken 'inactive' gorunmesi
# normaldir, saglik gostergesi son turun sonucudur.
my (undef, $out) = &systemctl("show", "$svc.service",
			      "-p", "Result", "-p", "ExecMainExitTimestamp");
foreach my $l (split(/\r?\n/, $out)) {
	$st{'lastresult'} = $1 if ($l =~ /^Result=(.*)/);
	$st{'lastrun'} = $1 if ($l =~ /^ExecMainExitTimestamp=(.+)/);
	}

# Anlik tetikleme asil is: zamanlayici tek basina kalirsa DNS-01 wildcard
# dogrulamasi icin cok yavas olur. Bu yuzden 'ok' ikisini birden istiyor;
# yalnizca zamanlayici ayaktaysa panel bunu eksik calisma olarak gosterir.
$st{'ok'} = ($st{'timer'}->{'active'} && !$st{'nowatch'} &&
	     $st{'path'}->{'active'}) ? 1 : 0;
return \%st;
}


# sync_units_healthy(&durum) -> dosyalar guncel ve birimler ayakta mi
# Sayfa acilisinda once buna bakiyoruz; her sey yerindeyse ensure cagrilmiyor,
# boylece saglikli durumda gereksiz systemctl cagrisi yapilmiyor.
sub sync_units_healthy
{
my ($st) = @_;
return 0 if (!$st->{'systemd'});
return 0 if (!$st->{'timer'}->{'current'} || !$st->{'timer'}->{'active'});
return 0 if (!$st->{'service'}->{'current'});
# Izlenecek zone dizini yoksa kurulacak .path birimi de yok - bu durumda
# tekrar tekrar kurmaya calismanin anlami olmaz, panel zaten uyariyor.
return 1 if ($st->{'nowatch'});
return 0 if (!$st->{'path'}->{'current'} || !$st->{'path'}->{'active'});
return 1;
}
# ensure_sync_units([force]) -> ( yapilanlarin listesi, hata )
# Eksik ya da eskimis dosyayi yazar, etkin degilse etkinlestirir, durmussa
# baslatir. Idempotent: her sey yerindeyse hicbir sey yapmaz ve bos liste
# doner - bu yuzden sayfa her acildiginda cagrilabilir.
sub ensure_sync_units
{
my ($force) = @_;
return ([ ], $text{'svc_enosystemd'}) if (!&have_systemd());
my $svc = &sync_service();
my %want = &sync_unit_files();
my @done;
my $reload = 0;

# Zone dizini kaybolduysa eski .path birimini birakma: olmayan bir dizini
# izleyen birim her aciliste basarisiz olur.
if (!$want{$svc.".path"} && -e &sync_unit_dir()."/$svc.path") {
	&systemctl("disable", "--now", "$svc.path");
	unlink(&sync_unit_dir()."/$svc.path");
	push(@done, "removed $svc.path");
	$reload = 1;
	}

my @changed;
foreach my $u (sort keys %want) {
	my $file = &sync_unit_dir()."/$u";
	my $cur = -r $file ? &read_file_contents($file) : "";
	next if (!$force && $cur eq $want{$u});
	eval {
		local $main::error_must_die = 1;
		&write_file_contents($file, $want{$u});
		};
	return (\@done, &text('svc_ewrite', $file, "$@")) if ($@);
	push(@changed, $u);
	push(@done, ($cur ? "updated " : "installed ").$u);
	$reload = 1;
	}

&systemctl("daemon-reload") if ($reload);

foreach my $u (sort keys %want) {
	next if ($u =~ /\.service$/);	# tek seferlik is: enable/start edilmez
	my ($en) = &systemctl("is-enabled", $u);
	if (!$en) {
		&systemctl("enable", $u);
		push(@done, "enabled $u");
		}
	# daemon-reload dosyayi yeniden okutur ama CALISAN birim eski
	# yapilandirmasiyla devam eder - izlenen dizin degisseydi degisiklik
	# hic uygulanmazdi. Bu yuzden dosya degistiyse yeniden baslatiyoruz.
	if (&indexof($u, @changed) >= 0) {
		&systemctl("restart", $u);
		push(@done, "restarted $u");
		next;
		}
	my ($ac) = &systemctl("is-active", $u);
	if (!$ac) {
		my ($ok, $out) = &systemctl("start", $u);
		push(@done, $ok ? "started $u" : "could not start $u: $out");
		}
	}
return (\@done, undef);
}

# remove_sync_units() - modul kaldirilirken birimleri de goturur.
sub remove_sync_units
{
return 0 if (!&have_systemd());
my $svc = &sync_service();
my $n = 0;
foreach my $u ("$svc.path", "$svc.timer", "$svc.service") {
	my $file = &sync_unit_dir()."/$u";
	next if (!-e $file);
	&systemctl("disable", "--now", $u);
	unlink($file);
	$n++;
	}
&systemctl("daemon-reload") if ($n);
return $n;
}

1;
