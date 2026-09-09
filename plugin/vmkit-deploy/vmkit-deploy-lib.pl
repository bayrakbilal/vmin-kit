# vmkit-deploy yardimci fonksiyonlari.
#
# Veri modeli: domain basina N adet "deployment". Her deployment bir repo ve
# bir hedef klasordur; ayni domainde iki repo iki ayri klasorde calisabilir.
#
# Saklama: her deployment icin bir dosya
#   /etc/webmin/vmkit-deploy/deploys/<domain-id>-<deploy-id>
# Webmin'in key=value bicimi kullanilir; boylece ekleme/silme atomik ve
# yedeklemesi de klasoru tarlamak kadar basit olur.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, %in, $module_name, $module_config_directory,
     $root_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

sub deploys_dir
{
return "$module_config_directory/deploys";
}

# list_deploys([&domain])
# Tum deployment'lari, ya da verilen domaine ait olanlari dondurur.
sub list_deploys
{
my ($d) = @_;
my $dir = &deploys_dir();
my @rv;
opendir(my $DIR, $dir) || return ( );
foreach my $f (readdir($DIR)) {
	next if ($f eq "." || $f eq "..");
	next if ($d && $f !~ /^\Q$d->{'id'}\E-/);
	my %dep;
	&read_file("$dir/$f", \%dep) || next;
	$dep{'file'} = "$dir/$f";
	push(@rv, \%dep);
	}
closedir($DIR);
return sort { ($a->{'name'} || '') cmp ($b->{'name'} || '') } @rv;
}

# get_deploy(&domain, id)
sub get_deploy
{
my ($d, $id) = @_;
my ($dep) = grep { $_->{'id'} eq $id } &list_deploys($d);
return $dep;
}

# save_deploy(&domain, &deploy)
# id bossa yeni bir kimlik uretir.
sub save_deploy
{
my ($d, $dep) = @_;
my $dir = &deploys_dir();
-d $dir || &make_dir($dir, 0700, 1);
$dep->{'id'} ||= time().$$;
$dep->{'dom'} = $d->{'id'};
my $file = "$dir/$d->{'id'}-$dep->{'id'}";
my %out = %$dep;
delete($out{'file'});
&lock_file($file);
&write_file($file, \%out);
&unlock_file($file);
$dep->{'file'} = $file;
return $dep;
}

# delete_deploy(&domain, &deploy)
# Yalnizca tanimi, bare repoyu ve logu siler. HEDEF KLASORE DOKUNMAZ:
# deploy edilmis site icerigi, yuklemeler ve .env yerinde kalir.
sub delete_deploy
{
my ($d, $dep) = @_;
my $file = $dep->{'file'} || &deploys_dir()."/$d->{'id'}-$dep->{'id'}";
my $repo = &deploy_repo_path($d, $dep);
if ($dep->{'id'} && -d $repo) {
	my $cmd = &command_as_user($d->{'user'}, 1, "rm -rf ".quotemeta($repo));
	&backquote_with_timeout("$cmd 2>&1", 60);
	}
unlink(&deploy_log_path($d, $dep));
unlink(&actions_path($d, $dep));
unlink(&actions_script_path($d, $dep)) if ($dep->{'id'});
&lock_file($file);
unlink($file);
&unlock_file($file);
}

# delete_domain_deploys(&domain)
sub delete_domain_deploys
{
my ($d) = @_;
foreach my $dep (&list_deploys($d)) {
	&delete_deploy($d, $dep);
	}
}

# can_edit_domain(&domain)
# Virtualmin'in yetki kontrolunu kullanir: master admin, reseller ya da
# domainin sahibi duzenleyebilir.
sub can_edit_domain
{
my ($d) = @_;
return &virtual_server::can_edit_domain($d);
}

# validate_target(&domain, yol)
# Hedef domainin BELGE KOKUNUN (public_html) altinda olmali. Ev dizininde
# panelin kendi klasorleri, e-posta, gunlukler ve alt sunucularin dizinleri
# duruyor; oraya deploy etmek karisikliktan baska bir sey getirmez ve ana
# domainin panelinden alt sunucunun icine yazmayi mumkun kilar.
#
# Uygulama belge kokunu bir alt klasore tasiyorsa (Laravel gibi) Virtualmin'in
# kendi ayari kullanilir: Website Options -> Website documents sub-directory =
# public_html/public. Deploy yine public_html'e yapilir, kok asagi kayar.
sub validate_target
{
my ($d, $path) = @_;
return $text{'err_target_empty'} if ($path eq '');
return $text{'err_target_abs'}   if ($path =~ /^\//);
return $text{'err_target_dots'}  if ($path =~ /(^|\/)\.\.(\/|$)/);
return $text{'err_target_char'}  if ($path !~ /^[A-Za-z0-9._\-\/]+$/);

my $root = &deploy_root($d);
return $text{'err_target_nohtml'} if (!$root);
my $full = "$d->{'home'}/$path";
return &text('err_target_outside', &deploy_root_rel($d))
	if ($full ne $root && $full !~ /^\Q$root\E\//);
return undef;
}

# deploy_root(&domain) -> deploy edilebilecek en ust dizin (mutlak yol)
#
# Belge kokunun ILK parcasi. Virtualmin'in "Website documents sub-directory"
# ayari public_html/public gibi bir alt klasoru gosterebiliyor (Laravel ve
# benzerleri boyle kuruluyor); o durumda proje koku yine public_html'dir,
# public yalnizca onun icindeki yayin klasoru. Dolayisiyla belge kokunun
# kendisini degil, ilk parcasini aliyoruz.
sub deploy_root
{
my ($d) = @_;
my $home = $d->{'home'};
return undef if (!$home);
my $abs = &virtual_server::public_html_dir($d);
my $rel = "public_html";
if ($abs && $abs =~ /^\Q$home\E\/(.+)$/) {
	$rel = $1;
	$rel =~ s/\/.*$//;	# ilk parca
	}
return "$home/$rel";
}

# deploy_root_rel(&domain) -> ayni dizinin ev dizinine gore hali
sub deploy_root_rel
{
my ($d) = @_;
my $root = &deploy_root($d) || return "public_html";
my $rel = $root;
$rel =~ s/^\Q$d->{'home'}\E\/?//;
return $rel eq '' ? "public_html" : $rel;
}

# target_sub(&domain, hedef) -> hedefin koke gore kalan parcasi (form icin)
# Depoda hedef EV DIZININE gore saklaniyor (public_html/app gibi); formda ise
# yalnizca kok altindaki kismi gosteriyoruz.
sub target_sub
{
my ($d, $target) = @_;
my $rel = &deploy_root_rel($d);
return "" if (!defined($target) || $target eq '' || $target eq $rel);
my $sub = $target;
return $sub if ($sub !~ s/^\Q$rel\E\///);
return $sub;
}

# target_full(&domain, alt-yol) -> ev dizinine gore saklanacak hedef
sub target_full
{
my ($d, $sub) = @_;
my $rel = &deploy_root_rel($d);
$sub = '' if (!defined($sub));
$sub =~ s/^\/+//; $sub =~ s/\/+$//;
return $sub eq '' ? $rel : "$rel/$sub";
}

# deploy_target_dir(&domain, &deploy) -> mutlak yol
sub deploy_target_dir
{
my ($d, $dep) = @_;
return "$d->{'home'}/$dep->{'target'}";
}

# validate_repo_url(url)
# Semadan hemen sonra alfanumerik bekliyoruz: bu, '-' ile baslayip git'e
# secenek gibi gecen ya da 'ext::<komut>' gibi calistirilabilir URL'leri eler.
sub validate_repo_url
{
my ($url) = @_;
return $text{'save_erepo'} if ($url !~ /\S/);
return $text{'save_erepourl'}
	if ($url !~ /^(https:\/\/|http:\/\/|ssh:\/\/|git\@)[A-Za-z0-9]/);
return undef;
}

# remote_branches(&domain, url)
# Uzak repoyu 'git ls-remote' ile sorgular - klonlamaz, yalnizca ref listesini
# alir. Komut DOMAININ KENDI KULLANICISI olarak calisir ki ozel repolarda o
# kullanicinin SSH anahtari kullanilsin.
# Doner: (varsayilan-dal, \@dallar, hata)
sub remote_branches
{
my ($d, $url) = @_;
my $err = &validate_repo_url($url);
return (undef, undef, $err) if ($err);

# BatchMode: parola sorulursa beklemek yerine hemen hata versin.
my $inner = "GIT_TERMINAL_PROMPT=0 ".
	    "GIT_SSH_COMMAND=".quotemeta(&git_ssh_command($d))." ".
	    "git ls-remote --symref -- ".quotemeta($url);
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 25);
return (undef, undef, $text{'err_timeout'}) if ($timed);
return (undef, undef, $out) if ($?);

my ($default, @branches);
foreach my $l (split(/\r?\n/, $out)) {
	if ($l =~ /^ref:\s+refs\/heads\/(\S+)\s+HEAD$/) {
		$default = $1;
		}
	elsif ($l =~ /^\S+\s+refs\/heads\/(.+)$/) {
		push(@branches, $1);
		}
	}
return (undef, undef, $text{'err_nobranches'}) if (!@branches);
$default ||= $branches[0];
return ($default, \@branches, undef);
}
# ---- domainin SSH anahtari ----------------------------------------------
# Domain basina TEK anahtar, standart konumda: ~/.ssh/id_ed25519
# Bu anahtarin acik kismi GitHub/Gitea'da HESABA eklenir (Settings -> SSH
# keys), tek bir repoya "deploy key" olarak degil. Boylece o hesabin
# erisebildigi butun ozel repolar bu domain icin calisir.
#
# Not: deploy key yolu da mumkun ama GitHub bir deploy anahtarini yalnizca tek
# bir repoda kabul ediyor; ikinci ozel repo eklendiginde tikanir.
sub domain_key_path
{
my ($d) = @_;
return $d->{'home'}."/.ssh/id_ed25519";
}

# domain_key_pub(&domain) -> acik anahtar metni (yoksa undef)
sub domain_key_pub
{
my ($d) = @_;
my $pub = &domain_key_path($d).".pub";
return undef if (!-r $pub);
my $txt = &read_file_contents($pub);
$txt =~ s/\s+$//;
return $txt;
}

# ensure_domain_key(&domain) -> hata mesaji ya da undef
# Anahtari domainin kendi kullanicisi olarak uretir; sahiplik ve izinler
# bastan dogru olsun diye root olarak uretip sonra chown yapmiyoruz.
sub ensure_domain_key
{
my ($d) = @_;
return undef if (&domain_key_pub($d));
my $path = &domain_key_path($d);
my $sshdir = $d->{'home'}."/.ssh";
my $inner = "mkdir -p ".quotemeta($sshdir)." && ".
	    "chmod 700 ".quotemeta($sshdir)." && ".
	    "ssh-keygen -q -t ed25519 -N '' -f ".quotemeta($path).
	    " -C ".quotemeta("vmkit ".$d->{'dom'});
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 30);
return $text{'err_timeout'} if ($timed);
return $out if ($?);
return &domain_key_pub($d) ? undef : ($out || $text{'key_efail'});
}

# git_ssh_command(&domain)
# Anahtar standart konumda oldugu icin -i vermeye gerek yok; ssh kendisi
# buluyor. BatchMode: parola sorulursa beklemek yerine hemen hata versin.
sub git_ssh_command
{
my ($d) = @_;
return "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new".
       " -o ConnectTimeout=10";
}
# ---- calistirma ---------------------------------------------------------
# Git verisi web kokunun DISINDA durur:
#     ~/.vmkit/repos/<id>.git      (bare)
#         |  git --work-tree=<hedef> checkout -f <dal>
#         v
#     ~/public_html/...            (yalnizca dosyalar, .git yok)
#
# Hedefe dogrudan klonlasaydik public_html/.git olusur ve yanlis bir Apache
# ayarinda repo gecmisi internete acilirdi. Ayrica '~/.git' adini bilerek
# kullanmiyoruz: ev dizini git tarafindan calisma kopyasi sanilirdi.
#
# CEKME ile DAGITIM ayri iki islem:
#   pull    uzak repodan bare repoya fetch. Site DEGISMEZ; ne geldigini
#           Commit'ler sayfasindan gorup sonra dagitmaya karar verirsin.
#   deploy  bare repodaki dali hedefe yazar ve varsa dagitim sonrasi
#           komutlari calistirir.
# Otomatik moddaki deployment (ve webhook) 'both' kullanir: ceker ve dagitir.
# Manuel modda cekme dagitimi tetiklemez.
sub deploy_repo_path
{
my ($d, $dep) = @_;
return $d->{'home'}."/.vmkit/repos/".$dep->{'id'}.".git";
}

sub deploy_log_path
{
my ($d, $dep) = @_;
return "$module_config_directory/logs/$d->{'id'}-$dep->{'id'}.log";
}

sub deploy_log_read
{
my ($d, $dep) = @_;
return &read_file_contents(&deploy_log_path($d, $dep));
}

# Log dizini. Kanca isi ciktisini kabuktan yonlendirdigi icin dizin ISIN
# BASLAMASINDAN once var olmali; deploy_run'in kendi kontrolu gec kalirdi.
sub ensure_log_dir
{
my $dir = "$module_config_directory/logs";
-d $dir || &make_dir($dir, 0700, 1);
return $dir;
}

# ---- dagitim sonrasi komutlar -------------------------------------------
# Komutlar key=value bicimine sigmiyor (coksatirli), o yuzden log gibi ayri
# bir dosyada duruyorlar. Icerik kullanicinin yazdigi kabuk satirlari;
# standart bir liste ya da sablon YOK - ne yazarsa o calisir.
sub actions_path
{
my ($d, $dep) = @_;
return "$module_config_directory/actions/$d->{'id'}-$dep->{'id'}";
}

sub actions_read
{
my ($d, $dep) = @_;
my $t = &read_file_contents(&actions_path($d, $dep));
return defined($t) ? $t : "";
}

sub actions_write
{
my ($d, $dep, $text) = @_;
my $dir = "$module_config_directory/actions";
-d $dir || &make_dir($dir, 0700, 1);
my $file = &actions_path($d, $dep);
if (!defined($text) || $text !~ /\S/) {
	unlink($file);
	return;
	}
$text =~ s/\r\n/\n/g;
$text .= "\n" if ($text !~ /\n$/);
no strict "subs";
&open_tempfile(ACT, ">".$file);
&print_tempfile(ACT, $text);
&close_tempfile(ACT);
use strict "subs";
}

# domain_php_bin(&domain, mutlak-dizin) -> (surum, php-binary)
# Klasore en ozel eslesen Virtualmin PHP tanimini bulur. vmkit-composer ayni
# mantigi kendi icinde tasiyor: iki modul birbirinden bagimsiz kurulabilsin
# diye bilerek paylasmiyoruz.
sub domain_php_bin
{
my ($d, $dir) = @_;
my @pd = eval { &virtual_server::list_domain_php_directories($d) };
return (undef, undef) if ($@ || !@pd || !ref($pd[0]));
my $best;
foreach my $p (@pd) {
	next if (index($dir."/", $p->{'dir'}."/") != 0);
	$best = $p if (!$best || length($p->{'dir'}) > length($best->{'dir'}));
	}
return (undef, undef) if (!$best || !$best->{'version'});
# cgimode 2 = komut satiri PHP'si. Varsayilan mod php<ver>-cgi'yi de aday
# gorup CGI SAPI ile calistirabiliyor; composer o durumda hicbir sey yapmadan
# "should be invoked via the CLI version" diyor.
return ($best->{'version'},
	&virtual_server::php_command_for_version($best->{'version'}, 2));
}

# ensure_php_path_dir(&domain, dizin) -> PATH'in basina eklenecek dizin
# Icinde tek bir 'php' baglantisi var: hedef klasorun Virtualmin PHP surumu.
# Boylece kullanicinin komutlari ('php artisan migrate', 'composer install' -
# composer'in shebang'i de 'env php') dogru surumle calisir ve kimse
# /usr/bin/php8.3 gibi tam yol yazmak zorunda kalmaz.
sub ensure_php_path_dir
{
my ($d, $dir) = @_;
my (undef, $php) = &domain_php_bin($d, $dir);
return undef if (!$php);
my $bindir = $d->{'home'}."/.vmkit/bin";
my $inner = "mkdir -p ".quotemeta($bindir)." && ".
	    "ln -sfn ".quotemeta($php)." ".quotemeta($bindir."/php");
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my (undef, $timed) = &backquote_with_timeout("$cmd 2>&1", 20);
return $timed || $? ? undef : $bindir;
}

# current_ref(&domain, &deploy) -> bare repodaki dalin ucu (kisa hash)
sub current_ref
{
my ($d, $dep) = @_;
my $repo = &deploy_repo_path($d, $dep);
return undef if (!-d $repo);
my $inner = "git --git-dir=".quotemeta($repo)." rev-parse --short ".
	    quotemeta($dep->{'branch'});
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>/dev/null", 20);
return undef if ($timed || $?);
$out =~ s/\s+//g;
return $out eq '' ? undef : $out;
}

# pending(&domain, &deploy) -> cekilmis ama dagitilmamis bir sey var mi
sub pending
{
my ($d, $dep) = @_;
return 0 if (!$dep->{'pulled_ref'});
return ($dep->{'deployed_ref'} || '') ne $dep->{'pulled_ref'} ? 1 : 0;
}

# ---- adim uretenler ------------------------------------------------------
# Her biri kabuk satirlari dondurur; deploy_run hepsini 'set -e' altinda tek
# bir kullanici oturumunda calistirir.

sub git_env
{
my ($d) = @_;
return "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=".
       quotemeta(&git_ssh_command($d));
}

# Cekme: ilk seferde bare klon, sonrakilerde fetch.
# Repo BARE kalmali: core.bare false yapilirsa git deponun kendi dizinini
# calisma kopyasi sanar ve "refusing to fetch into branch ... checked out at"
# diyerek fetch'i reddeder. Bare halde --work-tree ile checkout zaten calisiyor.
sub pull_steps
{
my ($d, $dep) = @_;
my $R = quotemeta(&deploy_repo_path($d, $dep));
my $B = quotemeta($dep->{'branch'});
my $env = &git_env($d);
# <pre> icinde YALNIZCA komutlarin kendi ciktisi var: aciklama yankilayan
# 'echo' satirlari yok. Ekran bir konsol dokumu, anlatilmis bir ozet degil.
my @steps;
# OLDREF KLONDAN ONCE okunuyor: 'git clone --bare' zaten butun commit'leri
# getirdigi icin klondan sonra okunsaydi ilk cekmede bile dolu olurdu ve
# ardindan gelen fetch hicbir sey getirmeyeceginden log "yeni commit yok"
# derdi - ilk cekmede yaniltici. Repo yokken komut hata verir, OLDREF bos
# kalir, mesaj da dogru olur.
push(@steps, 'OLDREF=$(git --git-dir='.$R.' rev-parse -q --verify '.$B.
	     ' 2>/dev/null || true)');
push(@steps, "if [ ! -d $R ]; then ".
	     "mkdir -p ".quotemeta($d->{'home'}."/.vmkit/repos")." && ".
	     "$env git clone --bare -- ".quotemeta($dep->{'repo'})." $R; ".
	     "fi");
push(@steps, "git --git-dir=$R remote set-url origin -- ".
	     quotemeta($dep->{'repo'}));
# '-v': fetch getirecek bir sey yoksa VARSAYILAN OLARAK hicbir sey yazmaz
# ve ekran bombos kalirdi. Terminalde 'git pull' deyince gorunen "Already up
# to date." mesaji pull'un merge adimindan geliyor; bizde merge yok (bare
# repo + ayri checkout), o yuzden karsiligi fetch'in ayrintili ciktisi:
#   = [up to date]      main       -> main
#   4cb4a6e..ed3bea3    main       -> main
# Kendi metnimizi yazmiyoruz - bunlar git'in kendi satirlari.
push(@steps, "$env git --git-dir=$R fetch -v --prune origin ".
	     quotemeta("+refs/heads/*:refs/heads/*"));
push(@steps, 'NEWREF=$(git --git-dir='.$R.' rev-parse '.$B.')');
# Ilk cekmede OLDREF bos olur ve aralik anlamsizdir; ayni commit'te
# kalindiysa da gosterilecek bir sey yoktur - iki durumda da hicbir sey
# basilmiyor, uydurma bir metin degil.
push(@steps, 'if [ -n "$OLDREF" ] && [ "$OLDREF" != "$NEWREF" ]; then '.
	     'git --git-dir='.$R.' log --oneline --no-decorate "$OLDREF..$NEWREF"; '.
	     'git --git-dir='.$R.' diff --stat "$OLDREF" "$NEWREF"; fi');
return @steps;
}

# Dagitim: bare repodaki dali hedefe yaz.
# checkout -f: calisma kopyasi bu dalla ayni hale gelir. IZLENEN dosyalardan
# repoda silinmis olanlar buradan da silinir; IZLENMEYEN dosyalara (yuklemeler,
# .env) dokunulmaz - onlari yalnizca 'git clean' silerdi, kullanmiyoruz.
# Yol belirtmiyoruz ('-- .' yok) ki HEAD de dala tasinsin.
sub deploy_steps
{
my ($d, $dep) = @_;
my $R = quotemeta(&deploy_repo_path($d, $dep));
my $T = quotemeta(&deploy_target_dir($d, $dep));
my $B = quotemeta($dep->{'branch'});
my @steps;
push(@steps, "mkdir -p $T");
# checkout'un "Already on 'main'" satiri BILEREK duruyor. Uc durumda da ayni
# ciktigi olculdu (dosyalar ilk kez yazilirken, hicbir sey degismezken ve
# gercekten degisirken), yani dagitimin bir sey yapip yapmadigini soylemiyor -
# ama onu zaten panel soyluyor: cekme bolumu neyin geldigini, liste ve
# bekleyen dagitim kutusu da yayindaki ile cekilen ucu gosteriyor. '-q' ile
# susturulunca dagitim bolumu tek satira dusuyor ve fazla ciplak kaliyordu.
push(@steps, "git --git-dir=$R --work-tree=$T checkout -f $B");
# Yayina giren commit. '--oneline' git'in KENDI hazir bicimi ve cekme
# bolumundeki commit listesiyle ayni gorunuyor; onceki
# --pretty=format:"%h %ad %an %s" bizim uydurdugumuz bicimdi.
push(@steps, "git --git-dir=$R --work-tree=$T log -1 --oneline --no-decorate");
return @steps;
}

# Dagitim sonrasi komutlar. Kullanicinin yazdigi satirlar hedef klasorde,
# domainin kendi yetkileriyle calisir. 'set -e' altinda oldugu icin ILK
# HATADA durur: yarim kalmis bir dagitimi basarili saymiyoruz.
sub action_steps
{
my ($d, $dep) = @_;
return ( ) if (!$dep->{'actions_on'});
my $cmds = &actions_read($d, $dep);
return ( ) if ($cmds !~ /\S/);
my $target = &deploy_target_dir($d, $dep);

# Kullanicinin blogu bir BETIK DOSYASINA yaziliyor ve tek satirla
# calistiriliyor. Sebebi: komut dizesine satir sonu koyamiyoruz
# (command_as_user quotemeta'liyor, bash ters-bolu + satir sonunu satir
# devami sayip siliyor), oysa 'if'/'for' gibi yapilar satir sonu ister.
# Dosyaya yazinca kutuya ne yazildiysa aynen o calisiyor.
#
# Dosya domainin KENDI dizininde ve KENDI kullanicisinin: betigi calistiran
# da o. Ayrica orada durmasi ise yariyor - ne calistigi SSH ile de gorulebilir.
my $file = &actions_script_path($d, $dep);
my $script = "set -e
".
	     "cd ".quotemeta($target)."
";
my $bindir = &ensure_php_path_dir($d, $target);
$script .= "PATH=".quotemeta($bindir).":\"\$PATH\"
" if ($bindir);
# Kabugun kendi izlemesi: her komut calisirken loga dusuyor, dongulerin ve
# kosullarin ici dahil. Elle yankilamak cok satirli yapilari bozardi.
$script .= "set -x
";
my $body = $cmds;
$body =~ s/
/
/g;
$body .= "
" if ($body !~ /
$/);
$script .= $body;

&write_user_script($d, $file, $script) || return ( );

# Betigin basindaki 'set -x' her komutu calisirken '+ komut' olarak
# basiyor, yani ekran zaten konsol gibi ilerliyor - ayrica baslik
# yankilamaya gerek yok.
my @steps;
# Betik kendi icinde 'set -e' tasiyor; hata verirse cikis kodu sifirdan
# farkli oluyor ve disaridaki 'set -e' dagitimi durduruyor.
push(@steps, "bash ".quotemeta($file));
return @steps;
}

# actions_script_path(&domain, &deploy) -> calistirilacak betigin yolu
sub actions_script_path
{
my ($d, $dep) = @_;
return $d->{'home'}."/.vmkit/actions-".$dep->{'id'}.".sh";
}

# write_user_script(&domain, yol, icerik) -> basarili mi
# Dosyayi domainin kullanicisina ait ve yalnizca ona okunur/calistirilir
# olarak yazar (0700). Root yazip sahipligi devrediyoruz: icerigi baska
# kullanicilar gormesin, calistiran ise domainin kendisi olsun.
sub write_user_script
{
my ($d, $file, $text) = @_;
my $dir = $file;
$dir =~ s/\/[^\/]+$//;
if (!-d $dir) {
	&make_dir($dir, 0700, 1) || return 0;
	&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0700, $dir);
	}
eval {
	no warnings 'once';
	local $main::error_must_die = 1;
	&write_file_contents($file, $text);
	};
return 0 if ($@);
&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0700, $file);
return 1;
}

# run_streaming(komut, saniye, &geri-cagirma) -> (cikti, zaman-asimi, basarili)
#
# Ciktiyi SATIR SATIR okuyup hem geri cagirmaya veriyor hem biriktiriyor.
# backquote_with_timeout bunu yapamiyor: komut bitene kadar hicbir sey
# dondurmuyor, dolayisiyla sayfa da bos bekliyor. Uzun suren bir 'composer
# install' sirasinda kullanicinin ekrani bos kalmasin diye gerekiyor.
#
# Zaman asiminda sureci OLDURUYORUZ: yalnizca okumayi birakmak arkada
# calisan bir komut birakirdi.
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

# Cekme ve dagitimin tamami icin zaman asimi. Ayarda yoksa 900: modul
# yukseltilirken var olan config dosyasina yeni anahtarlar EKLENMIYOR
# (update-plugins.sh yalnizca dosya yoksa kopyaliyor), o yuzden her okuma
# kendi varsayilanini tasimali.
sub deploy_timeout
{
my $t = $config{'timeout'};
return $t && $t =~ /^\d+$/ && $t > 0 ? $t : 900;
}

# deploy_run(&domain, &deploy, op, [&geri-cagirma]) -> (basarili?, cikti)
#
# Geri cagirma verilirse cikti satir satir ona gonderiliyor ve sayfa is
# ilerledikce doluyor. Verilmezse eskisi gibi toplu donuyor - web kancasi ve
# komut satiri boyle kullaniyor, onlarin akitacak bir ekrani yok.
#   op 'pull'   yalnizca cek
#   op 'deploy' yalnizca dagit (once cekilmis olmali)
#   op 'both'   cek ve dagit
# Tum komutlar domainin kendi kullanicisi olarak, tek bir kabuk oturumunda ve
# 'set -e' altinda calisir.
sub deploy_run
{
my ($d, $dep, $op, $cb) = @_;
$op ||= 'both';
my @steps;
push(@steps, &pull_steps($d, $dep))   if ($op eq 'pull' || $op eq 'both');
if ($op eq 'deploy' || $op eq 'both') {
	if ($op eq 'deploy' && !-d &deploy_repo_path($d, $dep)) {
		# Geri cagirma varsa mesaj EKRANA da dusmeli: sayfa yalnizca
		# akan satirlari basiyor, donen $out'u kullanmiyor. Yoksa
		# hicbir sey cekilmemisken 'Dagit' bombos bir ekran veriyordu.
		&$cb($text{'err_nopull'}) if ($cb);
		return (0, $text{'err_nopull'});
		}
	push(@steps, &deploy_steps($d, $dep));
	push(@steps, &action_steps($d, $dep));
	}

# Adimlar TEK SATIRDA, ';' ile birlestiriliyor - araya satir sonu KOYULAMAZ.
# Komut command_as_user'dan gecerken quotemeta'lanıyor ve quotemeta bir satir
# sonunu ters-bolu + satir sonu yapiyor; bash bunu SATIR DEVAMI sayip siliyor,
# yani butun betik tek satira yapisiyor: "set -e" + "echo" -> "set -eecho".
# (Olculdu: 'bash -c' ayni hatayi veriyor.)
#
# Kullanicinin cok satirli yazabilmesi bu yuzden baska turlu cozuluyor: onun
# blogu ayri bir betik DOSYASINA yaziliyor ve buradan tek satirla
# calistiriliyor (bkz. action_steps).
my $inner = "set -e; ".join("; ", @steps);
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
# Dagitim sonrasi komutlar (composer install gibi) uzun surebiliyor.
my $secs = &deploy_timeout();
my ($out, $timed, $ok);
if ($cb) {
	($out, $timed, $ok) = &run_streaming("$cmd 2>&1", $secs, $cb);
	}
else {
	($out, $timed) = &backquote_with_timeout("$cmd 2>&1", $secs);
	$ok = !$timed && !$? ? 1 : 0;
	}
# Zaman asiminda ciktinin UZERINE yazmiyoruz: o ana kadar akan satirlar
# ekranda duruyor, kayit dosyasinda da dursun. Not sona ekleniyor.
$out .= "\n".$text{'err_timeout'}."\n" if ($timed);

# Log ayri dosyada: key=value bicimi coksatirli degeri tasiyamaz.
#
# Dosyaya YALNIZCA ham cikti yaziliyor - tarih/durum basligi YOK. Ikisi
# zaten deployment kaydinda (last_time, last_op, last_status) duruyor ve
# deploylog.cgi onlari oradan basiyor. Basligi buraya yazarken tarihi
# make_date ile bicimlendiriyorduk; tema make_date'i EZIYOR ve HTML
# donduruyor, o yuzden log sayfasinda ham metin olarak
# "<span data-filesize-bytes=...>" gorunuyordu.
&ensure_log_dir();
# Webmin'in tempfile fonksiyonlari bareword dosya tanitici bekliyor; 'use
# strict' altinda bu yasak oldugu icin Virtualmin eklentilerinin kendi
# kullandigi kalipla kisa sureligine kapatiyoruz.
no strict "subs";
&open_tempfile(LOG, ">".&deploy_log_path($d, $dep));
&print_tempfile(LOG, $out);
&close_tempfile(LOG);
use strict "subs";

$dep->{'last_time'}   = time();
$dep->{'last_status'} = $ok ? "ok" : "failed";
$dep->{'last_op'}     = $op;
if ($ok) {
	# Cekilen ve dagitilan ucu ayri tutuyoruz: manuel modda "cekildi ama
	# daha yayinlanmadi" durumunu bundan goruyoruz.
	my $ref = &current_ref($d, $dep);
	$dep->{'pulled_ref'} = $ref if ($ref && $op ne 'deploy');
	$dep->{'deployed_ref'} = ($dep->{'pulled_ref'} || $ref)
		if ($op ne 'pull');
	}
&save_deploy($d, $dep);

return ($ok, $out);
}

sub op_label
{
my ($op) = @_;
return $op eq 'pull'   ? $text{'op_pull'} :
       $op eq 'deploy' ? $text{'op_deploy'} : $text{'op_both'};
}

# deploy_commits(&domain, &deploy, [adet]) -> (\@commit, hata)
# Bare repodaki dalin son commit'leri. Repo yalnizca ilk deploy'dan sonra
# olustugu icin yoksa acik bir mesaj donuyoruz.
#
# Alanlar birim ayiricisi (0x1f) ile ayriliyor: commit konusunda her noktalama
# gecebilir, metin bir ayirici guvenli olmaz.
sub deploy_commits
{
my ($d, $dep) = @_;
my $repo = &deploy_repo_path($d, $dep);
return (undef, $text{'commits_norepo'}) if (!-d $repo);

# Dalin TAMAMI listeleniyor, son N tanesi degil: bu sayfa gecmise bakmak
# icin var ve nerede kesilecegini bilmiyoruz. Cikti tek satirlik kayitlar
# oldugu icin binlerce commit'te bile kucuk kaliyor.
my $fmt = '%h%x1f%an%x1f%ad%x1f%s';
my $inner = "git --git-dir=".quotemeta($repo).
	    " log --no-decorate --date=short --format=".quotemeta($fmt).
	    " ".quotemeta($dep->{'branch'});
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 30);
return (undef, $text{'err_timeout'}) if ($timed);
return (undef, $out) if ($?);

my @rv;
foreach my $l (split(/\r?\n/, $out)) {
	next if ($l !~ /\S/);
	my ($h, $an, $ad, $s) = split(/\x1f/, $l, 4);
	push(@rv, { 'hash' => $h, 'author' => $an,
		    'date' => $ad, 'subject' => $s });
	}
return (\@rv, undef);
}


# ---- duzenleme formu ----------------------------------------------------
# Form TEK YERDE ciziliyor cunku iki sayfa da gosteriyor: edit_deploy.cgi ve
# "Repoyu kontrol et" basildiginda save_deploy.cgi.
#
# Neden save_deploy.cgi de cizmek zorunda: formu iki ayri hedefe gonderecek
# tek yol dugmedeki 'formaction' niteligiydi, ama tema form gonderimini kendi
# ele aldigi icin onu yok sayiyor ve her sey formun action'ina gidiyordu -
# Kontrol dugmesi sessizce KAYDEDIP listeye donuyordu. Artik form her zaman
# save_deploy.cgi'ye gidiyor, o da 'check' basildiysa kaydetmek yerine formu
# yeniden ciziyor.

# deploy_from_in(&domain) -> (&deploy, komut-metni, yeni-mi)
# Formdan gelenleri kayitla birlestirir.
sub deploy_from_in
{
my ($d) = @_;
my $new = $in{'new'};
my $dep;
if ($new) {
	$dep = { 'branch' => '', 'target' => 'public_html', 'mode' => 'manual' };
	}
else {
	$dep = &get_deploy($d, $in{'id'});
	return ( ) if (!$dep);
	}
foreach my $f ('name', 'repo', 'branch', 'target', 'mode') {
	$dep->{$f} = $in{$f} if (defined($in{$f}) && $in{$f} ne '');
	}
my $actions;
if ($in{'check'} || $in{'regen'}) {
	# Alan eylemi turundan geliyoruz: kullanicinin yazdiklari %in'de.
	$dep->{'actions_on'} = $in{'actions_on'} ? 1 : 0;
	$actions = $in{'actions'};
	}
else {
	$actions = &actions_read($d, $dep);
	}

# Ad bos birakildiysa repo adresinin son parcasindan doldur:
# ".../vmin-kit.git" -> "vmin-kit.git". Elle bir ad yazmak cogu zaman
# gereksiz; yazan olursa ona dokunulmuyor.
if ($dep->{'repo'} && ($dep->{'name'} || '') !~ /\S/) {
	my $n = $dep->{'repo'};
	$n =~ s/\/+$//;
	$n =~ s/^.*[\/:]//;
	$n =~ s/[^A-Za-z0-9._\- ]//g;
	$dep->{'name'} = $n if ($n =~ /\S/);
	}

# Kanca adresi EKLERKEN de gorunsun. Eskiden UUID yalnizca kayittan sonra
# uretiliyordu, yani adresi almak icin "kaydet, listeye don, tekrar duzenle"
# gerekiyordu. Artik form acilirken uretiliyor, gizli alanda tasiniyor ve
# kaydederken ayni deger yaziliyor.
$dep->{'uuid'} = $in{'uuid'}
	if ($in{'uuid'} && $in{'uuid'} =~ /^[a-f0-9]{32}$/);
$dep->{'uuid'} ||= &new_uuid();

return ($dep, $actions, $new);
}

# print_deploy_form(&domain, &deploy, komut-metni, yeni-mi)
sub print_deploy_form
{
my ($d, $dep, $actions, $new) = @_;

# Repo adresi varsa dallari sorgula (klonlamaz, yalnizca ls-remote).
my ($defbranch, $branches, $rerr);
if ($dep->{'repo'}) {
	($defbranch, $branches, $rerr) = &remote_branches($d, $dep->{'repo'});
	$dep->{'branch'} ||= $defbranch;
	}

if ($rerr) {
	print "<p><b>$text{'edit_echeck'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($rerr),"</pre>\n";
	# Ozel repo ise domainin SSH anahtari GitHub/Gitea HESABINA eklenmeli.
	print "<p>",&ui_link("sshkey.cgi?dom=$d->{'id'}&new=$new&id=$dep->{'id'}".
			     "&repo=".&urlize($dep->{'repo'}),
			     $text{'edit_showkey'}),"</p>\n";
	}

print &ui_form_start("save_deploy.cgi", "post");
print &ui_hidden("dom", $d->{'id'});
print &ui_hidden("new", $new);
print &ui_hidden("id", $dep->{'id'});
# Kanca adresi kayittan once uretiliyor; formdan geri gelsin diye gizli alanda.
print &ui_hidden("uuid", $dep->{'uuid'});
print &ui_table_start($text{'edit_header'}, "width=100%", 2);

print &ui_table_row($text{'edit_name'},
	&ui_textbox("name", $dep->{'name'}, 30));

# Kontrol dugmesi ADRESIN YANINDA: o alana ait bir eylem, sayfanin altindaki
# kaydet/sil dugmeleriyle isi yok. Ayni formun icinde ayri adli bir submit,
# save_deploy.cgi ona bakip kaydetmek yerine formu yeniden ciziyor.
print &ui_table_row($text{'edit_repo'},
	&ui_textbox("repo", $dep->{'repo'}, 50)." ".
	&ui_submit($text{'edit_check'}, "check")."<br>".
	"<font size=-1>$text{'edit_repo_help'}</font>");

# Dal, repo okunana kadar secilemez - repoya bagli tek alan bu.
print &ui_table_row($text{'edit_branch'},
	$branches ? &ui_select("branch", $dep->{'branch'}, $branches, 1, 0, 0)
		  : &ui_select("branch", undef, [ ], 1, 0, 0, 1)." ".
		    "<font size=-1>$text{'edit_branch_check'}</font>");

print &ui_table_row($text{'edit_target'},
	"<tt>".&deploy_root($d)."/</tt> ".
	&ui_textbox("target", &target_sub($d, $dep->{'target'}), 25)."<br>".
	"<font size=-1>$text{'edit_target_help'}</font>");

# Acilir liste, radyo dugmesi degil: iki radyo yan yana duruken orada bir
# ayar oldugu bile fark edilmiyordu.
print &ui_table_row($text{'edit_mode'},
	&ui_select("mode", $dep->{'mode'} || 'manual',
		   [ [ "manual", $text{'mode_manual_desc'} ],
		     [ "auto",   $text{'mode_auto_desc'} ] ], 1, 0, 0));

print &ui_table_row($text{'edit_actions'},
	&ui_checkbox("actions_on", 1, $text{'edit_actions_on'},
		     $dep->{'actions_on'} ? 1 : 0)."<br>".
	&ui_textarea("actions", $actions, 6, 70)."<br>".
	"<font size=-1>".
	&text('edit_actions_help',
	      "<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>").
	"</font>");

# Kanca adresi AYNI TABLODA. Ayri bir forma alinca sayfanin dibine dusuyordu;
# oysa deployment'in bir alani ve digerleriyle birlikte durmasi gerekiyor.
# Yenileme dugmesi de kendi alaninin yaninda - ayni formda, ayri adli submit.
#
# Adres salt okunur bir kutuda: uzun ve kopyalanmasi gereken bir deger, duz
# yazi olarak metinlerin arasinda durunca hem secmesi zor hem de kayboluyordu.
print &ui_table_row($text{'edit_hook'},
	&ui_textbox("hookurl", &hook_url($dep) || '', 60, 0, undef,
		    "readonly onClick='this.select()'")." ".
	&ui_submit($text{'edit_hook_regen'}, "regen")."<br>".
	"<font size=-1>$text{'edit_hook_help'}</font>".
	($new ? "<br><font size=-1>$text{'edit_hook_new'}</font>" : "").
	(&hook_path_registered() ? "" :
		"<br><b>$text{'edit_hook_notready'}</b>"));

print &ui_table_end();

# Sayfanin altinda YALNIZCA kaydet ve sil: alanlara ait eylemler kendi
# satirlarinda duruyor.
# Dugme dizisi: [ ad, etiket, sonrasina eklenecek, devre disi, ek nitelik ]
# Kaydet, repo dogrulanana kadar devre disi - dal secilmeden kayit anlamsiz.
my @buttons = ( [ undef, $new ? $text{'create'} : $text{'save'},
		  undef, $branches ? 0 : 1 ] );
push(@buttons, [ "delete", $text{'delete'} ]) if (!$new);
print &ui_form_end(\@buttons);
}

# ---- web kancasi --------------------------------------------------------
# Plesk'teki ile ayni model: adresin icindeki UUID PAROLADIR. Adresi bilen
# tetikler, bilmeyen tetikleyemez.
#
# Bilerek YAPMADIKLARIMIZ ve nedenleri:
#   - Imza dogrulama (GitHub'in X-Hub-Signature-256'si) yok. Eklersek kanca
#     GitHub'a OZEL olurdu; Gitea, GitLab ya da elle 'curl' calismazdi.
#     UUID her yerde calisir.
#   - Gelen govde HIC OKUNMAZ. Hangi repo, hangi dal, hangi klasor zaten
#     kayitli; payload'da bize yeni bir sey yok.
#
# Bedeli: adres bir parola oldugu icin sunucunun erisim gunluklerine duser ve
# paylasmak onu paylasmak demektir. Sizdiginda formdan yeniden uretilir,
# eskisi aninda gecersiz olur. Plesk'te de durum aynidir.

# new_uuid() -> 128 bitlik rastgele kimlik (32 onaltilik karakter)
sub new_uuid
{
my $h;
if (open($h, "<", "/dev/urandom")) {
	my $b;
	my $n = read($h, $b, 16);
	close($h);
	return unpack("H*", $b) if ($n == 16);
	}
# /dev/urandom her Linux'ta var; buraya dusmemiz beklenmiyor ama sessizce
# bos bir kimlik uretmektense zayif da olsa bir sey uretelim.
return sprintf("%08x%08x%08x%08x", time(), $$, int(rand(0xffffffff)),
	       int(rand(0xffffffff)));
}

# find_by_uuid(uuid) -> (&domain, &deploy) ya da bos
# Butun domainlerdeki deployment'lar taranir: kanca kimlik dogrulamasi
# yapmadan calistigi icin hangi domain oldugunu yalnizca UUID soyluyor.
sub find_by_uuid
{
my ($uuid) = @_;
return ( ) if (!$uuid || $uuid !~ /^[a-f0-9]{16,64}$/);
foreach my $dep (&list_deploys()) {
	next if (($dep->{'uuid'} || '') ne $uuid);
	my $d = &virtual_server::get_domain($dep->{'dom'});
	next if (!$d || !$d->{'vmkit-deploy'});
	return ($d, $dep);
	}
return ( );
}

# hook_url(&deploy) -> tam adres
# Konak adini TAHMIN ETMIYORUZ: sayfayi hangi adresten actiysan kancanin
# adresi de odur. Panele vekil uzerinden girildiginde ProxyPreserveHost
# sayesinde bu zaten dis adres (webmin.<domain>) oluyor.
sub hook_url
{
my ($dep) = @_;
return undef if (!$dep->{'uuid'});
my $host = $ENV{'HTTP_HOST'} || $ENV{'SERVER_NAME'} || "";
return undef if (!$host);
return "https://$host/$module_name/hook.cgi?uuid=$dep->{'uuid'}";
}

# ---- miniserv: kimlik dogrulamasi istemeyen yol -------------------------
# Kanca adresine giris yapmadan erisilebilmesi gerekiyor. Webmin'in kendi
# ayari bunu sagliyor; ayarin ADINI TAHMIN ETMIYORUZ, miniserv.pl'in hangi
# anahtari okudugunu kaynaktan buluyoruz. Webmin surumleri arasinda
# degisirse burasi kendiliginden dogru olani secer.
sub unauth_key
{
my $mp = "$root_directory/miniserv.pl";
my $src = -r $mp ? &read_file_contents($mp) : undef;
return "unauthenticated"
	if ($src && $src =~ /config\{["']unauthenticated["']\}/);
return "unauth";
}

sub hook_path
{
return "/$module_name/hook.cgi";
}

sub miniserv_conf
{
return "$ENV{'WEBMIN_CONFIG'}/miniserv.conf";
}

# hook_path_registered() -> yol listede mi
sub hook_path_registered
{
my $conf = &miniserv_conf();
return 0 if (!-r $conf);
my $key = &unauth_key();
my $cur = "";
foreach my $l (split(/\n/, &read_file_contents($conf))) {
	$cur = $1 if ($l =~ /^\Q$key\E=(.*)$/);
	}
my $p = &hook_path();
return (grep { $_ eq $p } split(/\s+/, $cur)) ? 1 : 0;
}

# ensure_hook_path() -> (degisti mi, hata)
# Yolu listeye ekler ve miniserv'i yeniden yukler. Idempotent: zaten varsa
# hicbir sey yapmaz, dolayisiyla her kurulumda cagrilabilir.
sub ensure_hook_path
{
return (0, undef) if (&hook_path_registered());
my $conf = &miniserv_conf();
return (0, &text('hook_econf', $conf)) if (!-w $conf);
my $key = &unauth_key();
my %mc;
&read_file($conf, \%mc);
$mc{$key} = join(" ", grep { $_ ne '' }
			(split(/\s+/, $mc{$key} || ''), &hook_path()));
&lock_file($conf);
&write_file($conf, \%mc);
&unlock_file($conf);
# Ayar yalnizca miniserv yeniden yuklenince gecerli oluyor. Webmin'in kendi
# fonksiyonu bunu calisan istegi oldurmeden yapiyor (ayni seyi Webmin
# Configuration sayfalari da kullaniyor).
if (defined(&restart_miniserv)) {
	eval { &restart_miniserv(1); };
	}
return (1, undef);
}

# remove_hook_path() - modul kaldirilirken listeden cikar.
sub remove_hook_path
{
my $conf = &miniserv_conf();
return 0 if (!-w $conf);
my $key = &unauth_key();
my %mc;
&read_file($conf, \%mc);
my $p = &hook_path();
my @keep = grep { $_ ne '' && $_ ne $p } split(/\s+/, $mc{$key} || '');
return 0 if (join(" ", @keep) eq ($mc{$key} || ''));
$mc{$key} = join(" ", @keep);
&lock_file($conf);
&write_file($conf, \%mc);
&unlock_file($conf);
if (defined(&restart_miniserv)) {
	eval { &restart_miniserv(1); };
	}
return 1;
}

1;
