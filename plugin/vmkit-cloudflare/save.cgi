#!/usr/bin/perl
# Cloudflare ayarlarini kaydet.
# ISKELET: deger saklaniyor, henuz API cagrisi ya da senkron yok.
use strict;
use warnings;
our (%text, %in, %config, $module_name, $module_config_directory);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'save_err'});

&virtual_server::master_admin() || &error($text{'index_eaccess'});

if ($in{'domains'}) {
	# Domain basina senkron acik/kapali
	my %on = map { $_, 1 } split(/\0/, $in{'sync'});
	foreach my $d (&virtual_server::list_domains()) {
		next if (!$d->{'dns'});
		&set_sync_enabled($d, $on{$d->{'id'}} ? 1 : 0);
		}
	}
else {
	# Token bos birakilirsa mevcut deger korunur - maskeli gosterdigimiz
	# icin kullanicinin her kaydedista yeniden yazmasini istemiyoruz.
	if ($in{'api_token'} =~ /\S/) {
		$in{'api_token'} =~ /^[A-Za-z0-9_\-]{20,}$/
			|| &error($text{'save_etoken'});
		$config{'api_token'} = $in{'api_token'};
		}
	$config{'proxy_default'} = $in{'proxy_default'} ? 1 : 0;
	&lock_file("$module_config_directory/config");
	&save_module_config();
	&unlock_file("$module_config_directory/config");
	# Token bir sirdir: yapilandirma dosyasi baskasina okutulmamali.
	chmod(0600, "$module_config_directory/config");
	}

&webmin_log("save", "cloudflare");
&redirect("");
