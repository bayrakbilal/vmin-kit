#!/usr/bin/perl
# Bir deployment'i calistirir ve ciktisini normal bir sayfada gosterir.
# Webmin'in ui-lib'inde modal/popup destegi yok; kendi penceremizi uydurmak
# yerine temanin standart sayfa duzenini kullaniyoruz.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-deploy'} || &error(&text('index_eoff', $d->{'dom'}));

my $dep = &get_deploy($d, $in{'id'});
$dep || &error($text{'edit_egone'});

# Tamponsuz baslik: cikti islem surerken satir satir ekrana dusuyor.
&ui_print_unbuffered_header(&virtual_server::domain_in($d),
			    $text{'deploy_title'}, "", undef, 0, 0);

print "<pre style='white-space:pre-wrap'>";
my ($ok, $out) = &run_deploy($d, $dep);
print "</pre>\n";

&webmin_log("deploy", "deploy", $dep->{'name'} || $dep->{'id'},
	    { 'status' => $ok ? "ok" : "failed" });
print "<p><b>", $ok ? $text{'deploy_ok'} : $text{'deploy_failed'}, "</b></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
