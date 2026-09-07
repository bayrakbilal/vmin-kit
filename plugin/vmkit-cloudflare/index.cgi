#!/usr/bin/perl
# dom verilmisse o domainin Cloudflare ayarlari, verilmemisse domain listesi.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-cloudflare-lib.pl';
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

# ---- otomatik senkron servisi --------------------------------------------
# Modul kendi izleme servisinden sorumlu: sayfa acildiginda birim eksikse
# kurulur, durmussa baslatilir. Durum da her zaman gorunur - senkron sessizce
# durmus olsun istemiyoruz.
if (&virtual_server::master_admin()) {
	print &ui_alert_box(&html_escape($in{'msg'}), 'success') if ($in{'msg'});
	my $st = &sync_units_status();
	if ($st->{'systemd'} && !&sync_units_healthy($st)) {
		&ensure_sync_units();
		$st = &sync_units_status();
		}
	my $head;
	if (!$st->{'systemd'}) {
		$head = &ui_text_color($text{'svc_nosystemd'}, 'warn');
		}
	elsif ($st->{'ok'}) {
		$head = &ui_text_color("&#10004; ".$text{'svc_ok'}, 'success');
		}
	elsif ($st->{'nowatch'} && $st->{'timer'}->{'active'}) {
		# Zamanlayici ayakta ama anlik tetikleyici yok: senkron olur,
		# yalnizca 15 dakikaya kadar gecikir.
		$head = &ui_text_color("&#9888; ".$text{'svc_partial'}, 'warn');
		}
	else {
		$head = &ui_text_color("&#10008; ".$text{'svc_bad'}, 'danger');
		}
	print "<p>$head";
	if ($st->{'systemd'}) {
		print " &nbsp; <font size=-1>".$text{'svc_lastrun'}.": ".
		      &html_escape($st->{'lastrun'} || $text{'svc_never'});
		print " (".&html_escape($st->{'lastresult'}).")"
			if ($st->{'lastresult'} && $st->{'lastresult'} ne 'success');
		print "</font>";
		}
	print "</p>\n";

	# Ayrinti tablosu ve onarim dugmesi yalnizca bir sorun varken. Her sey
	# yerindeyken tek yesil satir yeterli.
	if ($st->{'systemd'} && !$st->{'ok'}) {
		my @tbl;
		foreach my $k ("path", "timer", "service") {
			my $u = $st->{$k};
			my $state = !$u->{'exists'} ? &ui_text_color($text{'svc_missing'}, 'danger') :
				    $k eq 'service' ? $text{'svc_oneshot'} :
				    $u->{'active'} ? &ui_text_color($text{'svc_running'}, 'success') :
						     &ui_text_color($text{'svc_stopped'}, 'danger');
			push(@tbl, [ "<tt>".&html_escape($u->{'name'})."</tt>",
				     $text{'svc_'.$k},
				     $state ]);
			}
		print &ui_columns_table(
			[ $text{'svc_col_unit'}, $text{'svc_col_role'},
			  $text{'svc_col_state'} ], 100, \@tbl);
		print "<p>".$text{'svc_nowatch'}."</p>\n" if ($st->{'nowatch'});
		print &ui_form_start("units.cgi", "post"),
		      ($in{'dom'} ? &ui_hidden("dom", $in{'dom'}) : ""),
		      &ui_submit($text{'svc_repair'}),
		      &ui_form_end();
		}
	}

# ---- domain secilmedi: erisebildiklerimizi listele ----
if (!$d) {
	my @doms = grep { $_->{$module_name} && &can_edit_domain($_) }
			&virtual_server::list_domains();
	if (!@doms) {
		&ui_print_endpage($text{'index_edoms'});
		}
	print "<p>$text{'index_pickdom'}</p>\n";
	my @table;
	foreach my $dd (@doms) {
		my $cf = &get_cf($dd);
		push(@table, [
			&ui_link("index.cgi?dom=$dd->{'id'}", $dd->{'dom'}),
			$cf->{'token'} ? $text{'yes'} : $text{'no'},
			&zone_status($dd),
			]);
		}
	print &ui_columns_table(
		[ $text{'col_domain'}, $text{'col_token'}, $text{'col_status'} ],
		100, \@table);
	&ui_print_footer("/", $text{'index'});
	exit;
	}

# ---- domainde ozellik kapaliysa uyar ----
if (!$d->{$module_name}) {
	&ui_print_endpage(&text('index_eoff', $d->{'dom'}));
	}

# ---- domainin ayarlari ----
my $cf = &get_cf($d);

print "<p>$text{'index_intro'}</p>\n";

print &ui_form_start("save.cgi", "post");
print &ui_hidden("dom", $d->{'id'});
print &ui_table_start($text{'index_settings'}, "width=100%", 2);

# Her domain kendi token'ini tasir: domainler farkli Cloudflare hesaplarinda
# olabilir ve token hesap/zone bazlidir.
print &ui_table_row($text{'index_token'},
	&ui_password("token", "", 50)."<br>".
	"<font size=-1>".
	($cf->{'token'} ? &text('index_token_set', &masked_token($cf->{'token'}))
			: $text{'index_token_none'}).
	"<br>$text{'index_token_help'}</font>");

print &ui_table_row($text{'index_proxy'},
	&ui_yesno_radio("proxy", $cf->{'proxy'} ? 1 : 0)."<br>".
	"<font size=-1>$text{'index_proxy_help'}</font>");

print &ui_table_row($text{'index_status'}, &zone_status($d));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ],
		     $cf->{'token'} ? ( [ "forget", $text{'index_forget'} ] ) : ( ) ]);

# Karsilastir ve Senkronize et: ikisi de ayri birer islem, ayni bicimde ve
# yan yana. Kaydet/Unut yukaridaki ayar formuna ait, orada kaliyor.
# Form blok eleman oldugu icin inline-block olmadan alt alta dizilirler.
my $inl = "style='display:inline-block;margin-right:6px'";
print "<p>";
print &ui_form_start("compare.cgi", "get", undef, $inl),
      &ui_hidden("dom", $d->{'id'}),
      &ui_submit($text{'index_compare'}),
      &ui_form_end();
if ($cf->{'token'}) {
	print &ui_form_start("sync.cgi", "post", undef, $inl),
	      &ui_hidden("dom", $d->{'id'}),
	      &ui_submit($text{'index_syncnow'}),
	      &ui_form_end();
	}
print "</p>\n";

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
