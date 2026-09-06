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
sub delete_deploy
{
my ($d, $dep) = @_;
my $file = $dep->{'file'} || &deploys_dir()."/$d->{'id'}-$dep->{'id'}";
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

# Yerel repo modunda kullaniciya verilecek push adresi (iskelet).
sub deploy_push_url
{
my ($d, $dep) = @_;
return "$d->{'user'}\@$d->{'dom'}:repos/$dep->{'id'}.git";
}

1;
