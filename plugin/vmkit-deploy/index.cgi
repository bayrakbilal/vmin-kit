#!/usr/bin/perl
# Bir domainin deployment listesi.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-deploy-lib.pl';
&ReadParse();

# Hangi domain? Menuden gelirken dom=<id> ile geliyoruz.
my $d;
if ($in{'dom'}) {
	$d = &virtual_server::get_domain($in{'dom'});
	$d || &error($text{'index_edom'});
	&can_edit_domain($d) || &error($text{'index_eaccess'});
	}

&ui_print_header($d ? &virtual_server::domain_in($d) : undef,
		 $text{'index_title'}, "", undef, 1, 1);

# Plugin Virtualmin'de acik mi?
no warnings "once";
if (&indexof($module_name, @virtual_server::plugins) < 0) {
	&ui_print_endpage($text{'index_eplugin'});
	}
use warnings "once";

# Domain secilmediyse erisebildigimiz domainleri listele.
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

# Domainde ozellik kapaliysa uyar.
if (!$d->{$module_name}) {
	&ui_print_endpage(&text('index_eoff', $d->{'dom'}));
	}

my @deps = &list_deploys($d);
if (@deps) {
	my @table;
	foreach my $dep (@deps) {
		push(@table, [
			&ui_link("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				 $dep->{'name'} || $dep->{'id'}),
			$dep->{'source'} eq 'local' ? $text{'src_local'}
						    : $text{'src_remote'},
			$dep->{'source'} eq 'local' ? "-" : $dep->{'repo'},
			$dep->{'branch'},
			$dep->{'target'},
			$dep->{'mode'} eq 'auto' ? $text{'mode_auto'}
						 : $text{'mode_manual'},
			$dep->{'last_status'} || $text{'never'},
			]);
		}
	print &ui_columns_table([ $text{'col_name'}, $text{'col_source'},
				  $text{'col_repo'}, $text{'col_branch'},
				  $text{'col_target'}, $text{'col_mode'},
				  $text{'col_last'} ],
				100, \@table);
	}
else {
	print "<p><i>$text{'index_none'}</i></p>\n";
	}

print &ui_link("edit_deploy.cgi?dom=$d->{'id'}&new=1", $text{'index_add'}),
      "<br>\n";

# ISKELET uyarisi - islevsellik henuz yok.
print "<p><table border=1 cellpadding=4><tr><td bgcolor=#ffffcc>",
      "<b>$text{'index_skeleton'}</b></td></tr></table></p>\n";

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
