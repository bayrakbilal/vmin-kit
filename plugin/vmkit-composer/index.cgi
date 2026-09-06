#!/usr/bin/perl
# Domainin composer projeleri.
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
		# Baglanti degil form POST: tema baglantilari XHR ile yukleyip
		# yanitin tamamini bekliyor, canli akis gorunmuyor.
		my $acts = "";
		foreach my $a ( [ "install",       $text{'act_install'} ],
				[ "update",        $text{'act_update'} ],
				[ "dump-autoload", $text{'act_dump'} ] ) {
			$acts .= &ui_form_start("run.cgi", "post").
				 &ui_hidden("dom", $d->{'id'}).
				 &ui_hidden("dir", $p->{'dir'}).
				 &ui_hidden("action", $a->[0]).
				 &ui_submit($a->[1]).
				 &ui_form_end()." ";
			}
		push(@table, [
			"<tt>".&html_escape($p->{'rel'})."</tt>",
			$p->{'ver'} ? "PHP ".$p->{'ver'} : $text{'php_default'},
			$acts,
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
