#!/usr/bin/perl
# A domain's deployment list.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-deploy-lib.pl';
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

# ---- no domain chosen: list the ones this user may edit ----
if (!$d) {
	my @doms = grep { $_->{$module_name} && &can_edit_domain($_) }
			&virtual_server::list_domains();
	if (!@doms) {
		&ui_print_endpage($text{'index_edoms'});
		}
	print "<p>$text{'index_pickdom'}</p>\n";
	print &ui_columns_start([ $text{'index_dom'}, $text{'index_count'} ]);
	foreach my $dd (@doms) {
		print &ui_columns_row([
			&ui_link("index.cgi?dom=$dd->{'id'}", $dd->{'dom'}),
			scalar(&list_deploys($dd)) ]);
		}
	print &ui_columns_end();
	&ui_print_footer("/", $text{'index'});
	exit;
	}

if (!$d->{$module_name}) {
	&ui_print_endpage(&text('index_eoff', $d->{'dom'}));
	}

# Webmin's ui-lib GROWS from release to release. Calling a helper that the
# target server does not have kills the page with "Undefined subroutine" -
# ui_badge does not exist in 2.660. Decoration like colour is therefore never
# called directly: when it is missing we fall back to plain text.
sub colour
{
my ($txt, $type) = @_;
return defined(&ui_text_color) ? &ui_text_color($txt, $type) : $txt;
}

my @deps = &list_deploys($d);
if (@deps) {
	# Pulling and deploying are MUTATIONS: a POST button, not a link.
	# Clicking a link, caching it or a browser prefetch must never trigger
	# a deployment.
	# The target is 'deploy_progressive.cgi': the "_progressive.cgi" suffix
	# is the only general rule that puts a page on the theme's streaming
	# list (see the note at the top of that file). Rename it and the output
	# arrives in one lump at the end again.
	#
	# All FOUR buttons in a row use the same small POST form. The reason is
	# APPEARANCE: ui_link_button emits a real <button> but misses the
	# theme's button styling, so it came out smaller than the others.
	# commits/log only READ; arriving by POST changes nothing and keeps the
	# sizes consistent.
	my $btn = sub {
		my ($dep, $cgi, $op, $label) = @_;
		return &ui_form_start($cgi, "post", undef,
				      "style='display:inline-block;margin-right:6px'").
		       &ui_hidden("dom", $d->{'id'}).
		       &ui_hidden("id", $dep->{'id'}).
		       ($op ? &ui_hidden("op", $op) : "").
		       &ui_submit($label).
		       &ui_form_end();
		};

	my @table;
	foreach my $dep (@deps) {
		# Valid colour types: success, info, warn, danger. Any other name
		# and ui_text_color applies no colour at all, silently.
		my $last = $dep->{'last_time'}
			? &colour($dep->{'last_status'} eq 'ok'
					 ? $text{'st_ok'} : $text{'st_failed'},
					 $dep->{'last_status'} eq 'ok'
					 ? 'success' : 'danger')." - ".
			  &op_label($dep->{'last_op'} || 'both')." - ".
			  &make_date($dep->{'last_time'}).
			  # Manual or hook: the list answers "is the hook
			  # working?" without opening anything.
			  (($dep->{'last_trigger'} || '') eq 'hook'
				? " <small>(".$text{'trigger_hook'}.")</small>" : "")
			: $text{'never'};

		# The live and the pulled revision are shown separately: the
		# whole point of manual mode is seeing the "pulled but not yet
		# published" state.
		my $state;
		if (&pending($d, $dep)) {
			$state = &colour(&text('state_pending',
						      $dep->{'pulled_ref'}), 'warn').
				 ($dep->{'deployed_ref'}
					? "<br><small>".&text('state_live',
							$dep->{'deployed_ref'}).
					  "</small>"
					: "");
			}
		elsif ($dep->{'deployed_ref'}) {
			$state = &text('state_live', $dep->{'deployed_ref'});
			}
		else {
			$state = "-";
			}

		# The button labels are FIXED ("Pull" and "Deploy"). Letting the
		# pull button read "Pull and deploy" in automatic mode made rows
		# different widths, and the Mode column already says what the
		# mode does.
		#
		# No 'op' is sent: the page decides from the mode, so that
		# decision lives in one place, the same one the hook uses.
		#
		# THE LANGUAGE KEY NAME DETERMINES THE COLOUR AND ICON. The theme
		# looks the label up in %text to find the key, then searches the
		# key name for a word (get_button_style/string_contains):
		#   'update'  -> blue + refresh icon   (pull)
		#   'install' -> green + package icon  (deploy)
		#   'delete'  -> red + cross icon
		#
		# CAREFUL: a button's LABEL TEXT must be UNIQUE in the language
		# file. The theme finds the key with
		#     ($keys) = grep { $module_text{$_} eq $label } keys %module_text
		# so two keys sharing one text make 'keys' return them in a
		# different order per request and the colour comes and goes.
		my @acts = ( &$btn($dep, "deploy_progressive.cgi", '',
				   $text{'pull_update'}) );
		push(@acts, &$btn($dep, "deploy_progressive.cgi", 'deploy',
				  $text{'deploy_install'}))
			if (-d &deploy_repo_path($d, $dep));
		# The repository only exists after the first pull, so these two
		# appear from then on.
		if ($dep->{'last_time'}) {
			push(@acts,
			     &$btn($dep, "commits.cgi", '', $text{'act_commits'}),
			     &$btn($dep, "deploylog.cgi", '', $text{'act_log'}));
			}
		push(@table, [
			# Linking the name to the edit page is Webmin's pattern:
			# the row's identity is clickable, so no separate
			# "Edit" button is needed.
			&ui_link("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				 $dep->{'name'} || $dep->{'id'}),
			$dep->{'repo'},
			$dep->{'branch'},
			"<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>",
			($dep->{'mode'} || 'manual') eq 'auto' ? $text{'mode_auto'}
							       : $text{'mode_manual'},
			$state,
			$last,
			join(" ", @acts),
			]);
		}
	print &ui_columns_table([ $text{'col_name'}, $text{'col_repo'},
				  $text{'col_branch'}, $text{'col_target'},
				  $text{'col_mode'}, $text{'col_state'},
				  $text{'col_last'}, "" ],
				100, \@table);
	}
else {
	print "<p><i>$text{'index_none'}</i></p>\n";
	}

# Actions at the foot of the page: Webmin's pattern is a button with a short
# description beside it (ui_buttons_row). Both just open a page, so these are
# links rather than forms.
print &ui_buttons_start();
print &ui_buttons_row("edit_deploy.cgi", $text{'index_add'},
		      $text{'index_add_desc'},
		      [ [ "dom", $d->{'id'} ], [ "new", 1 ] ], undef, undef, "get");
print &ui_buttons_row("sshkey.cgi", $text{'index_sshkey'},
		      $text{'index_sshkey_desc'},
		      [ [ "dom", $d->{'id'} ] ], undef, undef, "get");
print &ui_buttons_end();

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
