# vmkit-deploy - Virtualmin feature sozlesmesi.
#
# ISKELET: yasam dongusu fonksiyonlari yerinde ve dogru sirada cagriliyor,
# ancak henuz git islemi yapilmiyor. Amac once panelde nerede nasil
# gorunecegini netlestirmek.
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
# Domainde ozellik acildiginda. ISKELET: henuz yapilacak bir sey yok;
# deployment tanimlari sonradan panelden eklenir.
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'setup_start'});
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
# ISKELET: tanimlar duruyor, sadece pasif sayiliyor.
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

1;
