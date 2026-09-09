# vmkit-cloudflare - Virtualmin feature sozlesmesi.
#
# vmkit-deploy ile SIMETRIK: domain basina bir ozellik. Her domainin kendi
# Cloudflare API token'i vardir, cunku token hesap/zone bazlidir ve domainler
# farkli Cloudflare hesaplarinda olabilir. Global token yoktur.
#
# Ozelligin bir domainde acilmasi: kayit dosyasini olusturur ve otomatik
# senkron servisinin ayakta oldugundan emin olur. Senkronun kendisi token
# girildikten sonra baslar.
use strict;
use warnings;
our (%text, %config);
our $module_name;

require 'vmkit-cloudflare-lib.pl';

# feature_name()
sub feature_name
{
return $text{'feat_name'};
}

# feature_label(in-edit-form)
sub feature_label
{
my ($edit) = @_;
return $edit ? $text{'feat_label2'} : $text{'feat_label'};
}

sub feature_losing
{
return $text{'feat_losing'};
}

sub feature_disname
{
return $text{'feat_disname'};
}

# feature_check()
sub feature_check
{
return undef;
}

# feature_suitable(&parentdom, &aliasdom, &subdom)
# Alias domainlerin kendi zone'u yok; alt sunucularin kayitlari ust zone'a
# yaziliyor. Bu yuzden yalnizca ust duzey sunucular icin anlamli.
sub feature_suitable
{
my ($parentdom, $aliasdom, $subdom) = @_;
return $aliasdom || $parentdom ? 0 : 1;
}

# feature_depends(&domain)
# Senkronlayacak bir zone gerektigi icin DNS ozelligi sart.
sub feature_depends
{
my ($d) = @_;
return $d->{'dns'} ? undef : $text{'feat_edepdns'};
}

# feature_setup(&domain)
# Kayit dosyasini varsayilanlarla olusturur; token panelden girilir. Token
# girilene kadar domain senkrona hic girmez (sync_domains).
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'setup_start'});
# Varsayilan, modul ayarlarindan gelir (Features and Plugins -> Configure).
&save_cf($d, { 'proxy'   => $config{'default_proxy'} ? 1 : 0,
	       'enabled' => 1 });
# Ilk domain acilirken izleme servisinin ayakta oldugundan emin ol: modul
# elle kopyalanmis, yani postinstall.pl hic calismamis olabilir.
&ensure_sync_units();
&$virtual_server::second_print($text{'setup_done_token'});
}

sub feature_modify
{
}

# feature_delete(&domain)
# Ozellik kaldirilinca token dahil tum ayarlari sil.
sub feature_delete
{
my ($d) = @_;
&$virtual_server::first_print($text{'delete_start'});
&delete_cf($d);
&$virtual_server::second_print($virtual_server::text{'setup_done'});
}

sub feature_disable
{
}

sub feature_enable
{
}

sub feature_validate
{
return undef;
}

# feature_links(&domain)
# Domainin menusune ikon ekler.
sub feature_links
{
my ($d) = @_;
return ( { 'mod'   => $module_name,
	   'desc'  => $text{'links_link'},
	   'page'  => 'index.cgi?dom='.$d->{'id'},
	   'cat'   => 'server',
	   'order' => 560 } );
}

# feature_webmin(&main-domain, &all-domains)
# Domain sahibi kendi domaininin Cloudflare ayarlarini yonetebilsin.
sub feature_webmin
{
my ($d, $alldoms) = @_;
my @doms = map { $_->{'dom'} } grep { $_->{$module_name} } @$alldoms;
return @doms ? ( [ $module_name, { 'dom' => join(" ", @doms),
				   'noconfig' => 1 } ] ) : ( );
}

sub feature_modules
{
return ( [ $module_name, $text{'feat_module'} ] );
}

# ---------------------------------------------------------------------------
# YEDEK / GERI YUKLEME
#
# Tasinan: token, proxy tercihi ve otomatik senkron anahtari.
#
# TOKEN HAM DOSYADAN OKUNUYOR (get_cf degil): diskte zaten okunaksiz bicimde
# duruyor ve oyle kalsin istiyoruz. get_cf ile okusaydik yedege duz metin
# yazardik - okunaksizlastirmanin ana sebeplerinden biri tam da yedekti.
#
# Tasinmayanlar:
#   zone_id      Cloudflare'in zone kimligi. Yoksa cf_zone_id kendisi bulup
#                yaziyor; eski bir id (domain baska hesaba tasinmissa) sessiz
#                ve kafa karistirici hatalara yol acardi.
#   last_status  Baska bir sunucudaki eski bir calismanin sonucu; yaniltici.
#   last_time
# ---------------------------------------------------------------------------

# feature_backup_name()
sub feature_backup_name
{
return $text{'backup_name'};
}

# feature_backup(&domain, dosya, &opts, homeformat?, differential?, as-owner,
#                &all-opts, &destinations)
sub feature_backup
{
my ($d, $file, $opts, $homefmt, $increment, $asd) = @_;
&$virtual_server::first_print($text{'backup_doing'});

my %cf;
&read_file(&domain_file($d), \%cf);
my %out;
foreach my $k ('token', 'proxy', 'enabled') {
	$out{$k} = $cf{$k} if (defined($cf{$k}));
	}

my $err;
eval { &write_file($file, \%out); };
$err = $@;
if ($err) {
	$err =~ s/\s+at\s+\S+\s+line\s+\d+.*//;
	&$virtual_server::second_print(&text('backup_efile', $err));
	return 0;
	}

# Domain sahibi kendi yedegini aliyorsa arsivi paketleyen o; dosyayi
# okuyabilmeli. Root aliyorsa 0600 root'ta kalsin.
if ($asd) {
	&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0600, $file);
	}
else {
	&set_ownership_permissions(undef, undef, 0600, $file);
	}

&$virtual_server::second_print($out{'token'} ? $text{'backup_done'}
					     : $text{'backup_done_notoken'});
return 1;
}

# feature_restore(&domain, dosya, &opts, &all-opts)
sub feature_restore
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'restore_doing'});

my %in;
if (!&read_file($file, \%in)) {
	&$virtual_server::second_print($text{'restore_eread'});
	return 0;
	}

# save_cf KULLANILMIYOR: o, token'i sifreleyerek yaziyor; elimizdeki deger
# yedekten geldigi icin zaten o bicimde. Ikinci kez sifrelemek onu bozardi.
# Mevcut kaydin uzerine yaziyoruz - zone_id ve son calisma bilgisi bilerek
# dusuyor, ikisi de kendiliginden yeniden olusuyor.
my $file2 = &domain_file($d);
my $dir = &domains_dir();
-d $dir || &make_dir($dir, 0700, 1);
&lock_file($file2);
&write_file($file2, \%in);
&unlock_file($file2);
chmod(0600, $file2);

&$virtual_server::second_print($in{'token'} ? $text{'restore_done'}
					   : $text{'restore_done_notoken'});
return 1;
}

1;
