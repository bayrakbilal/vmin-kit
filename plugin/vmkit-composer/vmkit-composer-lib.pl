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
sub list_projects
{
my ($d) = @_;
my $home = $d->{'home'};
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
sub run_composer
{
my ($d, $p, $action) = @_;
my $composer = &composer_command();
return (0, $text{'err_nocomposer'}) if (!$composer);

my %args = ( 'install'       => "install --no-interaction --no-progress",
	     'update'        => "update --no-interaction --no-progress",
	     'dump-autoload' => "dump-autoload --no-interaction" );
my $sub = $args{$action};
return (0, $text{'err_action'}) if (!$sub);

my $inner = "cd ".quotemeta($p->{'dir'})." && ".
	    ($p->{'php'} ? quotemeta($p->{'php'})." " : "").
	    quotemeta($composer)." ".$sub;
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 900);
return (0, $text{'err_timeout'}) if ($timed);
return ($? ? 0 : 1, $out);
}

1;
