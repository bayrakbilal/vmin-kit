#!/usr/bin/perl
# Bir domainin deployment listesi.
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

# ---- domain secilmedi: erisebildiklerimizi listele ----
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

my @deps = &list_deploys($d);
if (@deps) {
	my @table;
	foreach my $dep (@deps) {
		my $last = $dep->{'last_time'}
			? ($dep->{'last_status'} eq 'ok' ? $text{'st_ok'}
							 : $text{'st_failed'}).
			  " - ".&make_date($dep->{'last_time'})
			: $text{'never'};
		# Deploy bir BAGLANTI degil, form POST'u: tema baglantilari XHR ile
		# yukleyip yanitin tamamini bekliyor, boylece canli akis gorunmuyor.
		# Virtualmin'in akan sayfalari (domain_setup, script_install) da
		# form gonderimiyle aciliyor.
		my $dform = &ui_form_start("deploy.cgi", "post").
			    &ui_hidden("dom", $d->{'id'}).
			    &ui_hidden("id", $dep->{'id'}).
			    &ui_submit($text{'act_deploy'}).
			    &ui_form_end();
		my @links = ( &ui_link("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				       $text{'act_edit'}) );
		push(@links, &ui_link("deploylog.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				      $text{'act_log'}))
			if ($dep->{'last_time'});
		push(@table, [
			$dep->{'name'} || $dep->{'id'},
			$dep->{'repo'},
			$dep->{'branch'},
			$dep->{'target'},
			$dep->{'mode'} eq 'auto' ? $text{'mode_auto'}
						 : $text{'mode_manual'},
			$last,
			$dform." ".join(" | ", @links),
			]);
		}
	print &ui_columns_table([ $text{'col_name'}, $text{'col_repo'},
				  $text{'col_branch'}, $text{'col_target'},
				  $text{'col_mode'}, $text{'col_last'},
				  "" ],
				100, \@table);
	}
else {
	print "<p><i>$text{'index_none'}</i></p>\n";
	}

print &ui_link("edit_deploy.cgi?dom=$d->{'id'}&new=1", $text{'index_add'}),
      "<br>\n";
print &ui_link("sshkey.cgi?dom=$d->{'id'}", $text{'index_sshkey'}),
      "<br>\n";

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
