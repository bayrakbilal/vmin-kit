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
		my $u = "run.cgi?dom=$d->{'id'}&dir=".&urlize($p->{'dir'});
		# Bu dugmelerin hicbiri bir sey CALISTIRMIYOR: composer islemleri
		# run.cgi'deki onay sayfasina goturuyor, komut oradaki POST ile
		# calisiyor. Onay sayfasini acmak bir GET oldugu icin
		# ui_link_button uygun - bir sayfa acmaktan baska sey yapmiyor.
		#
		# Liste kisa oldugu icin tam boy dugme kullaniliyor, git
		# listesindeki gibi. Renk ve ikon yine dil anahtarinin adindan:
		# act_install -> yesil + paket, act_update -> mavi + yenileme.
		push(@table, [
			"<tt>".&html_escape($p->{'dir'})."</tt>",
			$p->{'ver'} ? "PHP ".$p->{'ver'} : $text{'php_default'},
			&ui_link_button("packages.cgi?dom=$d->{'id'}&dir=".
					&urlize($p->{'dir'}), $text{'act_packages'})." ".
			&ui_link_button($u."&action=install", $text{'act_install'})." ".
			&ui_link_button($u."&action=update", $text{'act_update'})." ".
			&ui_link_button($u."&action=dump-autoload", $text{'act_dump'}),
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
