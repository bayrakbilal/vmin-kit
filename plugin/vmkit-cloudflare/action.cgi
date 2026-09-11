#!/usr/bin/perl
# The action buttons in the comparison table.
# Every action works on ONE Cloudflare record and arrives with that record's
# id, not with guessable fields such as name and type.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'act_err'});

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

my ($r, $err) = &cf_find_record($d, $in{'id'});
&error($err) if ($err);

my $act = $in{'act'};
$act =~ /^(proxy|import|adopt|delete)$/ || &error($text{'act_eunknown'});

# ---- CONFIRMATION ----
# Nothing here acts straight away: the button on the comparison table only
# opens this page, and the operation runs on the second, confirmed post. The
# rule covers adopting and importing as much as deleting.
#
# Proxying is the exception: it is a click on a cloud icon, already a POST and
# undone with one more click.
if ($act ne 'proxy' && !$in{'confirm'}) {
	&ui_print_header(&virtual_server::domain_in($d),
			 $text{'conf_title'}, "", undef, 0, 0);
	print "<p>$text{'conf_'.$act}</p>\n";
	print &ui_table_start($text{'conf_record'}, "width=100%", 2);
	print &ui_table_row($text{'cmp_name'}, "<tt>".&html_escape($r->{'name'})."</tt>");
	print &ui_table_row($text{'cmp_type'}, uc($r->{'type'}));
	print &ui_table_row($text{'cmp_cf'}, "<tt>".&short_value(&cf_value($r))."</tt>");
	print &ui_table_end();
	print &ui_form_start("action.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("act", $act);
	print &ui_hidden("confirm", 1);
	# The confirm button's colour and icon come from the word the theme
	# finds in the language key (get_button_style -> string_contains):
	#   delete_ok        -> red + cross
	#   keys_import_ok   -> green + import
	#   adopt_update_ok  -> blue + refresh
	my %okkey = ( 'delete' => 'delete_ok',
		      'import' => 'keys_import_ok',
		      'adopt'  => 'adopt_update_ok' );
	print &ui_form_end([ [ $act, $text{$okkey{$act}} ] ]);
	&ui_print_footer("compare.cgi?dom=$d->{'id'}", $text{'conf_cancel'});
	exit;
	}

my $done;

# Proxied records that are NOT OURS are never touched: the typical case is a
# Cloudflare tunnel, whose content (xxx.cfargotunnel.com) is meaningless in the
# local zone and whose deletion breaks a working setup. Changing the proxy
# state is allowed on our own records only.
if ($r->{'proxied'} && $act ne 'proxy') {
	&error($text{'act_eproxied'});
	}

if ($act eq 'proxy') {
	&cf_is_ours($r) || &error($text{'act_enotours'});
	my $on = $r->{'proxied'} ? 0 : 1;
	$err = &cf_set_proxy($d, $r, $on);
	&error($err) if ($err);
	$done = $on ? $text{'act_proxyon'} : $text{'act_proxyoff'};
	}
elsif ($act eq 'import') {
	$err = &import_record($d, $r);
	&error($err) if ($err);
	$err = &cf_tag_record($d, $r);
	&error($err) if ($err);
	$done = $text{'act_imported'};
	}
elsif ($act eq 'adopt') {
	$err = &cf_tag_record($d, $r);
	&error($err) if ($err);
	$done = $text{'act_adopted'};
	}
elsif ($act eq 'delete') {
	$err = &cf_delete_record($d, $r);
	&error($err) if ($err);
	$done = $text{'act_deleted'};
	}
else {
	&error($text{'act_eunknown'});
	}

&webmin_log($act, "cloudflare", $r->{'name'},
	    { 'type' => $r->{'type'}, 'dom' => $d->{'dom'} });
&redirect("compare.cgi?dom=$d->{'id'}&msg=".&urlize($done));
