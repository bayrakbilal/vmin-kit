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

if ($err) {
	print "<p><b>$text{'sync_failed'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	}
else {
	print "<p><b>", $ok ? $text{'sync_ok'} : $text{'sync_partial'},
	      "</b></p>\n";
	}

&webmin_log("sync", "cloudflare", $d->{'dom'},
	    { 'status' => $err ? "error" : ($ok ? "ok" : "partial") });

print "<p>",&ui_link("compare.cgi?dom=$d->{'id'}", $text{'index_compare'}),
      "</p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
