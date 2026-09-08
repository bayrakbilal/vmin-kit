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
		# Eylemler ui_submit ile, yani birer kucuk form. Sebep GORUNUM:
		# renk ve ikon kurali (get_button_style) yalnizca ui_submit
		# yolunda calisiyor - ui_link_button gercek bir <button> uretiyor
		# ama renksiz ve ikonsuz kaliyor. Denendi.
		#   act_install -> yesil + paket ikonu
		#   act_update  -> mavi + yenileme ikonu
		#   act_dump    -> uygun bir kural yok, duz kaliyor
		#
		# Yine de hicbiri bir sey CALISTIRMIYOR: run.cgi 'confirm'
		# gelmedikce yalnizca onay sayfasini gosteriyor.
		# Paketler sayfasi da AYNI kalipla: ayni satirdaki dugmeler ayni
		# bilesenden olmali, yoksa boylari tutmuyor. packages.cgi
		# yalnizca okuyor, POST ile gelmesi bir sey degistirmiyor.
		my $btn = sub {
			my ($cgi, $action, $label) = @_;
			return &ui_form_start($cgi, "post", undef,
					      "style='display:inline-block;margin-right:6px'").
			       &ui_hidden("dom", $d->{'id'}).
			       &ui_hidden("dir", $p->{'dir'}).
			       ($action ? &ui_hidden("action", $action) : "").
			       &ui_submit($label).
			       &ui_form_end();
			};
		push(@table, [
			"<tt>".&html_escape($p->{'dir'})."</tt>",
			$p->{'ver'} ? "PHP ".$p->{'ver'} : $text{'php_default'},
			&$btn("run.cgi", "install", $text{'act_install'}).
			&$btn("run.cgi", "update", $text{'act_update'}).
			&$btn("run.cgi", "dump-autoload", $text{'act_dump'}).
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
