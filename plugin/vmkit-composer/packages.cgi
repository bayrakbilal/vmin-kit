#!/usr/bin/perl
# The composer packages installed in a project, and which can be updated.
# READ ONLY: runs 'composer show', installs nothing.
use strict;
use warnings;
our (%text, %in);

require './vmkit-composer-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-composer'} || &error(&text('index_eoff', $d->{'dom'}));

# A directory arriving from a link is not trusted: it has to be one of the
# projects the scan found.
my $p = &valid_project($d, $in{'dir'});
$p || &error($text{'run_edir'});

&ui_print_header(&virtual_server::domain_in($d),
		 &text('pkg_title', $p->{'dir'}), "", undef, 0, 0);

my ($pkgs, $err) = &composer_packages($d, $p);
if ($err) {
	print "<p><b>$text{'pkg_efail'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	}
elsif (!@$pkgs) {
	print "<p><i>$text{'pkg_none'}</i></p>\n";
	}
else {
	# Updatable ones first: however long the list, what needs attention is
	# visible at a glance.
	my @sorted = sort {
		($a->{'latest-status'} eq 'up-to-date' ? 1 : 0) <=>
		($b->{'latest-status'} eq 'up-to-date' ? 1 : 0) ||
		lc($a->{'name'}) cmp lc($b->{'name'})
		} @$pkgs;

	my ($old, @table) = (0);
	foreach my $pk (@sorted) {
		my $st = $pk->{'latest-status'} || '';
		my $cell;
		if ($st eq 'up-to-date') {
			$cell = &ui_text_color($text{'pkg_uptodate'}, 'success');
			}
		elsif ($st eq 'semver-safe-update') {
			$cell = &ui_text_color($text{'pkg_safe'}, 'warn');
			$old++;
			}
		elsif ($st eq 'update-possible') {
			$cell = &ui_text_color($text{'pkg_major'}, 'danger');
			$old++;
			}
		else {
			$cell = "-";
			}
		push(@table, [
			"<tt>".&html_escape($pk->{'name'})."</tt>",
			&html_escape($pk->{'version'}),
			&html_escape($pk->{'latest'} || '-'),
			$cell,
			&html_escape($pk->{'description'} || ''),
			]);
		}
	print "<p>",&text('pkg_counts', scalar(@$pkgs), $old),"</p>\n";
	print &ui_columns_table([ $text{'pkg_name'}, $text{'pkg_version'},
				  $text{'pkg_latest'}, $text{'pkg_status'},
				  $text{'pkg_desc'} ], 100, \@table);
	print "<p><font size=-1>$text{'pkg_note'}</font></p>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'run_return'});
