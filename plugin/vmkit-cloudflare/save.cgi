#!/usr/bin/perl
# Bir domainin Cloudflare ayarlarini kaydet.
# Yalnizca ayar yazar; senkronu tetiklemez (onu sync.cgi ya da servis yapar).
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'save_err'});

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

my $cf = &get_cf($d);

if ($in{'forget'}) {
	delete($cf->{'token'});
	&save_cf($d, $cf);
	&webmin_log("forget", "cloudflare", $d->{'dom'});
	&redirect("index.cgi?dom=$d->{'id'}");
	exit;
	}

# Token bos birakilirsa mevcut deger korunur - maskeli gosterdigimiz icin
# her kaydedista yeniden yazilmasini istemiyoruz.
if ($in{'token'} =~ /\S/) {
	$in{'token'} =~ /^[A-Za-z0-9_\-]{20,}$/ || &error($text{'save_etoken'});
	$cf->{'token'} = $in{'token'};
	}
$cf->{'enabled'} = $in{'enabled'} ? 1 : 0;
$cf->{'proxy'} = $in{'proxy'} ? 1 : 0;
&save_cf($d, $cf);

&webmin_log("save", "cloudflare", $d->{'dom'});
&redirect("index.cgi?dom=$d->{'id'}");
