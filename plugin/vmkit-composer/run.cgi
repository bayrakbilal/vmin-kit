#!/usr/bin/perl
# Bir projede composer komutunu calistirir ve ciktisini gosterir.
use strict;
use warnings;
our (%text, %in);

require './vmkit-composer-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-composer'} || &error(&text('index_eoff', $d->{'dom'}));

# Baglantidan gelen dizine guvenmiyoruz: taramada bulunan projelerden biri
# olmak zorunda. Aksi halde ev dizini disinda komut calistirilabilirdi.
my $p = &valid_project($d, $in{'dir'});
$p || &error($text{'run_edir'});

# Tamponsuz baslik: composer ciktisi islem surerken ekrana dusuyor.
&ui_print_unbuffered_header(&virtual_server::domain_in($d),
			    &text('run_title', $in{'action'}, $p->{'rel'}),
			    "", undef, 0, 0);

print "<pre style='white-space:pre-wrap'>";
my ($ok, $out) = &run_composer($d, $p, $in{'action'});
print "</pre>\n";
# Bos cikti kafa karistirici: komutun calisip calismadigini soyle.
print "<p><i>$text{'run_nooutput'}</i></p>\n" if ($out !~ /\S/);

&webmin_log("composer", "composer", $p->{'rel'},
	    { 'action' => $in{'action'}, 'status' => $ok ? "ok" : "failed" });
print "<p><b>", $ok ? $text{'run_ok'} : $text{'run_failed'}, "</b></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'run_return'});
