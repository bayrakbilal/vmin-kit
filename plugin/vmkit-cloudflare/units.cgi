#!/usr/bin/perl
# Otomatik senkron birimlerini yeniden kur ve baslat.
# Dosyalar zorla yeniden yazilir (force): bozulmus ya da elle degistirilmis
# bir birim dosyasi da bu dugmeyle duzelsin.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'svc_err'});

# Sistem servisi: yalnizca sunucu yoneticisi. Domain sahibinin kendi
# sayfasindan sistem birimlerini yeniden baslatmasini istemiyoruz.
&virtual_server::master_admin() || &error($text{'svc_eaccess'});

my ($done, $err) = &ensure_sync_units(1);
&error($err) if ($err);

&webmin_log("units", "cloudflare", undef, { 'done' => join(", ", @$done) });

my @args = ( "msg=".&urlize($text{'svc_repaired'}) );
push(@args, "dom=".&urlize($in{'dom'})) if ($in{'dom'});
&redirect("index.cgi?".join("&", @args));
