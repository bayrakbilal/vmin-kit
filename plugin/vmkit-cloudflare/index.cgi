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
