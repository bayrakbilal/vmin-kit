#!/usr/bin/perl
# The check page: every dependency of the vmkit plugins, green or red, with a
# repair button where this module can put it right.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-check-lib.pl';
&ReadParse();
&virtual_server::master_admin() || &error($text{'index_eaccess'});

&ui_print_header(undef, $text{'index_title'}, "", undef, 1, 1);

no warnings "once";
if (&indexof($module_name, @virtual_server::plugins) < 0) {
	&ui_print_endpage($text{'index_eplugin'});
	}
use warnings "once";

if ($in{'msg'}) {
	print "<p><b>",&html_escape($in{'msg'}),"</b></p>\n";
	}

# Results come from the last run; the page never runs the checks by itself,
# so opening it is cheap. The button below runs them.
my $r = &load_results();
if (!$r) {
	print "<p>$text{'index_never'}</p>\n";
	}
else {
	my $when = &make_date($r->{'time'});
	my $state = $r->{'failed'}
		? &ui_text_color(&text('index_failed', $r->{'failed'}, $r->{'total'}), 'danger')
		: &ui_text_color(&text('index_ok', $r->{'total'}), 'success');
	print "<p><b>$state</b> &nbsp; <font size=-1>$text{'index_when'}: $when</font></p>\n";
	if (!&results_current($r)) {
		print "<p>",&ui_text_color($text{'index_stale'}, 'warn'),"</p>\n";
		}
	print "<p><font size=-1><tt>",&html_escape($r->{'stamp'}),"</tt></font></p>\n";

	# Hardening rows are rendered in their own always-visible section below
	# (with where/why), so keep them out of the collapsing plugin table.
	# Failures are always listed in full. Passing checks are one line per
	# plugin unless the full list is asked for: a hundred green rows hide
	# the one red one.
	my (@rows, %passed);
	foreach my $c (sort { $a->{'ok'} <=> $b->{'ok'} ||
			      $a->{'plugin'} cmp $b->{'plugin'} } @{$r->{'checks'}}) {
		next if ($c->{'plugin'} eq 'hardening');
		if ($c->{'ok'} && !$in{'all'}) {
			$passed{$c->{'plugin'}}++;
			next;
			}
		my $fix = "";
		if (!$c->{'ok'} && $c->{'fix'}) {
			$fix = &ui_form_start("fix.cgi", "post", undef,
					      "style='display:inline-block;margin:0'").
			       &ui_hidden("id", $c->{'fix'}).
			       &ui_submit($text{'fix_update'}).
			       &ui_form_end();
			}
		push(@rows, [ $c->{'plugin'},
			      &html_escape($c->{'desc'}),
			      &ui_text_color($c->{'ok'} ? $text{'st_ok'} : $text{'st_failed'},
					     $c->{'ok'} ? 'success' : 'danger'),
			      &html_escape($c->{'detail'} || ''),
			      $fix ]);
		}
	foreach my $p (sort keys %passed) {
		push(@rows, [ $p, &text('index_passed', $passed{$p}),
			      &ui_text_color($text{'st_ok'}, 'success'), "", "" ]);
		}
	print &ui_columns_table([ $text{'col_plugin'}, $text{'col_check'},
				  $text{'col_state'}, $text{'col_detail'}, "" ],
				100, \@rows);
	# Reading only, so a plain link is fine here.
	print "<p>", ($in{'all'} ? &ui_link("index.cgi", $text{'index_summary'})
				 : &ui_link("index.cgi?all=1", $text{'index_all'})),
	      "</p>\n";

	# --- Hardening: always shown in full, with where and why --------------
	# This is the "what did vmin-kit change, and where" reference the whole
	# section exists for. State comes from the same saved run.
	my %hstate = map { $_->{'fix'} => $_->{'ok'} }
		     grep { $_->{'plugin'} eq 'hardening' } @{$r->{'checks'}};
	print &ui_subheading($text{'hard_title'});
	print "<p><font size=-1>$text{'hard_intro'}</font></p>\n";
	my @hrows;
	foreach my $m (&hardening_measures()) {
		my $fixid = 'harden_'.$m->{'id'};
		my $ok = $hstate{$fixid};
		my $act = "";
		if (!$ok) {
			$act = &ui_form_start("fix.cgi", "post", undef,
					      "style='display:inline-block;margin:0'").
			       &ui_hidden("id", $fixid).
			       &ui_submit($text{'fix_update'}).
			       &ui_form_end();
			}
		# A measure may show a live status line (fail2ban lists its
		# current values, without enforcing them).
		my $what = &html_escape($m->{'title'});
		if ($m->{'status'}) {
			my $s = eval { $m->{'status'}->() };
			$what .= "<br><font size=-1>".&html_escape($s)."</font>" if ($s);
			}
		push(@hrows, [ $what,
			       "<tt>".&html_escape($m->{'where'})."</tt>",
			       &html_escape($m->{'why'}),
			       &ui_text_color($ok ? $text{'st_ok'} : $text{'st_failed'},
					      $ok ? 'success' : 'danger'),
			       $act ]);
		}
	print &ui_columns_table([ $text{'hard_col_what'}, $text{'hard_col_where'},
				  $text{'hard_col_why'}, $text{'col_state'}, "" ],
				100, \@hrows);
	}

# Running the checks reads source and touches nothing, but it is still a POST:
# a link could be prefetched, and the result file is rewritten.
print &ui_buttons_start();
print &ui_buttons_row("run.cgi", $text{'index_run'}, $text{'index_run_desc'});
print &ui_buttons_end();

print "<p><font size=-1>$text{'index_help'}</font></p>\n";

&ui_print_footer("/virtual-server/", $text{'index_return'});
