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

# ---- token'i unut ----
# Rengi tema ETIKETTEKI "Delete" kelimesine bakarak veriyor (ad degil). Bu
# islem geri alinamiyor: token bir daha gosterilmiyor, Cloudflare'den
# yeniden uretmek gerekiyor. Once onay, sonra silme.
if ($in{'delete'} && !$in{'confirm'}) {
	&ui_print_header(&virtual_server::domain_in($d), $text{'forget_title'},
			 "", undef, 0, 0);
	print "<p>",&text('forget_warn', "<tt>".&html_escape($d->{'dom'})."</tt>"),
	      "</p>\n";
	print "<ul>\n";
	print "<li>$text{'forget_goes'}</li>\n";
	print "<li><b>$text{'forget_stays'}</b></li>\n";
	print "</ul>\n";
	print &ui_form_start("save.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("confirm", 1);
	print &ui_form_end([ [ "delete", $text{'forget_ok'} ] ]);
	&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'forget_cancel'});
	exit;
	}
if ($in{'delete'}) {
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
