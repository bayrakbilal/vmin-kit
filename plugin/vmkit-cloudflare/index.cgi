#!/usr/bin/perl
# With 'dom' given, that domain's Cloudflare settings; without it, the domain
# list.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

my $d;
if ($in{'dom'}) {
	$d = &virtual_server::get_domain($in{'dom'});
	$d || &error($text{'index_edom'});
	&can_edit_domain($d) || &error($text{'index_eaccess'});
	}

&ui_print_header($d ? &virtual_server::domain_in($d) : undef,
		 $text{'index_title'}, "", undef, 1, 1);

no warnings "once";
if (&indexof($module_name, @virtual_server::plugins) < 0) {
	&ui_print_endpage($text{'index_eplugin'});
	}
use warnings "once";

# ---- the automatic sync service -------------------------------------------
# The module looks after its own watch service: opening the page installs a
# missing unit and starts a stopped one. The state is always visible - the sync
# must not be able to stop silently.
#
# The result of an action (on/off and the like) is shown to everyone.
# ui_alert_box is one of Webmin's newer helpers and is not called directly, so
# a version that lacks it does not kill the page (as ui_badge once did).
if ($in{'msg'}) {
	my $m = &html_escape($in{'msg'});
	print defined(&ui_alert_box) ? &ui_alert_box($m, 'success')
				     : "<p><b>$m</b></p>\n";
	}

if (&virtual_server::master_admin()) {
	my $st = &sync_units_status();
	if ($st->{'systemd'} && !&sync_units_healthy($st)) {
		&ensure_sync_units();
		$st = &sync_units_status();
		}
	my $head;
	if (!$st->{'systemd'}) {
		$head = &ui_text_color($text{'svc_nosystemd'}, 'warn');
		}
	elsif ($st->{'ok'}) {
		$head = &ui_text_color("&#10004; ".$text{'svc_ok'}, 'success');
		}
	elsif ($st->{'nowatch'} && $st->{'timer'}->{'active'}) {
		# The timer is up but there is no instant trigger: the sync
		# happens, just up to 15 minutes late.
		$head = &ui_text_color("&#9888; ".$text{'svc_partial'}, 'warn');
		}
	else {
		$head = &ui_text_color("&#10008; ".$text{'svc_bad'}, 'danger');
		}
	print "<p>$head";
	if ($st->{'systemd'}) {
		print " &nbsp; <font size=-1>".$text{'svc_lastrun'}.": ".
		      &html_escape($st->{'lastrun'} || $text{'svc_never'});
		print " (".&html_escape($st->{'lastresult'}).")"
			if ($st->{'lastresult'} && $st->{'lastresult'} ne 'success');
		print "</font>";
		}
	print "</p>\n";

	# The detail table and the repair button appear only when something is
	# wrong. With everything in place one green line is enough.
	if ($st->{'systemd'} && !$st->{'ok'}) {
		my @tbl;
		foreach my $k ("path", "timer", "service") {
			my $u = $st->{$k};
			my $state = !$u->{'exists'} ? &ui_text_color($text{'svc_missing'}, 'danger') :
				    $k eq 'service' ? $text{'svc_oneshot'} :
				    $u->{'active'} ? &ui_text_color($text{'svc_running'}, 'success') :
						     &ui_text_color($text{'svc_stopped'}, 'danger');
			push(@tbl, [ "<tt>".&html_escape($u->{'name'})."</tt>",
				     $text{'svc_'.$k},
				     $state ]);
			}
		print &ui_columns_table(
			[ $text{'svc_col_unit'}, $text{'svc_col_role'},
			  $text{'svc_col_state'} ], 100, \@tbl);
		print "<p>".$text{'svc_nowatch'}."</p>\n" if ($st->{'nowatch'});
		print &ui_form_start("units.cgi", "post"),
		      ($in{'dom'} ? &ui_hidden("dom", $in{'dom'}) : ""),
		      &ui_submit($text{'svc_repair'}),
		      &ui_form_end();
		}
	}

# ---- no domain chosen: list the ones this user may edit ----
if (!$d) {
	my @doms = grep { $_->{$module_name} && &can_edit_domain($_) }
			&virtual_server::list_domains();
	if (!@doms) {
		&ui_print_endpage($text{'index_edoms'});
		}
	print "<p>$text{'index_pickdom'}</p>\n";
	my @table;
	foreach my $dd (@doms) {
		my $cf = &get_cf($dd);
		# On/off in one click: a small form per row, so this can be
		# managed from the list without opening the settings.
		my $btn = &ui_form_start("toggle.cgi", "post").
			  &ui_hidden("dom", $dd->{'id'}).
			  &ui_submit($cf->{'enabled'} ? $text{'sync_off'}
						      : $text{'sync_on'}).
			  &ui_form_end();
		push(@table, [
			&ui_link("index.cgi?dom=$dd->{'id'}", $dd->{'dom'}),
			$cf->{'token'} ? $text{'yes'} : $text{'no'},
			$cf->{'enabled'} ? &ui_text_color($text{'sync_yes'}, 'success')
					 : $text{'sync_no'},
			&zone_status($dd),
			$btn,
			]);
		}
	print &ui_columns_table(
		[ $text{'col_domain'}, $text{'col_token'}, $text{'col_auto'},
		  $text{'col_status'}, "" ],
		100, \@table);
	&ui_print_footer("/", $text{'index'});
	exit;
	}

# ---- warn when the feature is off for this domain ----
if (!$d->{$module_name}) {
	&ui_print_endpage(&text('index_eoff', $d->{'dom'}));
	}

# ---- the domain's settings ----
my $cf = &get_cf($d);

print "<p>$text{'index_intro'}</p>\n";

print &ui_form_start("save.cgi", "post");
print &ui_hidden("dom", $d->{'id'});
print &ui_table_start($text{'index_settings'}, "width=100%", 2);

# Each domain carries its own token: domains may live in different Cloudflare
# accounts, and a token is account/zone scoped.
print &ui_table_row($text{'index_token'},
	&ui_password("token", "", 50)."<br>".
	"<font size=-1>".
	($cf->{'token'} ? &text('index_token_set', &masked_token($cf->{'token'}))
			: $text{'index_token_none'}).
	"<br>$text{'index_token_help'}</font>");

# A drop-down rather than a yes/no radio: side by side, two radios do not read
# as a setting at all. The option labels also say what the setting does, so no
# second line of explanation is needed.
#
# The automatic sync switch is SEPARATE from the token: turning it off should
# not require deleting the token, and turning it on is one click.
print &ui_table_row($text{'index_enabled'},
	&ui_select("enabled", $cf->{'enabled'} ? 1 : 0,
		   [ [ 1, $text{'index_enabled_on'} ],
		     [ 0, $text{'index_enabled_off'} ] ], 1, 0, 0));

# The proxy setting KEEPS its explanation: two things are not obvious from its
# name - it only affects new records, and mail names are never proxied. Not
# knowing either one breaks mail.
print &ui_table_row($text{'index_proxy'},
	&ui_select("proxy", $cf->{'proxy'} ? 1 : 0,
		   [ [ 1, $text{'index_proxy_on'} ],
		     [ 0, $text{'index_proxy_off'} ] ], 1, 0, 0)."<br>".
	"<font size=-1>$text{'index_proxy_help'}</font>");

print &ui_table_row($text{'index_status'}, &zone_status($d));

print &ui_table_end();
# The theme colours a button from the LANGUAGE KEY'S NAME - not from the
# button's name or the label text. It is visible in the generated HTML: every
# button carries data-entry="<key>" and the theme picks the class from it.
#   delete, delete_ok -> btn-danger    (red, cross icon)
#   ...._ok           -> btn-success   (green, tick icon)
#   anything else     -> btn-default
# So even with the label "Delete token" the KEY has to be 'delete'. The action
# cannot be undone; save.cgi asks for confirmation.
print &ui_form_end([ [ undef, $text{'save'} ],
		     $cf->{'token'} ? ( [ "delete", $text{'delete'} ] ) : ( ) ]);

# Compare and Sync now: they do not belong to the settings form, they are the
# page's own actions. Webmin's pattern is a button with a description beside
# it, used here instead of two hand-written forms and an inline-block trick.
print &ui_buttons_start();
print &ui_buttons_row("compare.cgi", $text{'index_compare'},
		      $text{'index_compare_desc'},
		      [ [ "dom", $d->{'id'} ] ], undef, undef, "get");
if ($cf->{'token'}) {
	# The name ends in "_progressive.cgi": the theme streaming the output as
	# the work proceeds depends on it (see the note at the top of that file).
	# No "get" - a sync is a mutation and must go by POST.
	print &ui_buttons_row("sync_progressive.cgi", $text{'index_syncnow'},
			      $text{'index_syncnow_desc'},
			      [ [ "dom", $d->{'id'} ] ]);
	}
print &ui_buttons_end();

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
