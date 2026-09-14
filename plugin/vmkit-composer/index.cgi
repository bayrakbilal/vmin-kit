#!/usr/bin/perl
# A domain's composer projects.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-composer-lib.pl';
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

if (!&composer_command()) {
	&ui_print_endpage($text{'feat_echeck'});
	}

if (!$d) {
	my @doms = grep { $_->{$module_name} && &can_edit_domain($_) }
			&virtual_server::list_domains();
	@doms || &ui_print_endpage($text{'index_edoms'});
	print "<p>$text{'index_pickdom'}</p>\n";
	print &ui_columns_start([ $text{'index_dom'} ]);
	foreach my $dd (@doms) {
		print &ui_columns_row([
			&ui_link("index.cgi?dom=$dd->{'id'}", $dd->{'dom'}) ]);
		}
	print &ui_columns_end();
	&ui_print_footer("/", $text{'index'});
	exit;
	}

if (!$d->{$module_name}) {
	&ui_print_endpage(&text('index_eoff', $d->{'dom'}));
	}

my @projects = &list_projects($d);
if (@projects) {
	my @table;
	foreach my $p (@projects) {
		# The actions are ui_submit, that is, small forms. Two reasons:
		#
		# 1) SAFETY. A link means GET, and a cache or a browser prefetch
		#    could trigger the command without a click. A POST button
		#    only runs when it is pressed deliberately - which is why no
		#    confirmation page is needed.
		# 2) APPEARANCE. The colour and icon rule (get_button_style)
		#    only applies on the ui_submit path; ui_link_button emits a
		#    real <button> but without colour or icon and smaller.
		#    Buttons on one row must come from the same component or
		#    their sizes do not match - which is why packages.cgi is
		#    called by POST even though it only reads.
		#
		# The colours come from the language key's NAME:
		#   act_install -> green + package icon
		#   act_update  -> blue + refresh icon
		#   act_dump    -> no matching rule, stays plain
		#
		# THE FIELD MAY NOT BE CALLED 'action'. HTMLFormElement is
		# declared [LegacyOverrideBuiltIns], so a field's name shadows
		# the form's OWN property: with name="action", form.action is
		# that <input> rather than the URL. The theme decides whether to
		# stream from exactly there
		#     e.target.action && unbuffered_header_processor_allow(...)
		# and a DOM element fails the rule, dropping back to pjax: no
		# streaming, the page arrives in one lump at the end. The same
		# trap applies to 'target' (the theme reads e.target.target);
		# 'id' and 'name' are not read today but are the same class.
		my $btn = sub {
			my ($cgi, $action, $label) = @_;
			return &ui_form_start($cgi, "post", undef,
					      "style='display:inline-block;margin-right:6px'").
			       &ui_hidden("dom", $d->{'id'}).
			       &ui_hidden("dir", $p->{'dir'}).
			       ($action ? &ui_hidden("act", $action) : "").
			       &ui_submit($label).
			       &ui_form_end();
			};
		push(@table, [
			"<tt>".&html_escape($p->{'dir'})."</tt>",
			$p->{'ver'} ? "PHP ".$p->{'ver'} : $text{'php_default'},
			&$btn("run_progressive.cgi", "install",
			      $text{'act_install'}).
			&$btn("run_progressive.cgi", "update",
			      $text{'act_update'}).
			&$btn("run_progressive.cgi", "dump-autoload",
			      $text{'act_dump'}).
			&$btn("packages.cgi", undef, $text{'act_packages'}),
			]);
		}
	print &ui_columns_table([ $text{'col_dir'}, $text{'col_php'}, "" ],
				100, \@table);
	}
else {
	print "<p><i>",&text('index_none', $d->{'home'}),"</i></p>\n";
	}

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
