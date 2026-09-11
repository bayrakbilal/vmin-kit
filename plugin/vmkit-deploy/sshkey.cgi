#!/usr/bin/perl
# Generates the domain's SSH key and shows the public half.
#
# The key is per domain and in the standard place (~/.ssh/id_ed25519). Its
# public half is added to the ACCOUNT on GitHub/Gitea, so every private
# repository that account can reach works for this domain.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-deploy'} || &error(&text('index_eoff', $d->{'dom'}));

&ui_print_header(&virtual_server::domain_in($d), $text{'key_title'},
		 "", undef, 0, 0);

my $back = "index.cgi?dom=$d->{'id'}";
$back = "edit_deploy.cgi?dom=$d->{'id'}&new=$in{'new'}&id=$in{'id'}&repo=".
	&urlize($in{'repo'})
	if ($in{'repo'});

my $err = &ensure_domain_key($d);
if ($err) {
	print "<p><b>$text{'key_efail'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	&ui_print_footer($back, $text{'key_return'});
	exit;
	}

my $pub = &domain_key_pub($d);

print "<p>",&text('key_intro', "<tt>$d->{'dom'}</tt>"),"</p>\n";
print "<p><b>$text{'key_howto'}</b></p>\n";
print "<ul>\n";
print "<li>$text{'key_howto_github'}</li>\n";
print "<li>$text{'key_howto_gitea'}</li>\n";
print "</ul>\n";
print "<p><font size=-1>$text{'key_note_deploykey'}</font></p>\n";

print &ui_table_start($text{'key_pubheader'}, "width=100%", 2);
print &ui_table_row(undef,
	&ui_textarea("pub", $pub, 3, 90, "off", 0, "readonly"), 2);
print &ui_table_end();

if ($in{'repo'}) {
	print "<p>",&ui_link($back, $text{'key_recheck'}),"</p>\n";
	}

&ui_print_footer($back, $text{'key_return'});
