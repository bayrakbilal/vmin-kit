#!/usr/bin/perl
# Cloudflare DNS senkron ayarlari (sunucu geneli).
use strict;
use warnings;
our (%text, %config, $module_name);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

&ui_print_header(undef, $text{'index_title'}, "", undef, 1, 1);

# Sadece master admin gormeli - sunucu geneli bir ayar.
&virtual_server::master_admin() || &error($text{'index_eaccess'});

no warnings "once";
if (&indexof($module_name, @virtual_server::plugins) < 0) {
	&ui_print_endpage($text{'index_eplugin'});
	}
use warnings "once";

print "<p>$text{'index_intro'}</p>\n";

# ---- API token ----
print &ui_form_start("save.cgi", "post");
print &ui_table_start($text{'index_settings'}, "width=100%", 2);

print &ui_table_row($text{'index_token'},
	&ui_password("api_token", "", 50)."<br>".
	"<font size=-1>".
	(&token_set() ? &text('index_token_set', &masked_token())
		      : $text{'index_token_none'}).
	"<br>$text{'index_token_help'}</font>");

print &ui_table_row($text{'index_proxy'},
	&ui_yesno_radio("proxy_default", $config{'proxy_default'} ? 1 : 0).
	"<br><font size=-1>$text{'index_proxy_help'}</font>");

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

# ---- domain listesi ----
print "<hr>\n";
print &ui_subheading($text{'index_domains'});

my @doms = grep { $_->{'dns'} } &virtual_server::list_domains();
if (!@doms) {
	print "<p><i>$text{'index_nodoms'}</i></p>\n";
	}
else {
	print &ui_form_start("save.cgi", "post");
	print &ui_hidden("domains", 1);
	my @table;
	foreach my $d (@doms) {
		push(@table, [
			{ 'type' => 'checkbox', 'name' => 'sync',
			  'value' => $d->{'id'},
			  'checked' => &sync_enabled($d) },
			$d->{'dom'},
			&zone_status($d),
			]);
		}
	print &ui_columns_table(
		[ "", $text{'col_domain'}, $text{'col_status'} ],
		100, \@table, undef, 0, undef, $text{'index_nodoms'});
	print &ui_form_end([ [ undef, $text{'save'} ] ]);
	}


&ui_print_footer("/", $text{'index'});
