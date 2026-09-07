#!/usr/bin/perl
# Bir domainin OTOMATIK senkronunu tek tikla ac/kapat.
# Liste ekranindaki dugme buraya gelir; ayar sayfasina girmeye gerek kalmasin.
# Token'a dokunulmaz - kapatmak yalnizca otomatik gonderimi durdurur.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'toggle_err'});

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

my $cf = &get_cf($d);
$cf->{'enabled'} = $cf->{'enabled'} ? 0 : 1;
&save_cf($d, $cf);

&webmin_log($cf->{'enabled'} ? "enable" : "disable", "cloudflare", $d->{'dom'});

# Nereden gelindiyse oraya don: liste ya da domainin kendi sayfasi.
my $msg = &text($cf->{'enabled'} ? 'toggle_on' : 'toggle_off', $d->{'dom'});
if (($in{'back'} || '') eq 'dom') {
	&redirect("index.cgi?dom=$d->{'id'}&msg=".&urlize($msg));
	}
else {
	&redirect("index.cgi?msg=".&urlize($msg));
	}
