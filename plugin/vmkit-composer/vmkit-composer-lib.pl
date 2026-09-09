# vmkit-composer yardimci fonksiyonlari.
#
# Kayit tutmuyoruz: projeler her seferinde diskten bulunur. Deploy'dan farki
# bu - orada kullanicinin tanimladigi bir yapilandirma var, burada yok.
#
# ONEMLI: composer, klasorun KENDI PHP surumuyle calistirilir. Virtualmin
# klasor basina PHP surumu tutabiliyor; yanlis surumle kurulan bagimliliklar
# sessizce bozuk olurdu.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, $module_name, $module_config_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

sub can_edit_domain
{
my ($d) = @_;
return &virtual_server::can_edit_domain($d);
}

# composer_command() -> composer yolu (yoksa undef)
sub composer_command
{
return &has_command("composer");
}

# php_for_dir(&domain, mutlak-dizin) -> (surum, php-binary)
# Klasore en ozel eslesen Virtualmin PHP tanimini bulur.
sub php_for_dir
{
my ($d, $dir) = @_;
my @pd = eval { &virtual_server::list_domain_php_directories($d) };
# Website yoksa fonksiyon hash degil metin donduruyor - o durumda sistem
# varsayilani kullanilir.
return (undef, undef) if ($@ || !@pd || !ref($pd[0]));
my $best;
foreach my $p (@pd) {
	next if (index($dir."/", $p->{'dir'}."/") != 0);
	$best = $p if (!$best || length($p->{'dir'}) > length($best->{'dir'}));
	}
return (undef, undef) if (!$best || !$best->{'version'});
# cgimode 2 = "-cgi ile biten komutlari ele" yani KOMUT SATIRI PHP'si.
# Varsayilan 0 degil: o mod aday listesinde once php<ver>-cgi'yi deniyor ve
# composer CGI SAPI ile calisinca "should be invoked via the CLI version"
# uyarisi verip hicbir sey yapmiyor.
my $cmd = &virtual_server::php_command_for_version($best->{'version'}, 2);
return ($best->{'version'}, $cmd);
}

# list_projects(&domain) -> [ { dir, rel, ver, php } ]
# Ana dizin altinda composer.json arar; vendor, node_modules ve .git atlanir.
# web_root(&domain) -> taranacak en ust dizin (mutlak yol)
#
# Ev dizinine degil, WEB dizinine bakiyoruz: ev dizininde panelin kendi
# klasorleri, e-posta, gunlukler ve alt sunucularin dizinleri duruyor.
#
# Belge kokunun kendisini degil ILK PARCASINI aliyoruz: Virtualmin'in
# "Website documents sub-directory" ayari public_html/public gibi bir alt
# klasoru gosterebiliyor (Laravel ve benzerleri boyle kuruluyor) ve o durumda
# composer.json bir ust dizinde, public_html'in kendisinde olur.
sub web_root
{
my ($d) = @_;
my $home = $d->{'home'};
return undef if (!$home);
my $abs = &virtual_server::public_html_dir($d);
my $rel = "public_html";
if ($abs && $abs =~ /^\Q$home\E\/(.+)$/) {
	$rel = $1;
	$rel =~ s/\/.*$//;
	}
return "$home/$rel";
}

sub list_projects
{
my ($d) = @_;
my $home = &web_root($d);
return ( ) if (!$home || !-d $home);
my $depth = $config{'scan_depth'} || 3;
$depth =~ /^\d+$/ || ($depth = 3);
my $inner = "find ".quotemeta($home)." -maxdepth ".($depth + 1).
	    " -type f -name composer.json".
	    " -not -path ".quotemeta("*/vendor/*").
	    " -not -path ".quotemeta("*/node_modules/*").
	    " -not -path ".quotemeta("*/.git/*");
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>/dev/null", 30);
return ( ) if ($timed);
my @rv;
foreach my $l (split(/\r?\n/, $out)) {
	next if ($l !~ /^\Q$home\E\/(.*)\/composer\.json$/ &&
		 $l !~ /^\Q$home\E\/(composer\.json)$/);
	my $dir = $l;
	$dir =~ s/\/composer\.json$//;
	my $rel = $dir;
	$rel =~ s/^\Q$home\E\/?//;
	$rel = "." if ($rel eq '');
	my ($ver, $php) = &php_for_dir($d, $dir);
	push(@rv, { 'dir' => $dir, 'rel' => $rel, 'ver' => $ver, 'php' => $php });
	}
return sort { $a->{'rel'} cmp $b->{'rel'} } @rv;
}

# valid_project(&domain, mutlak-dizin) -> proje hash'i ya da undef
# Baglantidan gelen dizini asla dogrudan kullanmiyoruz: taramada bulunan
# projelerden biri olmak zorunda.
sub valid_project
{
my ($d, $dir) = @_;
my ($p) = grep { $_->{'dir'} eq $dir } &list_projects($d);
return $p;
}

# run_composer(&domain, &project, action) -> (basarili?, cikti)
# run_streaming(komut, saniye, geri-cagirma) -> (cikti, zaman-asimi?, basarili?)
#
# Cocugu bir boruda okuyup HER SATIRI once geri cagirmaya veriyor, sonra
# biriktiriyor: sayfa is ilerledikce dolabiliyor. backquote_with_timeout
# bunu yapamiyor cunku ancak komut bitince donuyor.
#
# Zaman asimi alarm ile: <$fh> engelleyici, alarm okumayi bolup eval'den
# atliyor. TERM gonderilmezse zaman asimindan sonra da calisan bir komut
# kalirdi. (vmkit-deploy'da ayni fonksiyonun ikizi var - Webmin modulleri
# birbirinin kutuphanesine baglanmasin diye bilerek kopyalandi.)
sub run_streaming
{
my ($cmd, $secs, $cb) = @_;
my ($out, $timed) = ("", 0);
my $fh;
my $pid = open($fh, "-|", $cmd);
return ("$cmd: $!", 0, 0) if (!$pid);
eval {
	local $SIG{'ALRM'} = sub { $timed = 1; die "timeout\n"; };
	alarm($secs);
	while(my $l = <$fh>) {
		$out .= $l;
		$l =~ s/\r?\n$//;
		&$cb($l);
		}
	alarm(0);
	};
alarm(0);
if ($timed) {
	kill('TERM', $pid);
	close($fh);
	return ($out, 1, 0);
	}
close($fh);
return ($out, 0, $? == 0 ? 1 : 0);
}

# ---------------------------------------------------------------------------
# EK BAYRAKLAR
#
# Modul ayarlarinda ONAY KUTUSU olarak seciliyor (config.info tip 2, "many of
# many"; secilenler virgulle ayrilmis saklaniyor). Serbest metin kutusu
# DEGIL: boylece yazim hatasi ve kabuk kacisi derdi yok, hangi secenegin var
# oldugu da ekranda duruyor.
#
# Anahtarlarda TIRE YOK ('nodev', 'no-dev' degil): config.info satiri
# virgulle bolunuyor ve deger/etiket ayirici ilk '-' oluyor
# (/^(\S*)\-(.*)$/), tireli bir deger yanlis bolunurdu.
#
# TUZAK: ayni is icin komuta gore bayrak ADI degisiyor. Composer'in kendi
# belgesinden (doc/03-cli.md) dogrulandi:
#   install / update -> --optimize-autoloader
#   dump-autoload    -> --optimize
# Bu yuzden esleme komut basina.
#
# '--no-scripts' composer'in GENEL secenegi, uc komutta da gecerli.
sub composer_flag_map
{
return (
  'nodev'     => { 'install'       => '--no-dev',
		   'update'        => '--no-dev',
		   'dump-autoload' => '--no-dev' },
  'optimize'  => { 'install'       => '--optimize-autoloader',
		   'update'        => '--optimize-autoloader',
		   'dump-autoload' => '--optimize' },
  'classmap'  => { 'install'       => '--classmap-authoritative',
		   'update'        => '--classmap-authoritative',
		   'dump-autoload' => '--classmap-authoritative' },
  'noscripts' => { 'install'       => '--no-scripts',
		   'update'        => '--no-scripts',
		   'dump-autoload' => '--no-scripts' },
  );
}

# composer_flags(eylem) -> o eylem icin eklenecek bayraklar
sub composer_flags
{
my ($action) = @_;
my %map = &composer_flag_map();
my @rv;
# Bilinmeyen anahtar sessizce atlanir: ayar dosyasi elle duzenlenmis ya da
# eski bir surumden kalmis olabilir.
foreach my $k (split(/,/, $config{'flags'} || '')) {
	$k =~ s/^\s+|\s+$//g;
	next if (!$k || !$map{$k});
	push(@rv, $map{$k}->{$action}) if ($map{$k}->{$action});
	}
return @rv;
}

# Komut zaman asimi. Ayarda yoksa 900: modul yukseltilirken var olan config
# dosyasina yeni anahtarlar EKLENMIYOR (update-plugins.sh yalnizca dosya
# yoksa kopyaliyor), o yuzden her okuma kendi varsayilanini tasimali.
sub composer_timeout
{
my $t = $config{'timeout'};
return $t && $t =~ /^\d+$/ && $t > 0 ? $t : 900;
}

# run_composer(&domain, &proje, eylem, [&geri-cagirma]) -> (basarili?, cikti)
#
# Geri cagirma verilirse cikti satir satir ona gonderilir ve sayfa is
# ilerledikce dolar; verilmezse eskisi gibi toplu doner.
sub run_composer
{
my ($d, $p, $action, $cb) = @_;
my $composer = &composer_command();
return (0, $text{'err_nocomposer'}) if (!$composer);

my %args = ( 'install'       => "install --no-interaction --no-progress",
	     'update'        => "update --no-interaction --no-progress",
	     'dump-autoload' => "dump-autoload --no-interaction" );
my $sub = $args{$action};
return (0, $text{'err_action'}) if (!$sub);
my $extra = join(" ", &composer_flags($action));
$sub .= " ".$extra if ($extra);

my $inner = "cd ".quotemeta($p->{'dir'})." && ".
	    ($p->{'php'} ? quotemeta($p->{'php'})." " : "").
	    quotemeta($composer)." ".$sub;
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my $secs = &composer_timeout();
my ($out, $timed, $ok);
if ($cb) {
	($out, $timed, $ok) = &run_streaming("$cmd 2>&1", $secs, $cb);
	}
else {
	($out, $timed) = &backquote_with_timeout("$cmd 2>&1", $secs);
	$ok = !$timed && !$? ? 1 : 0;
	}
# Zaman asiminda ciktinin UZERINE yazmiyoruz: o ana kadar akan satirlar
# ekranda duruyor, donen ciktida da dursun. Not sona ekleniyor.
$out .= "\n".$text{'err_timeout'}."\n" if ($timed);
return ($ok, $out);
}

# composer_packages(&domain, &proje) -> (\@paket, hata)
# 'composer show --latest --format=json' kurulu paketleri, her birinin surumunu
# ve varsa daha yeni surumunu tek seferde veriyor; ayrica 'outdated'
# calistirmaya gerek kalmiyor.
#
# vendor/ yoksa composer hata verir - o hatayi oldugu gibi gosteriyoruz, cunku
# kullaniciya "once install calistir" demenin en dogru yolu composer'in kendi
# mesaji. --latest agdan surum sorgusu yaptigi icin zaman asimi genis.
sub composer_packages
{
my ($d, $p) = @_;
my $composer = &composer_command();
return (undef, $text{'err_nocomposer'}) if (!$composer);

my $inner = "cd ".quotemeta($p->{'dir'})." && ".
	    ($p->{'php'} ? quotemeta($p->{'php'})." " : "").
	    quotemeta($composer)." show --latest --format=json --no-interaction";
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 300);
return (undef, $text{'err_timeout'}) if ($timed);
return (undef, $out) if ($?);

my $j;
eval { $j = &convert_from_json($out); };
return (undef, $text{'err_badjson'}) if ($@ || ref($j) ne 'HASH');
return ($j->{'installed'} || [ ], undef);
}

1;
