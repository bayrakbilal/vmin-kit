#!/usr/bin/perl
# Deployment ekleme / duzenleme.
#
# Iki asamali: once repo adresi girilir ve "Kontrol et" ile uzak repo
# sorgulanir. Ulasilabiliyorsa dallar listeden secilir, ulasilamiyorsa git'in
# hatasi gosterilir ve kayit yapilmaz - calismayan bir repo hic eklenmesin.
use strict;
use warnings;
our (%text, %in, %config, $module_name);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});

my $dep;
if ($in{'new'}) {
	$dep = { 'branch' => '',
		 'target' => 'public_html',
		 'mode'   => 'manual' };
	}
else {
	$dep = &get_deploy($d, $in{'id'});
	$dep || &error($text{'edit_egone'});
	}

# Kontrol sonrasi forma geri donerken kullanicinin girdiklerini koru.
foreach my $f ('name', 'repo', 'branch', 'target', 'mode') {
	$dep->{$f} = $in{$f} if (defined($in{$f}) && $in{$f} ne '');
	}

&ui_print_header(&virtual_server::domain_in($d),
		 $in{'new'} ? $text{'edit_title_new'} : $text{'edit_title'},
		 "", undef, 0, 0);

# Repo adresi varsa dallari sorgula (klonlamaz, yalnizca ls-remote).
my ($defbranch, $branches, $rerr);
if ($dep->{'repo'}) {
	($defbranch, $branches, $rerr) = &remote_branches($d, $dep->{'repo'});
	$dep->{'branch'} ||= $defbranch;
	}

# ---- 1. asama: repo adresi ----
print &ui_form_start("edit_deploy.cgi", "post");
print &ui_hidden("dom", $d->{'id'});
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $dep->{'id'});
foreach my $f ('name', 'target', 'mode') {
	print &ui_hidden($f, $dep->{$f});
	}
print &ui_table_start($text{'edit_repo_header'}, "width=100%", 2);
print &ui_table_row($text{'edit_repo'},
	&ui_textbox("repo", $dep->{'repo'}, 60)."<br>".
	"<font size=-1>$text{'edit_repo_help'}</font>");
print &ui_table_end();
print &ui_form_end([ [ undef, $text{'edit_check'} ] ]);

if ($rerr) {
	print "<p><b>$text{'edit_echeck'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($rerr),"</pre>\n";
	print "<p><font size=-1>$text{'edit_echeck_help'}</font></p>\n";
	# Ozel repo ise domainin SSH anahtari GitHub/Gitea HESABINA eklenmeli.
	print "<p>",&ui_link("sshkey.cgi?dom=$d->{'id'}&new=$in{'new'}&id=$in{'id'}&repo=".
			     &urlize($dep->{'repo'}), $text{'edit_showkey'}),
	      "</p>\n";
	}

# ---- web kancasi ----
# Kaydedilmis her deployment'in adresi VAR ve burada her zaman gorunur:
# repo o an ulasilamiyor diye (2. asama acilmasa bile) kaybolmamali.
#
# UUID'yi burada, gerektiginde uretiyoruz: bu alan sonradan eklendi ve eski
# kayitlarda yok. Kullaniciyi "adresin cikmasi icin bir kez kaydet" gibi bir
# adima zorlamak yerine ilk goruntulemede uretilip saklaniyor.
if (!$in{'new'} && $dep->{'id'}) {
	if (!$dep->{'uuid'}) {
		$dep->{'uuid'} = &new_uuid();
		&save_deploy($d, $dep);
		}
	print "<hr>\n";
	print &ui_table_start($text{'edit_hook'}, "width=100%", 2);
	print &ui_table_row($text{'edit_hook_url'},
		"<tt>".&html_escape(&hook_url($dep) || '')."</tt>".
		"<br><font size=-1>$text{'edit_hook_help'}</font>".
		(&hook_path_registered() ? "" :
			"<br><font size=-1 color=#cc0000>".
			$text{'edit_hook_notready'}."</font>"));
	print &ui_table_end();
	# Yeniden uretme AYRI bir form: kaydet dugmesine basmadan da
	# calismali ve yanlislikla tiklanan bir kutu olmamali.
	print &ui_form_start("hook_regen.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("id", $dep->{'id'});
	print &ui_submit($text{'edit_hook_regen'});
	print &ui_form_end();
	}

# ---- 2. asama: repo dogrulandiysa gerisi ----
if ($branches) {
	print "<hr>\n";
	print &ui_form_start("save_deploy.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("new", $in{'new'});
	print &ui_hidden("id", $dep->{'id'});
	print &ui_hidden("repo", $dep->{'repo'});
	print &ui_table_start($text{'edit_header'}, "width=100%", 2);

	print &ui_table_row($text{'edit_name'},
		&ui_textbox("name", $dep->{'name'}, 30));

	print &ui_table_row($text{'edit_branch'},
		&ui_select("branch", $dep->{'branch'}, $branches, 1, 0, 0).
		($defbranch ? "<br><font size=-1>".
			      &text('edit_branch_default', $defbranch).
			      "</font>" : ""));

	# Sabit onek belge kokune kadar; kullanicidan yalnizca onun altindaki
	# klasor isteniyor. Bos birakilirsa kokun kendisine deploy edilir.
	print &ui_table_row($text{'edit_target'},
		"<tt>".&deploy_root($d)."/</tt> ".
		&ui_textbox("target", &target_sub($d, $dep->{'target'}), 25).
		"<br><font size=-1>$text{'edit_target_help'}</font>");

	# Mod, CEKME SONRASI ne olacagini belirliyor: otomatikte hemen dagitir,
	# manuelde bekler ve dagitimi sen baslatirsin.
	print &ui_table_row($text{'edit_mode'},
		&ui_radio("mode", $dep->{'mode'} || 'manual',
			  [ [ "manual", $text{'mode_manual_desc'} ],
			    [ "auto",   $text{'mode_auto_desc'} ] ]).
		"<br><font size=-1>$text{'edit_mode_help'}</font>");

	# Dagitim sonrasi komutlar. Sablon ya da hazir liste YOK: ne yazarsan o
	# calisir. Hedef klasorde, domainin kendi yetkileriyle, ilk hatada durur.
	print &ui_table_row($text{'edit_actions'},
		&ui_checkbox("actions_on", 1, $text{'edit_actions_on'},
			     $dep->{'actions_on'} ? 1 : 0)."<br>".
		&ui_textarea("actions", &actions_read($d, $dep), 6, 70)."<br>".
		"<font size=-1>".
		&text('edit_actions_help',
		      "<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>").
		"</font>");

	print &ui_table_end();
	print &ui_form_end($in{'new'} ? [ [ undef, $text{'create'} ] ]
				      : [ [ undef, $text{'save'} ],
					  [ "delete", $text{'delete'} ] ]);
	}
elsif (!$rerr && !$dep->{'repo'}) {
	print "<p><i>$text{'edit_needcheck'}</i></p>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
