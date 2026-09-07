#!/usr/bin/perl
# Karsilastirma tablosundaki islem dugmeleri.
# Her islem TEK BIR Cloudflare kaydi uzerinde calisir ve kaydin kimligiyle
# gelir; ad/tip gibi tahmin edilebilir alanlarla degil.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'act_err'});

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

my ($r, $err) = &cf_find_record($d, $in{'id'});
&error($err) if ($err);

# Proxy'li kayitlara hicbir islem uygulanmaz: davranislari Cloudflare
# tarafindaki yapilandirmada, biz ne ice aktarabiliriz ne anlamli silebiliriz.
&error($text{'act_eproxied'}) if ($r->{'proxied'});

my $act = $in{'act'};
my $done;
if ($act eq 'import') {
	$err = &import_record($d, $r);
	&error($err) if ($err);
	$err = &cf_tag_record($d, $r);
	&error($err) if ($err);
	$done = $text{'act_imported'};
	}
elsif ($act eq 'adopt') {
	$err = &cf_tag_record($d, $r);
	&error($err) if ($err);
	$done = $text{'act_adopted'};
	}
elsif ($act eq 'delete') {
	$err = &cf_delete_record($d, $r);
	&error($err) if ($err);
	$done = $text{'act_deleted'};
	}
else {
	&error($text{'act_eunknown'});
	}

&webmin_log($act, "cloudflare", $r->{'name'},
	    { 'type' => $r->{'type'}, 'dom' => $d->{'dom'} });
&redirect("compare.cgi?dom=$d->{'id'}&msg=".&urlize($done));
