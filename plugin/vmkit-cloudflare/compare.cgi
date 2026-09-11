#!/usr/bin/perl
# Compares the local zone with Cloudflare. IT WRITES NOTHING.
#
# The classification comes from sync_plan(): THE SAME code the sync uses, so
# what this screen says and what will happen cannot drift apart. (A second copy
# of the same logic used to live here and did drift.)
#
# The comparison works on name+type GROUPS, not on individual records: a record
# with the same name and type but a different value is ONE CONFLICT, not two
# separate rows.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

&ui_print_header(&virtual_server::domain_in($d), $text{'cmp_title'},
		 "", undef, 0, 0);

my ($plan, $err) = &sync_plan($d);
if ($err) {
	print "<p><b>$text{'cmp_eapi'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
	exit;
	}

print "<p><b>",&html_escape($in{'msg'}),"</b></p>\n" if ($in{'msg'});

my $cf = &get_cf($d);

# An action button. POST because it is a mutation: a cache or a browser
# prefetch could trigger a link, and nothing must happen without a click. It
# still does not act directly - it opens the confirmation page.
#
# THE COLOUR AND ICON COME FROM THE LANGUAGE KEY'S NAME. The theme's
# get_button_style looks the label up in %text to find which key it came from,
# then searches THE KEY NAME for a word (string_contains):
#   contains 'delete' -> red + cross icon
#   'keys_import'     -> green + import icon
#   'update'          -> blue + refresh icon
# That is why the key names are what they are; the theme adds the icon itself,
# no symbol is put in the label by hand.
#
# A link was tried and abandoned: it gives the small outlined look but cannot
# be coloured - the theme's link colours are written BY HAND per module and
# href, with no hook for a third-party module.
my $btn = sub {
	my ($id, $act, $label) = @_;
	# Each button is its own form, and a form is a block element - without
	# inline-block they would stack vertically.
	return &ui_form_start("action.cgi", "post", undef,
			      "style='display:inline-block;margin-right:6px'").
	       &ui_hidden("dom", $d->{'id'}).
	       &ui_hidden("id", $id).
	       &ui_hidden("act", $act).
	       &ui_submit($label).
	       &ui_form_end();
	};

# The proxy cell: a CLOUD ICON, not a labelled button.
#
# Labelled buttons made the rows taller; the icon takes no space and speaks the
# same language as Cloudflare's own orange/grey cloud. It also sidesteps the
# theme colouring buttons by language key - here the colour is set directly.
my $cloud = sub {
	my ($on) = @_;
	return $on ? &ui_text_color("&#9729;", 'warn')
		   : "<span style='opacity:0.45'>&#9729;</span>";
	};

# A clickable cloud: a plain <button type=submit> rather than ui_submit so its
# body can be HTML. No theme class is applied - a button look is not wanted
# here, only a clickable icon. POST, because it is a mutation.
my $cloud_btn = sub {
	my ($id, $on) = @_;
	return &ui_form_start("action.cgi", "post", undef,
			      "style='display:inline-block;margin:0'").
	       &ui_hidden("dom", $d->{'id'}).
	       &ui_hidden("id", $id).
	       &ui_hidden("act", "proxy").
	       "<button type='submit' title=\"".
	       &quote_escape($on ? $text{'proxy_on'} : $text{'proxy_off'})."\" ".
	       "style='border:0;background:none;padding:0;cursor:pointer;".
	       "font-size:1.3em;line-height:1'>".&$cloud($on)."</button>".
	       &ui_form_end();
	};

# On our records the icon is clickable; on records that are not ours (a tunnel,
# say) it only shows the state. Proxying applies to A, AAAA and CNAME only. The
# icon alone is not self-explanatory, so its meaning is always in the title.
my $proxy_cell = sub {
	my ($e) = @_;
	return "-" if ($e->{'type'} !~ /^(A|AAAA|CNAME)$/);
	my @cr = @{$e->{'crecs'}};
	if (!@cr) {
		# The record does not exist yet: the state it would get on
		# creation, shown faded.
		my $on = $cf->{'proxy'} &&
			 !&never_proxy(&record_label($d, $e->{'name'})) ? 1 : 0;
		return "<span style='opacity:0.5' title=\"".
		       &quote_escape(&text('proxy_new',
				$on ? $text{'proxy_on'} : $text{'proxy_off'})).
		       "\">".&$cloud($on)."</span>";
		}
	return join(" ", map {
		my $on = $_->{'proxied'} ? 1 : 0;
		&cf_is_ours($_)
			? &$cloud_btn($_->{'id'}, $on)
			: "<span title=\"".
			  &quote_escape($on ? $text{'proxy_on'} : $text{'proxy_off'}).
			  "\">".&$cloud($on)."</span>";
		} @cr);
	};

my ($lcount, $ccount) = (0, 0);
foreach my $e (@$plan) {
	$lcount += scalar(@{$e->{'lvals'}});
	$ccount += scalar(@{$e->{'crecs'}});
	}
print "<p>",&text('cmp_counts', $lcount, $ccount),"</p>\n";

my (@insync, @outside);
foreach my $e (@$plan) {
	my @lv = @{$e->{'lvals'}};
	my @cv = @{$e->{'cvals'}};
	my @cr = @{$e->{'crecs'}};
	my $lcol = @lv ? "<tt>".&short_value(join(", ", sort @lv))."</tt>" : "-";
	my $ccol = @cv ? "<tt>".&short_value(join(", ", sort @cv))."</tt>" : "-";

	# The status TEXT and the COLOUR TYPE are kept apart; the colour is
	# applied at the end, TOGETHER with the warning icon, so the icon is not
	# left outside the coloured text and colourless.
	#
	# Valid types: success / info / warn / danger. Any other name and
	# ui_text_color silently applies no colour.
	my ($state, $type, $note, $out, $acts) = ("", "", "", 0, "");
	my $op = $e->{'op'};
	if    ($op eq 'create') { ($state, $type) = ($text{'st_willcreate'}, 'success'); }
	elsif ($op eq 'delete') { ($state, $type) = ($text{'st_willdelete'}, 'danger'); }
	elsif ($op eq 'update') { ($state, $type) = ($text{'st_willupdate'}, 'warn'); }
	elsif ($op eq 'adopt')  { ($state, $type) = ($text{'st_willadopt'}, 'info'); }
	# Rows that are in sync are green too: they are most of the table, and
	# left colourless the "all in place" message did not register.
	elsif ($op eq 'none')   { ($state, $type) = ($text{'st_insync'}, 'success'); }
	else {
		# skip: out of scope. The reason is in the 'why' field.
		$out = 1;
		my @links;
		if ($e->{'why'} eq 'cnameclash') {
			($state, $type, $note) =
				($text{'st_blocked'}, 'danger', $text{'st_cnameclash'});
			push(@links, &$btn($e->{'blocker'}->{'id'}, 'delete',
					   $text{'cf_delete_cname'}));
			}
		elsif ($e->{'why'} eq 'notours') {
			($state, $type) = ($text{'st_notours'}, 'info');
			# NO actions on proxied records: the typical case is a
			# Cloudflare tunnel, whose content is meaningless in the
			# local zone and whose deletion breaks a working setup.
			foreach my $r (@cr) {
				next if ($r->{'proxied'});
				push(@links,
				     &$btn($r->{'id'}, 'import', $text{'keys_import'}),
				     &$btn($r->{'id'}, 'delete', $text{'cf_delete'}));
				}
			}
		else {
			($state, $type, $note) =
				($text{'st_conflict'}, 'warn', $text{'st_conflict_note'});
			foreach my $r (@cr) {
				next if ($r->{'proxied'});
				push(@links,
				     &$btn($r->{'id'}, 'adopt', $text{'adopt_update'}),
				     &$btn($r->{'id'}, 'import', $text{'keys_import'}));
				}
			}
		$acts = join("", @links);
		# Rows without actions keep the same height: an invisible,
		# disabled button holds the space. Otherwise proxied rows sit
		# lower than the rest and the table looks ragged.
		$acts = "<span style='visibility:hidden'>".
			&ui_submit($text{'cf_delete'}, undef, 1)."</span>"
			if (!@links);
		# Say in the note why no action is offered.
		$note = $text{'st_proxied2'} if (!@links && $e->{'proxied'});
		}

	# The note lives in a warning icon at the start of the status rather than
	# in a column of its own: the first table has no notes at all, and in the
	# second long text bloated the rows.
	#
	# The icon is coloured INSIDE the text; the tooltip sits on the wrapper.
	my $scell = $note ? "&#9888; ".$state : $state;
	$scell = &ui_text_color($scell, $type) if ($type);
	$scell = "<span title=\"".&quote_escape($note)."\">".$scell."</span>"
		if ($note);
	my $row = [ $e->{'name'}, $e->{'type'}, $lcol, $ccol, &$proxy_cell($e), $scell ];
	if ($out) { push(@outside, [ @$row, $acts ]); }
	else      { push(@insync,  $row); }
	}

my @heads = ( $text{'cmp_name'}, $text{'cmp_type'}, $text{'cmp_local'},
	      $text{'cmp_cf'}, $text{'cmp_proxy'}, $text{'cmp_state'} );

print &ui_subheading($text{'cmp_tbl_sync'});
if (@insync) {
	print &ui_columns_table(\@heads, 100, \@insync);
	}
else {
	print "<p><i>$text{'cmp_none_sync'}</i></p>\n";
	}

print &ui_subheading($text{'cmp_tbl_outside'});
if (@outside) {
	print "<p>$text{'cmp_outside_intro'}</p>\n";
	print &ui_columns_table([ @heads, $text{'cmp_actions'} ], 100, \@outside);
	}
else {
	print "<p><i>$text{'cmp_none_outside'}</i></p>\n";
	}

print "<p><font size=-1>$text{'cmp_readonly'} $text{'cmp_proxy_help'}</font></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
