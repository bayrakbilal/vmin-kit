#!/usr/bin/perl
# Deployment ekleme / duzenleme.
#
# TEK FORM. Repo adresi degistiginde dallarin yeniden okunmasi ve sayfanin
# yeniden uretilmesi gerekiyor; bu yuzden "Repoyu kontrol et" dugmesi ayni
# formu formaction ile edit_deploy.cgi'ye gonderiyor. Boylece doldurulan her
# sey oldugu gibi geri geliyor - alanlar ayri bir formdayken kontrol sonrasi
# kayboluyorlardi.
#
# Repo dogrulanmadan alanlar GIZLENMIYOR, yalnizca dal secimi devre disi
# kaliyor: gizlemek sayfanin duzenini bozuyordu ve repoya bagli olan tek alan
# zaten dal.
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

# Kontrol turundan donerken kullanicinin girdiklerini koru.
foreach my $f ('name', 'repo', 'branch', 'target', 'mode') {
	$dep->{$f} = $in{$f} if (defined($in{$f}) && $in{$f} ne '');
	}
my $actions;
if ($in{'check'}) {
	$dep->{'actions_on'} = $in{'actions_on'} ? 1 : 0;
	$actions = $in{'actions'};
	}
else {
	$actions = &actions_read($d, $dep);
	}

# Kaydedilmis her deployment'in kanca adresi olsun. UUID alani sonradan
# eklendi, eski kayitlarda yok; kullaniciyi "adres ciksin diye bir kez kaydet"
# adimina zorlamak yerine ilk goruntulemede uretiliyor.
if (!$in{'new'} && $dep->{'id'} && !$dep->{'uuid'}) {
	$dep->{'uuid'} = &new_uuid();
	&save_deploy($d, $dep);
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

if ($rerr) {
	print "<p><b>$text{'edit_echeck'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($rerr),"</pre>\n";
	# Ozel repo ise domainin SSH anahtari GitHub/Gitea HESABINA eklenmeli.
	print "<p>",&ui_link("sshkey.cgi?dom=$d->{'id'}&new=$in{'new'}&id=$in{'id'}".
			     "&repo=".&urlize($dep->{'repo'}),
			     $text{'edit_showkey'}),"</p>\n";
	}

print &ui_form_start("save_deploy.cgi", "post");
print &ui_hidden("dom", $d->{'id'});
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $dep->{'id'});
print &ui_table_start($text{'edit_header'}, "width=100%", 2);

print &ui_table_row($text{'edit_repo'},
	&ui_textbox("repo", $dep->{'repo'}, 60)."<br>".
	"<font size=-1>$text{'edit_repo_help'}</font>");

print &ui_table_row($text{'edit_name'},
	&ui_textbox("name", $dep->{'name'}, 30));

# Dal, repo okunana kadar secilemez - repoya bagli tek alan bu.
print &ui_table_row($text{'edit_branch'},
	$branches ? &ui_select("branch", $dep->{'branch'}, $branches, 1, 0, 0)
		  : &ui_select("branch", undef, [ ], 1, 0, 0, 1)." ".
		    "<font size=-1>$text{'edit_branch_check'}</font>");

print &ui_table_row($text{'edit_target'},
	"<tt>".&deploy_root($d)."/</tt> ".
	&ui_textbox("target", &target_sub($d, $dep->{'target'}), 25)."<br>".
	"<font size=-1>$text{'edit_target_help'}</font>");

print &ui_table_row($text{'edit_mode'},
	&ui_radio("mode", $dep->{'mode'} || 'manual',
		  [ [ "manual", $text{'mode_manual_desc'} ],
		    [ "auto",   $text{'mode_auto_desc'} ] ]));

print &ui_table_row($text{'edit_actions'},
	&ui_checkbox("actions_on", 1, $text{'edit_actions_on'},
		     $dep->{'actions_on'} ? 1 : 0)."<br>".
	&ui_textarea("actions", $actions, 6, 70)."<br>".
	"<font size=-1>".
	&text('edit_actions_help',
	      "<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>").
	"</font>");

# Kanca adresi bir BILGI satiri; yeniden uretmek ayri bir eylem ve sayfanin
# altinda duruyor (form icinde form olmaz).
if ($dep->{'uuid'}) {
	print &ui_table_row($text{'edit_hook'},
		"<tt>".&html_escape(&hook_url($dep) || '')."</tt><br>".
		"<font size=-1>$text{'edit_hook_help'}</font>".
		(&hook_path_registered() ? "" :
			"<br><b>$text{'edit_hook_notready'}</b>"));
	}

print &ui_table_end();

# Dugme dizisi: [ ad, etiket, sonrasina eklenecek, devre disi, ek nitelik ]
# Kaydet, repo dogrulanana kadar devre disi - dal secilmeden kayit anlamsiz.
# Kontrol dugmesi ayni formu formaction ile bu sayfaya gonderiyor.
my @buttons = ( [ undef, $in{'new'} ? $text{'create'} : $text{'save'},
		  undef, $branches ? 0 : 1 ],
		[ "check", $text{'edit_check'}, undef, 0,
		  "formaction='edit_deploy.cgi'" ] );
push(@buttons, [ "delete", $text{'delete'} ]) if (!$in{'new'});
print &ui_form_end(\@buttons);

# Kanca adresini yenilemek: ayri bir eylem, o yuzden dugme + aciklama kalibi.
if ($dep->{'uuid'}) {
	print &ui_buttons_start();
	print &ui_buttons_row("hook_regen.cgi", $text{'edit_hook_regen'},
			      $text{'edit_hook_regen_desc'},
			      [ [ "dom", $d->{'id'} ], [ "id", $dep->{'id'} ] ]);
	print &ui_buttons_end();
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
