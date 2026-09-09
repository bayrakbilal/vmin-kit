#!/usr/bin/perl
# Bir projede composer komutunu calistirir ve ciktisini AKITARAK gosterir.
#
# ---------------------------------------------------------------------------
# DOSYA ADI ONEMLI: adi "_progressive.cgi" ile bitmek ZORUNDA.
#
# Tema (authentic) bir istegi akitarak mi yoksa bitmesini bekleyip tek seferde
# mi basacagina JS tarafinda karar veriyor: unbuffered_header_processor_allow()
# icinde yuzlerce satirlik SABIT bir yol listesi var (virtual-server/
# enable_dkim.cgi, package-updates/update.cgi ...). Listede olmayan her sey
# normal pjax'a giriyor, pjax da ancak yanit tamamlaninca ekrana basiyor.
#
# Listenin sonundaki iki satir ucuncu partiler icin birakilmis genel kapi:
#     n.indexOf("_progressive.cgi") > -1 || n.indexOf("_saving.cgi") > -1
#
# Tamponsuz baslik da sart (ui_print_unbuffered_header, $| = 1) ve tema ilk
# parcada icerikte bir <pre> gormek istiyor - o yuzden basliktan hemen sonra
# <pre> aciliyor.
# ---------------------------------------------------------------------------
#
# ONAY SAYFASI YOK. Vardi ve KALDIRILDI: konmasinin sebebi dugmelerin GET
# baglantisi olmasiydi - bir onbellek ya da tarayicinin onceden getirmesi
# komutu tetikleyebilirdi. Artik listedeki dort dugme de POST formu, yani
# komut ancak bilerek tiklayinca calisiyor. Git tarafinda cekme ve dagitim da
# onay istemiyor; ayni kural.
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

# Alan adi 'act', 'action' DEGIL: form icindeki name="action" formun kendi
# .action ozelligini golgeliyor ve tema akitma kararini oradan veriyor
# (bkz. index.cgi'deki uzun not).
my $act = $in{'act'};
$act =~ /^(install|update|dump-autoload)$/ || &error($text{'err_action'});

# Duzen Virtualmin'in kendi "is yapan" sayfalarindan: ustte hicbir sey yok,
# cikti hemen basliyor, sonuc en sonda. Sonucun ustte olmasi zaten mumkun
# degil - is bitmeden bilinmiyor.
&ui_print_unbuffered_header(&virtual_server::domain_in($d),
			    &text('run_title', $act, $p->{'dir'}),
			    "", undef, 0, 0);

# <pre> icinde YALNIZCA komutun ham ciktisi: terminalde ne gorunuyorsa o.
print "<pre style='white-space:pre-wrap; margin-bottom:16px'>";
my ($ok, $out) = &run_composer($d, $p, $act, sub {
	print &html_escape($_[0]), "\n";
	});
print "</pre>\n";

&webmin_log("composer", "composer", $p->{'dir'},
	    { 'action' => $act, 'status' => $ok ? "ok" : "failed" });

print "<p><b>",
      &ui_text_color($ok ? $text{'run_ok'} : $text{'run_failed'},
		     $ok ? 'success' : 'danger'),
      "</b></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'run_return'});
