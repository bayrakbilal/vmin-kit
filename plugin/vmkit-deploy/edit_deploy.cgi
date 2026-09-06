#!/usr/bin/perl
# Deployment ekleme / duzenleme formu.
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
	$dep = { 'source' => 'remote',
		 'branch' => $config{'default_branch'} || 'main',
		 'target' => 'public_html',
		 'mode'   => 'manual' };
	}
else {
	$dep = &get_deploy($d, $in{'id'});
	$dep || &error($text{'edit_egone'});
	}

&ui_print_header(&virtual_server::domain_in($d),
		 $in{'new'} ? $text{'edit_title_new'} : $text{'edit_title'},
		 "", undef, 0, 0);

print &ui_form_start("save_deploy.cgi", "post");
print &ui_hidden("dom", $d->{'id'});
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $dep->{'id'});
print &ui_table_start($text{'edit_header'}, "width=100%", 2);

print &ui_table_row($text{'edit_name'},
	&ui_textbox("name", $dep->{'name'}, 30));

# Kaynak: sunucuda tuttugumuz repo mu, uzaktaki repo mu?
print &ui_table_row($text{'edit_source'},
	&ui_radio("source", $dep->{'source'},
		  [ [ "remote", $text{'src_remote_desc'} ],
		    [ "local",  $text{'src_local_desc'} ] ], 1));

print &ui_table_row($text{'edit_repo'},
	&ui_textbox("repo", $dep->{'repo'}, 50)."<br>".
	"<font size=-1>$text{'edit_repo_help'}</font>");

print &ui_table_row($text{'edit_branch'},
	&ui_textbox("branch", $dep->{'branch'}, 20));

# Hedef klasor domainin home'una gore. Iki repo ayni domainde farkli
# klasorlerde calisabilsin diye serbest birakiyoruz.
print &ui_table_row($text{'edit_target'},
	"<tt>$d->{'home'}/</tt> ".&ui_textbox("target", $dep->{'target'}, 30).
	"<br><font size=-1>$text{'edit_target_help'}</font>");

print &ui_table_row($text{'edit_mode'},
	&ui_radio("mode", $dep->{'mode'},
		  [ [ "manual", $text{'mode_manual_desc'} ],
		    [ "auto",   $text{'mode_auto_desc'} ] ], 1));

if (!$in{'new'} && $dep->{'source'} eq 'local') {
	print &ui_table_row($text{'edit_push'},
		"<tt>".&html_escape(&deploy_push_url($d, $dep))."</tt>");
	}

print &ui_table_end();
print &ui_form_end($in{'new'} ? [ [ undef, $text{'create'} ] ]
			      : [ [ undef, $text{'save'} ],
				  [ "delete", $text{'delete'} ] ]);

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
