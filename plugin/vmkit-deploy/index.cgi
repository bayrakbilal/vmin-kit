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
	# Cekme ve dagitim birer MUTASYON: baglanti degil POST dugmesi. Bir
	# baglantiya tiklamak, onu onbelleklemek ya da tarayicinin onceden
	# getirmesi bir dagitimi tetiklememeli.
	my $btn = sub {
		my ($dep, $op, $label) = @_;
		return &ui_form_start("deploy.cgi", "post", undef,
				      "style='display:inline-block;margin-right:6px'").
		       &ui_hidden("dom", $d->{'id'}).
		       &ui_hidden("id", $dep->{'id'}).
		       &ui_hidden("op", $op).
		       &ui_submit($label).
		       &ui_form_end();
		};

	my @table;
	foreach my $dep (@deps) {
		my $last = $dep->{'last_time'}
			? &op_label($dep->{'last_op'} || 'both')." - ".
			  ($dep->{'last_status'} eq 'ok' ? $text{'st_ok'}
							 : $text{'st_failed'}).
			  " - ".&make_date($dep->{'last_time'}).
			  # Elle mi kancadan mi tetiklendi: kanca calisiyor mu
			  # sorusunun cevabi listede gorunsun.
			  (($dep->{'last_trigger'} || '') eq 'hook'
				? " <font size=-1>(".$text{'trigger_hook'}.")</font>"
				: "")
			: $text{'never'};

		# Yayindaki ve cekilmis ucu ayri gosteriyoruz: manuel modun butun
		# anlami "cekildi ama daha yayinlanmadi" ara durumunu gormek.
		my $state;
		if (&pending($d, $dep)) {
			$state = "<b>".&text('state_pending',
					     $dep->{'pulled_ref'})."</b>".
				 ($dep->{'deployed_ref'}
					? "<br><font size=-1>".
					  &text('state_live', $dep->{'deployed_ref'}).
					  "</font>" : "");
			}
		elsif ($dep->{'deployed_ref'}) {
			$state = &text('state_live', $dep->{'deployed_ref'});
			}
		else {
			$state = "-";
			}

		# Ilk dugme MODA uyuyor: otomatikte cekme dagitimi da baslatir,
		# manuelde yalnizca ceker. Ikinci dugme her zaman yalnizca
		# dagitir - manuel modun bekleyen isini yayina almak icin.
		my $auto = ($dep->{'mode'} || 'manual') eq 'auto';
		my @acts = ( &$btn($dep, $auto ? 'both' : 'pull',
				   $auto ? $text{'act_pulldeploy'}
					 : $text{'act_pull'}) );
		push(@acts, &$btn($dep, 'deploy', $text{'act_deploy'}))
			if (-d &deploy_repo_path($d, $dep));
		my @links = (
			&ui_link("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				 $text{'act_edit'}),
			);
		# Repo yalnizca ilk cekmeden sonra olusuyor; iki baglantiyi da
		# o zaman gosteriyoruz.
		if ($dep->{'last_time'}) {
			push(@links,
			     &ui_link("commits.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				      $text{'act_commits'}),
			     &ui_link("deploylog.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				      $text{'act_log'}));
			}
		push(@table, [
			$dep->{'name'} || $dep->{'id'},
			$dep->{'repo'},
			$dep->{'branch'},
			"<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>",
			($dep->{'mode'} || 'manual') eq 'auto' ? $text{'mode_auto'}
							       : $text{'mode_manual'},
			$state,
			$last,
			join("", @acts)."<br>".&ui_links_row(\@links),
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

print &ui_link("edit_deploy.cgi?dom=$d->{'id'}&new=1", $text{'index_add'}),
      "<br>\n";
print &ui_link("sshkey.cgi?dom=$d->{'id'}", $text{'index_sshkey'}),
      "<br>\n";

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
