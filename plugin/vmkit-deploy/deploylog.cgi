#!/usr/bin/perl
# Son deploy kaydini gosterir.
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

&ui_print_header(&virtual_server::domain_in($d), $text{'log_title'},
		 "", undef, 0, 0);

# Kayit dosyasi HAM cikti: ne tarih basligi ne durum satiri iceriyor.
# Ikisi de deployment kaydinda duruyor ve asagida oradan basiliyor - ayni
# bilgiyi dosyaya da yazsaydik bicimlendirmesi HTML'e karisirdi (make_date'i
# tema EZIYOR ve <span ...> donduruyor; log sayfasinda o etiket duz metin
# olarak gorunuyordu).
#
# Duzen calisan sayfayla ayni: once cikti, sonra sonuc satiri.
my $log = &deploy_log_read($d, $dep);
if (!defined($log) || $log !~ /\S/) {
	print "<p><i>$text{'deploy_nolog'}</i></p>\n";
	}
else {
	print "<pre style='white-space:pre-wrap; margin-bottom:16px'>",
	      &html_escape($log), "</pre>\n";
	}
if ($dep->{'last_time'}) {
	print "<p><b>",
	      &ui_text_color($dep->{'last_status'} eq 'ok' ? $text{'st_ok'}
							   : $text{'st_failed'},
			     $dep->{'last_status'} eq 'ok' ? 'success' : 'danger'),
	      "</b> - ", &op_label($dep->{'last_op'} || 'both'),
	      " - ", &make_date($dep->{'last_time'}), "</p>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
