# vmkit-cloudflare - Virtualmin feature sozlesmesi.
#
# vmkit-deploy ile SIMETRIK: domain basina bir ozellik. Her domainin kendi
# Cloudflare API token'i vardir, cunku token hesap/zone bazlidir ve domainler
# farkli Cloudflare hesaplarinda olabilir. Global token yoktur.
#
# ISKELET: yasam dongusu yerinde, ancak henuz Cloudflare API cagrisi ve
# senkron servisi yok.
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
# ISKELET: kayit dosyasini olusturur; token panelden girilir.
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'setup_start'});
# Varsayilan, modul ayarlarindan gelir (Features and Plugins -> Configure).
&save_cf($d, { 'proxy' => $config{'default_proxy'} ? 1 : 0 });
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

1;
