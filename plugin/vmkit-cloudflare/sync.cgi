#!/usr/bin/perl
# Elle senkron: plandaki islemleri uygular ve her adimi yazar.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

&ui_print_header(&virtual_server::domain_in($d), $text{'sync_title'},
		 "", undef, 0, 0);

print "<pre style='white-space:pre-wrap'>";
my ($ok, $err) = &run_sync($d, sub {
	print &html_escape($_[0]), "\n";
	});
print "</pre>\n";

# Sonuc satiri renkli: listedeki ve karsilastirmadaki durumlarla ayni dil.
if ($err) {
	print "<p><b>",&ui_text_color($text{'sync_failed'}, 'danger'),"</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	}
else {
	print "<p><b>",
	      &ui_text_color($ok ? $text{'sync_ok'} : $text{'sync_partial'},
			     $ok ? 'success' : 'warn'),
	      "</b></p>\n";
	}

&webmin_log("sync", "cloudflare", $d->{'dom'},
	    { 'status' => $err ? "error" : ($ok ? "ok" : "partial") });

# Gezinme govdede degil alt bilgide: karsilastirma ve ayarlar, ikisi de
# ayni bicimde.
&ui_print_footer("compare.cgi?dom=$d->{'id'}", $text{'index_compare'},
		 "index.cgi?dom=$d->{'id'}", $text{'index_return2'});
