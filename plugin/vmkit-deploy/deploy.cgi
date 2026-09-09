#!/usr/bin/perl
# Bir deployment'i calistirir ve ciktisini normal bir sayfada gosterir.
# Webmin'in ui-lib'inde modal/popup destegi yok; kendi penceremizi uydurmak
# yerine temanin standart sayfa duzenini kullaniyoruz.
#
# op parametresi:
#   pull    yalnizca cek (site degismez)
#   deploy  yalnizca dagit
#   yoksa   deployment'in moduna bakilir: otomatik ise cek+dagit, manuel ise
#           yalnizca cek. Webhook da parametresiz gelir, yani ayni kurala uyar.
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

# Bilinmeyen ya da eksik op: moda gore karar ver. Webhook da parametresiz
# gelecegi icin ayni kurala uyuyor - otomatikse cek+dagit, manuelse yalnizca cek.
my $op = $in{'op'} || '';
if ($op !~ /^(pull|deploy|both)$/) {
	$op = ($dep->{'mode'} || 'manual') eq 'auto' ? 'both' : 'pull';
	}

# TAMPONSUZ baslik: ciktiyi is ilerledikce gonderebilmek icin sart. Normal
# ui_print_header ile sayfa komut bitene kadar bos bekliyordu.
#
# Duzen Virtualmin'in kendi "is yapan" sayfalarindan (ornek: enable_dkim.cgi):
# ustte hicbir sey yok, cikti hemen basliyor, sonuc ve notlar en sonda.
# Sonucun ustte olmasi zaten mumkun degil - is bitmeden bilinmiyor.
&ui_print_unbuffered_header(&virtual_server::domain_in($d), &op_label($op),
			    "", undef, 0, 0);

$dep->{'last_trigger'} = 'panel';
print "<pre style='white-space:pre-wrap; margin-bottom:12px'>";
my ($ok, $out) = &deploy_run($d, $dep, $op, sub {
	print &html_escape($_[0]), "\n";
	});
print "</pre>\n";

&webmin_log($op, "deploy", $dep->{'name'} || $dep->{'id'},
	    { 'status' => $ok ? "ok" : "failed" });

print "<p><b>",
      &ui_text_color($ok ? $text{'deploy_ok'} : $text{'deploy_failed'},
		     $ok ? 'success' : 'danger'),
      "</b></p>\n";

# Cekildi ama yayinlanmadiysa bir sonraki adimi hemen onune koy: manuel modun
# butun anlami bu ara durumda.
#
# KUTU ICINDE ve acik metinle: eskiden bu dugme sayfanin dibinde, alt bilgi
# baglantisinin hemen ustunde tek basina duruyordu ve "geri don" sanilip
# yanlislikla basildi - istenmeyen bir dagitim. Bir siteyi yayina almak
# yanlislikla tiklanacak bir sey olmamali.
if ($ok && $op eq 'pull' && &pending($d, $dep)) {
	print "<div style='border:1px solid #999; padding:10px; margin:12px 0'>\n";
	print "<b>", $text{'deploy_pending'}, "</b><br>\n";
	print "<font size=-1>",
	      &text('deploy_pending_help', $dep->{'pulled_ref'} || ''),
	      "</font><br><br>\n";
	print &ui_form_start("deploy.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("id", $dep->{'id'});
	print &ui_hidden("op", "deploy");
	print &ui_submit($text{'deploy_now_install'});
	print &ui_form_end();
	print "</div>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
