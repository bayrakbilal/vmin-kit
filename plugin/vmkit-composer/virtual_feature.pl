# vmkit-composer - Virtualmin feature sozlesmesi.
# vmkit-deploy ile ayni kalip: domain basina ozellik, domain menusunde ikon,
# domain sahibi kendi domainini yonetir.
use strict;
use warnings;
our (%text, %config);
our $module_name;

require 'vmkit-composer-lib.pl';

sub feature_name
{
return $text{'feat_name'};
}

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
# composer kurulu degilse ozellik hic acilamasin.
sub feature_check
{
return &composer_command() ? undef : $text{'feat_echeck'};
}

sub feature_suitable
{
my ($parentdom, $aliasdom, $subdom) = @_;
return $aliasdom ? 0 : 1;
}

# feature_setup(&domain)
# Saklanacak bir yapilandirma yok: projeler her acilista diskten bulunuyor.
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'setup_start'});
&$virtual_server::second_print($virtual_server::text{'setup_done'});
}

sub feature_modify
{
}

# feature_delete(&domain)
# Silinecek bir sey yok; vendor klasorlerine kesinlikle dokunmuyoruz.
sub feature_delete
{
my ($d) = @_;
&$virtual_server::first_print($text{'delete_start'});
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

sub feature_links
{
my ($d) = @_;
return ( { 'mod'   => $module_name,
	   'desc'  => $text{'links_link'},
	   'page'  => 'index.cgi?dom='.$d->{'id'},
	   'cat'   => 'server',
	   'order' => 555 } );
}

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
