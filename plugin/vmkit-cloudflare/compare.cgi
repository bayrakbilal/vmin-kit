#!/usr/bin/perl
# Yerel zone ile Cloudflare'i karsilastirir. HICBIR SEY YAZMAZ.
#
# Karsilastirma ad+tip GRUBU uzerinden yapilir, tek tek kayit uzerinden degil:
# ayni ad ve tipte degeri farkli bir kayit, iki ayri satir degil TEK BIR
# CAKISMADIR. Deger anahtarin parcasi olsaydi bunu goremezdik.
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

# ---- gruplama ----
my (%lg, %cg, %cfcname);
foreach my $r (@loc) {
	push(@{$lg{lc($r->{'name'})."|".$r->{'type'}}},
	     &norm_value($r->{'type'}, $r->{'value'}));
	}
foreach my $r (@$cfrecs) {
	push(@{$cg{lc($r->{'name'})."|".uc($r->{'type'})}}, $r);
	# Cloudflare bir adda CNAME tutarken ayni ada baska tipte kayit kabul
	# etmez (CNAME tek basina durmali).
	$cfcname{lc($r->{'name'})} = 1 if (uc($r->{'type'}) eq 'CNAME');
	}

my %allk = map { $_ => 1 } (keys %lg, keys %cg);
my (@insync, @outside);

foreach my $k (sort keys %allk) {
	my ($n, $t) = split(/\|/, $k, 2);
	my @lv = @{$lg{$k} || [ ]};
	my @cr = @{$cg{$k} || [ ]};
	my @cv = map { &cf_value($_) } @cr;
	my $ours    = @cr && !(grep { !&cf_is_ours($_) } @cr);
	my $proxied = (grep { $_->{'proxied'} } @cr) ? 1 : 0;
	my $same    = join("\n", sort @lv) eq join("\n", sort @cv);

	my $lcol = @lv ? "<tt>".&short_value(join(", ", sort @lv))."</tt>" : "-";
	my $ccol = @cv ? "<tt>".&short_value(join(", ", sort @cv))."</tt>" : "-";

	my ($state, $note, $out);
	if ($proxied) {
		# Davranisi Cloudflare tarafinda; ne ice aktarilir ne yonetilir.
		($state, $note, $out) = ($text{'st_proxied2'}, "", 1);
		}
	elsif (@lv && !@cr) {
		if ($t ne 'CNAME' && $cfcname{$n}) {
			($state, $note, $out) =
				($text{'st_blocked'}, $text{'st_cnameclash'}, 1);
			}
		else {
			($state, $note, $out) = ($text{'st_willcreate'}, "", 0);
			}
		}
	elsif (!@lv && @cr) {
		($state, $note, $out) = $ours
			? ($text{'st_willdelete'}, "", 0)
			: ($text{'st_notours'}, "", 1);
		}
	elsif ($same) {
		($state, $note, $out) = $ours
			? ($text{'st_insync'}, "", 0)
			: ($text{'st_willadopt'}, "", 0);
		}
	else {
		($state, $note, $out) = $ours
			? ($text{'st_willupdate'}, "", 0)
			: ($text{'st_conflict'}, $text{'st_conflict_note'}, 1);
		}

	my $row = [ $n, $t, $lcol, $ccol, $state, $note ];
	if ($out) { push(@outside, $row); } else { push(@insync, $row); }
	}

my @heads = ( $text{'cmp_name'}, $text{'cmp_type'}, $text{'cmp_local'},
	      $text{'cmp_cf'}, $text{'cmp_state'}, $text{'cmp_note'} );

print &ui_subheading($text{'cmp_tbl_sync'});
if (@insync) {
	print &ui_columns_table(\@heads, 100, \@insync);
	}
else {
	print "<p><i>$text{'cmp_none_sync'}</i></p>\n";
	}

print &ui_subheading($text{'cmp_tbl_outside'});
if (@outside) {
	print "<p>$text{'cmp_outside_intro'}</p>\n";
	print &ui_columns_table(\@heads, 100, \@outside);
	}
else {
	print "<p><i>$text{'cmp_none_outside'}</i></p>\n";
	}

print "<p><font size=-1>$text{'cmp_readonly'}</font></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
