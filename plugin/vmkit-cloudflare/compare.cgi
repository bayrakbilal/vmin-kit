#!/usr/bin/perl
# Yerel zone ile Cloudflare'i yan yana gosterir. HICBIR SEY YAZMAZ.
# Amac: yazma tarafini eklemeden once eslesmenin dogrulugunu gormek ve
# hangi kayitlarin dokunulmaz oldugunu (tunel, Email Routing, elle eklenen)
# gozle dogrulamak.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

&ui_print_header(&virtual_server::domain_in($d), $text{'cmp_title'},
		 "", undef, 0, 0);

my ($cfrecs, $err) = &cf_records($d);
if ($err) {
	print "<p><b>$text{'cmp_eapi'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
	exit;
	}

my @loc = &local_records($d);
print "<p>",&text('cmp_counts', scalar(@loc), scalar(@$cfrecs)),"</p>\n";

# Anahtar: ad + tip + deger. Ayni ad/tipte birden fazla kayit olabilir
# (iki A, birden fazla MX), o yuzden deger de anahtarin parcasi.
my (%lk, %ck);
foreach my $r (@loc) {
	$lk{lc($r->{'name'})."|".$r->{'type'}."|".
	   &norm_value($r->{'type'}, $r->{'value'})} = $r;
	}
foreach my $r (@$cfrecs) {
	$ck{lc($r->{'name'})."|".uc($r->{'type'})."|".&cf_value($r)} = $r;
	}

my @table;
# Yerelde olanlar
foreach my $k (sort keys %lk) {
	my ($n, $t, $v) = split(/\|/, $k, 3);
	my $c = $ck{$k};
	my ($state, $note);
	if ($c) {
		$state = &cf_is_ours($c) ? $text{'st_synced'} : $text{'st_adopt'};
		$note  = &cf_is_ours($c) ? "" : $text{'st_adopt_note'};
		}
	else {
		$state = $text{'st_topush'};
		}
	push(@table, [ $n, $t, "<tt>".&html_escape($v)."</tt>",
		       $c ? "<tt>".&html_escape(&cf_value($c))."</tt>" : "-",
		       $state, $note || "" ]);
	}
# Yalnizca Cloudflare'de olanlar
foreach my $k (sort keys %ck) {
	next if ($lk{$k});
	my $c = $ck{$k};
	my ($n, $t, $v) = split(/\|/, $k, 3);
	my ($state, $note);
	if (&cf_is_ours($c)) {
		$state = $text{'st_todelete'};
		}
	else {
		$state = $text{'st_untouched'};
		$note  = $c->{'proxied'} ? $text{'st_proxied'} : "";
		}
	push(@table, [ $n, $t, "-", "<tt>".&html_escape($v)."</tt>",
		       $state, $note || "" ]);
	}

print &ui_columns_table(
	[ $text{'cmp_name'}, $text{'cmp_type'}, $text{'cmp_local'},
	  $text{'cmp_cf'}, $text{'cmp_state'}, $text{'cmp_note'} ],
	100, \@table);

print "<p><font size=-1>$text{'cmp_readonly'}</font></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
