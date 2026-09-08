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

&ui_print_header(&virtual_server::domain_in($d), &op_label($op),
		 "", undef, 0, 0);

my ($ok, $out) = &deploy_run($d, $dep, $op);
&webmin_log($op, "deploy", $dep->{'name'} || $dep->{'id'},
	    { 'status' => $ok ? "ok" : "failed" });

print "<p><b>", $ok ? $text{'deploy_ok'} : $text{'deploy_failed'}, "</b></p>\n";
print "<pre style='white-space:pre-wrap'>", &html_escape($out), "</pre>\n";

# Cekildi ama yayinlanmadiysa bir sonraki adimi hemen onune koy: manuel modun
# butun anlami bu ara durumda.
if ($ok && $op eq 'pull' && &pending($d, $dep)) {
	print "<p>", $text{'deploy_pending'}, "</p>\n";
	print &ui_form_start("deploy.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("id", $dep->{'id'});
	print &ui_hidden("op", "deploy");
	print &ui_submit($text{'act_deploy'});
	print &ui_form_end();
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
