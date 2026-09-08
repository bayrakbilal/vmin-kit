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

my $act = $in{'action'};
$act =~ /^(install|update|dump-autoload)$/ || &error($text{'err_action'});

# ---- ONAY ----
# Buraya listeden BAGLANTIYLA geliniyor ve baglanti GET demek: onbellek ya da
# tarayicinin onceden getirmesi komutu tetikleyebilirdi. Eskiden dogrudan
# calisiyordu; 'composer update' bir sitenin butun bagimliliklarini
# degistirebilecegi icin bu kabul edilemez. Artik baglanti yalnizca bu
# sayfayi aciyor, komut asagidaki POST ile calisiyor.
if (!$in{'confirm'}) {
	&ui_print_header(&virtual_server::domain_in($d), $text{'conf_title'},
			 "", undef, 0, 0);
	print "<p>$text{'conf_'.$act}</p>\n";
	print &ui_table_start($text{'conf_project'}, "width=100%", 2);
	print &ui_table_row($text{'col_dir'},
			    "<tt>".&html_escape($p->{'dir'})."</tt>");
	print &ui_table_row($text{'col_php'},
			    $p->{'ver'} ? "PHP ".$p->{'ver'} : $text{'php_default'});
	print &ui_table_end();
	print &ui_form_start("run.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("dir", $p->{'dir'});
	print &ui_hidden("action", $act);
	print &ui_hidden("confirm", 1);
	# Dugmenin rengi ve ikonu dil anahtarinin adindan geliyor:
	# 'install' -> yesil + paket, 'update' -> mavi + yenileme.
	my %okkey = ( 'install'       => 'install_ok',
		      'update'        => 'update_ok',
		      'dump-autoload' => 'dump_install_ok' );
	print &ui_form_end([ [ "run", $text{$okkey{$act}} ] ]);
	&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'conf_cancel'});
	exit;
	}

&ui_print_header(&virtual_server::domain_in($d),
		 &text('run_title', $act, $p->{'dir'}),
		 "", undef, 0, 0);

my ($ok, $out) = &run_composer($d, $p, $act);
&webmin_log("composer", "composer", $p->{'dir'},
	    { 'action' => $act, 'status' => $ok ? "ok" : "failed" });

# Sonuc satiri renkli: diger eklentilerdeki durumlarla ayni dil.
print "<p><b>",
      &ui_text_color($ok ? $text{'run_ok'} : $text{'run_failed'},
		     $ok ? 'success' : 'danger'),
      "</b></p>\n";
print "<pre style='white-space:pre-wrap'>", &html_escape($out), "</pre>\n";
# Bos cikti kafa karistirici: komutun calisip calismadigini soyle.
print "<p><i>$text{'run_nooutput'}</i></p>\n" if ($out !~ /\S/);

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'run_return'});
