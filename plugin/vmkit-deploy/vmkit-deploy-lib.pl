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

# validate_target(&domain, path)
# Hedef klasor domainin home'unun ICINDE kalmali. Domain sahibi de bu formu
# kullanacagi icin bu bir guvenlik siniri: ".." ya da mutlak yol kabul edilmez.
# Hata varsa mesaj, sorun yoksa undef doner.
sub validate_target
{
my ($d, $path) = @_;
return $text{'err_target_empty'} if ($path eq '');
return $text{'err_target_abs'}   if ($path =~ /^\//);
return $text{'err_target_dots'}  if ($path =~ /(^|\/)\.\.(\/|$)/);
return $text{'err_target_char'}  if ($path !~ /^[A-Za-z0-9._\-\/]+$/);
return undef;
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

my $env = "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=".
	  quotemeta(&git_ssh_command($d));

my @steps;
# Ilk deploy'da bare klon, sonrakilerde fetch. core.bare=false yapiyoruz ki
# --work-tree ile checkout calissin.
push(@steps, "if [ ! -d ".quotemeta($repo)." ]; then ".
	     "mkdir -p ".quotemeta($d->{'home'}."/.vmkit/repos")." && ".
	     "$env git clone --quiet --bare -- ".quotemeta($url)." ".
	     quotemeta($repo)." && ".
	     "git --git-dir=".quotemeta($repo)." config core.bare false; ".
	     "fi");
push(@steps, "git --git-dir=".quotemeta($repo).
	     " remote set-url origin -- ".quotemeta($url));
push(@steps, "$env git --git-dir=".quotemeta($repo).
	     " fetch --quiet --prune origin ".
	     quotemeta("+refs/heads/*:refs/heads/*"));
push(@steps, "mkdir -p ".quotemeta($target));
# checkout -f yalnizca repodaki dosyalari yazar. Repodan SILINMIS dosyalar
# diskte kalir - bu bilerek boyle: yuklemeler, .env gibi repoda olmayan
# dosyalar silinmesin.
push(@steps, "git --git-dir=".quotemeta($repo)." --work-tree=".
	     quotemeta($target)." checkout -f ".quotemeta($branch)." -- .");
push(@steps, "git --git-dir=".quotemeta($repo)." --work-tree=".
	     quotemeta($target)." log -1 --pretty=".
	     quotemeta("format:%h %an %s"));

my $inner = "set -e; ".join("; ", @steps);
my $cmd = &command_as_user($d->{'user'}, 1, $inner);
my ($out, $timed) = &backquote_with_timeout("$cmd 2>&1", 600);
my $ok = !$timed && !$?;
$out = $text{'err_timeout'} if ($timed);

# Log ayri dosyada: key=value bicimi coksatirli degeri tasiyamaz.
my $logdir = "$module_config_directory/logs";
-d $logdir || &make_dir($logdir, 0700, 1);
my $stamp = &make_date(time());
&open_tempfile(LOG, ">".&deploy_log_path($d, $dep));
&print_tempfile(LOG, "[$stamp] ".($ok ? "OK" : "FAILED")."\n\n".$out."\n");
&close_tempfile(LOG);

$dep->{'last_time'}   = time();
$dep->{'last_status'} = $ok ? "ok" : "failed";
&save_deploy($d, $dep);

return ($ok, $out);
}

1;
