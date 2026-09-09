#!/usr/bin/perl
# Elle senkron: plandaki islemleri uygular ve her adimi yazar.
#
# ---------------------------------------------------------------------------
# DOSYA ADI ONEMLI: adi "_progressive.cgi" ile bitmek ZORUNDA.
#
# Tema (authentic) bir istegi akitarak mi yoksa bitmesini bekleyip tek seferde
# mi basacagina JS tarafinda karar veriyor: unbuffered_header_processor_allow()
# icinde yuzlerce satirlik SABIT bir yol listesi var. Listede olmayan her sey
# pjax'a giriyor ve pjax ancak yanit tamamlaninca ekrana basiyor. Listenin
# sonunda ucuncu partiler icin genel bir kapi var:
#     n.indexOf("_progressive.cgi") > -1 || n.indexOf("_saving.cgi") > -1
#
# Tamponsuz baslik da sart ($| = 1) ve tema ilk parcada icerikte bir <pre>
# gormek istiyor - o yuzden basliktan hemen sonra <pre> aciliyor.
#
# Buraya gelen formda ALAN ADI 'action' ya da 'target' OLAMAZ: form icindeki
# bir alanin name'i formun kendi ozelligini golgeliyor ve tema kapiyi
# e.target.action uzerinden acyor. (Composer'da tam olarak bu yasandi.)
# ---------------------------------------------------------------------------
#
# Buradaki cikti bir kabuk komutunun ham ciktisi DEGIL - senkron dis komut
# calistirmiyor, adim adim Cloudflare API'sine gidiyor. O yuzden satirlari
# biz yaziyoruz; kural: her satir o an ne yapildigini soyleyen tek kisa satir
# (olusturuldu / guncellendi / silindi / sahiplenildi ya da hata).
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

&ui_print_unbuffered_header(&virtual_server::domain_in($d), $text{'sync_title'},
			    "", undef, 0, 0);

print "<pre style='white-space:pre-wrap; margin-bottom:16px'>";
my ($ok, $err) = &run_sync($d, sub {
	print &html_escape($_[0]), "\n";
	});
print "</pre>\n";

# Sonuc satiri renkli: listedeki ve karsilastirmadaki durumlarla ayni dil.
# Bu dal hicbir adima gelemeden dusen hatalar icin: plan cikarilamadi ya da
# zone bulunamadi. O durumda yukaridaki <pre> bos kaliyor, hatayi burada
# gosteriyoruz.
if ($err) {
	print "<p><b>",&ui_text_color($text{'sync_failed'}, 'danger'),"</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	}
else {
	print "<p><b>",
	      &ui_text_color($ok ? $text{'sync_ok'} : $text{'sync_partial'},
			     $ok ? 'success' : 'warn'),
	      "</b></p>\n";
	}

&webmin_log("sync", "cloudflare", $d->{'dom'},
	    { 'status' => $err ? "error" : ($ok ? "ok" : "partial") });

# Gezinme govdede degil alt bilgide: karsilastirma ve ayarlar, ikisi de
# ayni bicimde.
&ui_print_footer("compare.cgi?dom=$d->{'id'}", $text{'index_compare'},
		 "index.cgi?dom=$d->{'id'}", $text{'index_return2'});
