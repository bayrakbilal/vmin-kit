# vmkit-cloudflare - Virtualmin plugin sozlesmesi.
#
# Bu modul BILEREK bir domain "feature"i DEGILDIR: feature_setup tanimlamiyor.
# Virtualmin yalnizca feature_setup tanimlayan plugin'lere domain basina onay
# kutusu veriyor (list_feature_plugins). Cloudflare senkronu sunucu geneli bir
# is oldugu icin System Settings altinda tek bir ayar sayfasi olarak duruyor.
use strict;
use warnings;
our (%text);
our $module_name;

require 'vmkit-cloudflare-lib.pl';

# feature_name()
# Plugin listelerinde gorunen ad.
sub feature_name
{
return $text{'feat_name'};
}

# settings_links()
# System Settings bolumune baglanti ekler. @plugins icindeki her modul icin
# cagriliyor; feature olmak gerekmiyor.
sub settings_links
{
return ( { 'link'  => "/$module_name/",
	   'title' => $text{'settings_title'},
	   'icon'  => 'network',
	   'cat'   => 'setting' } );
}

1;
