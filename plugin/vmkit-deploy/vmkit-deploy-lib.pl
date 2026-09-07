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

our (%config, %text, $module_name, $module_config_directory);

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
sub deploy_root
{
my ($d) = @_;
my $root = &virtual_server::public_html_dir($d);
return undef if (!$root);
$root =~ s/\/+$//;
return $root;
}

# deploy_root_rel(&domain) -> ayni dizinin ev dizinine gore hali (mesajlar icin)
sub deploy_root_rel
{
my ($d) = @_;
my $root = &deploy_root($d) || return "public_html";
my $rel = $root;
$rel =~ s/^\Q$d->{'home'}\E\/?//;
return $rel eq '' ? "." : $rel;
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
# ---- deploy islemi ------------------------------------------------------
# Git verisi web kokunun DISINDA durur:
#     ~/.vmkit/repos/<id>.git      (bare)
#         |  git --work-tree=<hedef> checkout -f <dal>
#         v
#     ~/public_html/...            (yalnizca dosyalar, .git yok)
#
# Hedefe dogrudan klonlasaydik public_html/.git olusur ve yanlis bir Apache
# ayarinda repo gecmisi internete acilirdi. Ayrica '~/.git' adini bilerek
# kullanmiyoruz: ev dizini git tarafindan calisma kopyasi sanilirdi.
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

# run_deploy(&domain, &deploy) -> (basarili?, cikti)
# Tum git komutlari domainin kendi kullanicisi olarak calisir.
sub run_deploy
{
my ($d, $dep) = @_;
my $repo   = &deploy_repo_path($d, $dep);
my $target = &deploy_target_dir($d, $dep);
my $url    = $dep->{'repo'};
my $branch = $dep->{'branch'};

my $R = quotemeta($repo);
my $T = quotemeta($target);
my $B = quotemeta($branch);
my $env = "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=".
	  quotemeta(&git_ssh_command($d));

my @steps;
# Ilk deploy'da bare klon, sonrakilerde fetch. Repo BARE kalmali: core.bare
# false yapilirsa git deponun kendi dizinini calisma kopyasi sanar ve
# "refusing to fetch into branch ... checked out at ..." diyerek fetch'i
# reddeder. Bare halde --work-tree ile checkout zaten calisiyor.
push(@steps, "if [ ! -d $R ]; then ".
	     "mkdir -p ".quotemeta($d->{'home'}."/.vmkit/repos")." && ".
	     "$env git clone --bare -- ".quotemeta($url)." $R; ".
	     "fi");
push(@steps, "git --git-dir=$R remote set-url origin -- ".quotemeta($url));

# Fetch oncesi ve sonrasi dalin ucunu tutuyoruz ki ne geldigi gorulebilsin.
push(@steps, 'OLDREF=$(git --git-dir='.$R.' rev-parse -q --verify '.$B.
	     ' 2>/dev/null || true)');
push(@steps, "$env git --git-dir=$R fetch --prune origin ".
	     quotemeta("+refs/heads/*:refs/heads/*"));
push(@steps, 'NEWREF=$(git --git-dir='.$R.' rev-parse '.$B.')');
push(@steps, 'if [ -z "$OLDREF" ]; then echo; echo '.
	     quotemeta($text{'log_first'}).'; '.
	     'elif [ "$OLDREF" = "$NEWREF" ]; then echo; echo '.
	     quotemeta($text{'log_nochange'}).'; '.
	     'else echo; echo '.quotemeta($text{'log_newcommits'}).'; '.
	     'git --git-dir='.$R.' log --oneline --no-decorate "$OLDREF..$NEWREF"; '.
	     'echo; echo '.quotemeta($text{'log_changed'}).'; '.
	     'git --git-dir='.$R.' diff --stat "$OLDREF" "$NEWREF"; fi');

push(@steps, "mkdir -p $T");
# checkout -f: calisma kopyasi bu dalla ayni hale gelir. IZLENEN dosyalardan
# repoda silinmis olanlar buradan da silinir; IZLENMEYEN dosyalara (yuklemeler,
# .env) dokunulmaz - onlari yalnizca 'git clean' silerdi, kullanmiyoruz.
# Yol belirtmiyoruz ('-- .' yok) ki HEAD de dala tasinsin.
push(@steps, "git --git-dir=$R --work-tree=$T checkout -f $B");
push(@steps, "echo; echo ".quotemeta($text{'log_deployed'}));
push(@steps, "git --git-dir=$R --work-tree=$T log -1 --date=short --pretty=".
	     quotemeta("format:%h  %ad  %an  %s"));

my $inner = "set -e; ".join("; ", @steps);
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 600);
my $ok = !$timed && !$?;
$out = $text{'err_timeout'} if ($timed);

# Log ayri dosyada: key=value bicimi coksatirli degeri tasiyamaz.
my $logdir = "$module_config_directory/logs";
-d $logdir || &make_dir($logdir, 0700, 1);
my $stamp = &make_date(time());
# Webmin'in tempfile fonksiyonlari bareword dosya tanitici bekliyor; 'use
# strict' altinda bu yasak oldugu icin Virtualmin eklentilerinin kendi
# kullandigi kalipla kisa sureligine kapatiyoruz.
no strict "subs";
&open_tempfile(LOG, ">".&deploy_log_path($d, $dep));
&print_tempfile(LOG, "[$stamp] ".($ok ? "OK" : "FAILED")."\n\n".$out."\n");
&close_tempfile(LOG);
use strict "subs";

$dep->{'last_time'}   = time();
$dep->{'last_status'} = $ok ? "ok" : "failed";
&save_deploy($d, $dep);

return ($ok, $out);
}

# deploy_commits(&domain, &deploy, [adet]) -> (\@commit, hata)
# Bare repodaki dalin son commit'leri. Repo yalnizca ilk deploy'dan sonra
# olustugu icin yoksa acik bir mesaj donuyoruz.
#
# Alanlar birim ayiricisi (0x1f) ile ayriliyor: commit konusunda her noktalama
# gecebilir, metin bir ayirici guvenli olmaz.
sub deploy_commits
{
my ($d, $dep, $count) = @_;
$count = 20 if (!$count || $count !~ /^\d+$/);
my $repo = &deploy_repo_path($d, $dep);
return (undef, $text{'commits_norepo'}) if (!-d $repo);

my $fmt = '%h%x1f%an%x1f%ad%x1f%s';
my $inner = "git --git-dir=".quotemeta($repo).
	    " log --no-decorate --date=short --format=".quotemeta($fmt).
	    " -n ".int($count)." ".quotemeta($dep->{'branch'});
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

1;
