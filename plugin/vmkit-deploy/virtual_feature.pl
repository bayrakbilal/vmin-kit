# vmkit-deploy - Virtualmin feature sozlesmesi.
#
# Ozellik domain basina acilir. Ozelligin kendisi bir SEY KURMAZ: bir domainde
# acilmasi yalnizca "bu domainde deployment tanimlanabilir" demektir. Asil is
# kullanicinin tanimladigi deployment'larda (bkz. vmkit-deploy-lib.pl).
use strict;
use warnings;
our (%text, %config);
our $module_name;

require 'vmkit-deploy-lib.pl';

# feature_name()
sub feature_name
{
return $text{'feat_name'};
}

# feature_label(in-edit-form)
# Domain olusturma ve duzenleme formunda gorunen etiket.
sub feature_label
{
my ($edit) = @_;
return $edit ? $text{'feat_label2'} : $text{'feat_label'};
}

# feature_losing(&domain)
sub feature_losing
{
return $text{'feat_losing'};
}

# feature_disname(&domain)
sub feature_disname
{
return $text{'feat_disname'};
}

# feature_check()
# Ozellik kullanilabilir mi? git yoksa hata dondur.
sub feature_check
{
return &has_command("git") ? undef : $text{'feat_echeck'};
}

# feature_suitable(&parentdom, &aliasdom, &subdom)
# Alias domainlerde anlamsiz; ust duzey ve alt sunucularda kullanilabilir.
sub feature_suitable
{
my ($parentdom, $aliasdom, $subdom) = @_;
return $aliasdom ? 0 : 1;
}

# feature_depends(&domain)
# Deploy edilecek bir dizin gerektigi icin web ozelligi sart.
sub feature_depends
{
my ($d) = @_;
return $d->{'web'} ? undef : $text{'feat_edepweb'};
}

# feature_setup(&domain)
# Kurulacak bir sey yok: deployment tanimlari panelden, kullanici tarafindan
# eklenir. Ozellik yalnizca menuye erisim veriyor.
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'setup_start'});
# Ilk domainde kanca yolunun kayitli oldugundan emin ol: modul elle
# kopyalanmis, yani postinstall.pl hic calismamis olabilir.
&ensure_hook_path();
&$virtual_server::second_print($virtual_server::text{'setup_done'});
}

# feature_modify(&domain, &olddomain)
sub feature_modify
{
}

# feature_delete(&domain)
# Ozellik kaldirilinca bu domaine ait tum deployment tanimlarini sil.
sub feature_delete
{
my ($d) = @_;
&$virtual_server::first_print($text{'delete_start'});
&delete_domain_deploys($d);
&$virtual_server::second_print($virtual_server::text{'setup_done'});
}

# feature_disable(&domain) / feature_enable(&domain)
# Domain askiya alinip geri acildiginda cagriliyor. Yapacak isimiz yok:
# tanimlar dosyada duruyor, deploy zaten yalnizca elle ya da zamanlayiciyla
# tetikleniyor. Silmek feature_delete'in isi.
sub feature_disable
{
}

sub feature_enable
{
}

# feature_validate(&domain)
sub feature_validate
{
return undef;
}

# feature_links(&domain)
# Domainin sol menusune ikon ekler. Cekirdek kisayollar 500 (web apps) ve
# 600 (File Manager) arasinda yer birakiyor.
sub feature_links
{
my ($d) = @_;
return ( { 'mod'   => $module_name,
	   'desc'  => $text{'links_link'},
	   'page'  => 'index.cgi?dom='.$d->{'id'},
	   'cat'   => 'server',
	   'order' => 550 } );
}

# feature_webmin(&main-domain, &all-domains)
# Domain sahibinin kendi hesabiyla bu modulu gorebilmesi icin.
sub feature_webmin
{
my ($d, $alldoms) = @_;
my @doms = map { $_->{'dom'} } grep { $_->{$module_name} } @$alldoms;
return @doms ? ( [ $module_name, { 'dom' => join(" ", @doms),
				   'noconfig' => 1 } ] ) : ( );
}

# feature_modules()
# Sunucu sablonlarinda domain sahibine verilebilecek moduller listesinde cikar.
sub feature_modules
{
return ( [ $module_name, $text{'feat_module'} ] );
}

# ---------------------------------------------------------------------------
# YEDEK / GERI YUKLEME
#
# NEDEN GEREKLI: Webmin'in veritabani yok, her sey dosyada ve bizim
# dosyalarimiz Virtualmin'in domain yedegine KENDILIGINDEN girmiyor. Yedege
# giren tek sey, ozellik basina cagrilan feature_backup'in yazdigi dosya.
#
# NELER TASINIYOR: yalnizca /etc/webmin/vmkit-deploy altindakiler, yani
# deployment tanimlari (repo, dal, hedef, mod, kanca UUID'si) ve dagitim
# sonrasi komut metni. Domainin EV DIZININDEKILER buraya girmiyor cunku
# zaten 'dir' ozelligiyle yedekleniyorlar: ~/.vmkit/repos/<id>.git,
# ~/.vmkit/actions-<id>.sh, ~/.vmkit/bin/php ve ~/.ssh/id_ed25519.
#
# LOGLAR TASINMIYOR: gecmis bir calismanin ciktisi baska bir sunucuda
# yaniltici olur, ayrica zaten tek seferlik.
#
# DOMAIN ID'SI DEGISIR: dosya adlarimiz "<domainid>-<deploymentid>" bicimde
# ve geri yuklenen domain YENI bir id alabilir. Bu yuzden yedege domain id
# yazilmiyor; geri yuklemede kayitlar o anki $d->{'id'} ile tazeleniyor.
# ---------------------------------------------------------------------------

# feature_backup_name()
# Yedek ekranlarinda bu ozelligin ne sakladigini anlatir.
sub feature_backup_name
{
return $text{'backup_name'};
}

# feature_backup(&domain, dosya, &opts, homeformat?, differential?, as-owner,
#                &all-opts, &destinations)
# 1 = basarili, 0 = basarisiz.
sub feature_backup
{
my ($d, $file, $opts, $homefmt, $increment, $asd) = @_;
&$virtual_server::first_print($text{'backup_doing'});

my @deps = &list_deploys($d);
my @recs;
foreach my $dep (@deps) {
	my %copy = %$dep;
	# 'file' yerel yol, 'dom' yerel domain id: ikisi de bu sunucuya ait,
	# geri yuklemede yeniden uretiliyor.
	delete($copy{'file'});
	delete($copy{'dom'});
	push(@recs, { 'dep'     => \%copy,
		      'actions' => &actions_read($d, $dep) });
	}

# serialise_variable Webmin'in kendi bicimi (Virtualmin de yedek
# ustverisinde bunu kullaniyor). Kendi ayirici uydurmaktansa bunu
# kullaniyoruz: ic ice yapiyi ve coksatirli metni sorunsuz tasiyor.
my $data = &serialise_variable(\@recs);
my $err;
eval {
	no strict "subs";
	&open_tempfile(BACKUP, ">$file", 0, 1);
	&print_tempfile(BACKUP, $data);
	&close_tempfile(BACKUP);
	use strict "subs";
	};
$err = $@;
if ($err) {
	$err =~ s/\s+at\s+\S+\s+line\s+\d+.*//;
	&$virtual_server::second_print(&text('backup_efile', $err));
	return 0;
	}

# Domain sahibi kendi yedegini aliyorsa ($asd dolu) dosyayi root degil o
# okuyabilmeli - arsivi paketleyen de o. Icerik zaten kendi domainine ait
# (kanca adresi ve komutlar panelde ona zaten gorunuyor).
if ($asd) {
	&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0600, $file);
	}
else {
	&set_ownership_permissions(undef, undef, 0600, $file);
	}

&$virtual_server::second_print(&text('backup_done', scalar(@recs)));
return 1;
}

# feature_restore(&domain, dosya, &opts, &all-opts)
sub feature_restore
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'restore_doing'});

my $data = &read_file_contents($file);
if (!defined($data)) {
	&$virtual_server::second_print($text{'restore_eread'});
	return 0;
	}
my $recs = &unserialise_variable($data);
if (ref($recs) ne 'ARRAY') {
	&$virtual_server::second_print($text{'restore_ebad'});
	return 0;
	}

# Once bu domaine ait MEVCUT tanimlari temizliyoruz, yoksa yedekte olmayan
# eski bir deployment geri yuklemeden sonra da listede kalirdi.
#
# delete_deploy KULLANILMIYOR: o, bare repoyu da siliyor. Repo ev dizininde
# ve ev dizini 'dir' ozelligiyle geri yukleniyor; buradan silmek, yalnizca
# bu ozelligi geri yukleyen birinin deposunu yok ederdi.
foreach my $old (&list_deploys($d)) {
	unlink($old->{'file'}) if ($old->{'file'});
	unlink(&actions_path($d, $old));
	}

my $n = 0;
foreach my $r (@$recs) {
	my $dep = $r->{'dep'};
	next if (ref($dep) ne 'HASH' || !$dep->{'id'});
	# save_deploy 'dom' alanini ve dosya adini o anki domain id'siyle
	# yeniden kuruyor - yedekte domain id'si bilerek yok.
	&save_deploy($d, $dep);
	&actions_write($d, $dep, $r->{'actions'});
	$n++;
	}

&$virtual_server::second_print(&text('restore_done', $n));
return 1;
}

1;
