#!/usr/bin/perl
# Deployment ekleme / duzenleme.
#
# Formun kendisi kutuphanede (print_deploy_form): "Repoyu kontrol et"
# basildiginda ayni formu save_deploy.cgi de ciziyor. Sebebi orada anlatildi.
use strict;
use warnings;
our (%text, %in, %config, $module_name);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});

my ($dep, $actions, $new) = &deploy_from_in($d);
$dep || &error($text{'edit_egone'});

# Kaydedilmis her deployment'in kanca adresi olsun. UUID alani sonradan
# eklendi, eski kayitlarda yok; kullaniciyi "adres ciksin diye bir kez kaydet"
# adimina zorlamak yerine ilk goruntulemede uretiliyor.
if (!$new && $dep->{'id'} && !$dep->{'uuid'}) {
	$dep->{'uuid'} = &new_uuid();
	&save_deploy($d, $dep);
	}

&ui_print_header(&virtual_server::domain_in($d),
		 $new ? $text{'edit_title_new'} : $text{'edit_title'},
		 "", undef, 0, 0);

&print_deploy_form($d, $dep, $actions, $new);

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
