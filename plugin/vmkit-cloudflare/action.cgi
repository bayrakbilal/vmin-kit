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

my $act = $in{'act'};
my $done;

# Proxy'li ve BIZIM OLMAYAN kayitlara dokunulmaz: tipik ornek Cloudflare
# tuneli - icerigi (xxx.cfargotunnel.com) yerel zone'da anlamsizdir ve
# silinmesi calisan bir kurulumu bozar. Proxy durumunu degistirmek ise
# yalnizca bizim kayitlarimizda serbest.
if ($r->{'proxied'} && $act ne 'proxy') {
	&error($text{'act_eproxied'});
	}

if ($act eq 'proxy') {
	&cf_is_ours($r) || &error($text{'act_enotours'});
	my $on = $r->{'proxied'} ? 0 : 1;
	$err = &cf_set_proxy($d, $r, $on);
	&error($err) if ($err);
	$done = $on ? $text{'act_proxyon'} : $text{'act_proxyoff'};
	}
elsif ($act eq 'import') {
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
