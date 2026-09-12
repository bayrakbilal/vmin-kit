#!/usr/bin/perl
# Saves a domain's Cloudflare settings.
# It only writes settings; it does not trigger a sync - sync_progressive.cgi or
# the service does that.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'save_err'});

my $d = &domain_from_in();

my $cf = &get_cf($d);

# ---- delete the token ----
# The confirm button's language key is 'delete_ok'. The theme's
# get_button_style looks the label up in %text to find the key and searches
# THE KEY NAME for a word; containing 'delete' gives red + a cross icon. The
# deploy plugin uses the same key names.
#
# The action cannot be undone: the token is never shown again and a new one has
# to be generated at Cloudflare. Confirmation first, deletion second.
if ($in{'delete'} && !$in{'confirm'}) {
	&ui_print_header(&virtual_server::domain_in($d), $text{'delete_title'},
			 "", undef, 0, 0);
	print "<p>",&text('delete_warn', "<tt>".&html_escape($d->{'dom'})."</tt>"),
	      "</p>\n";
	print "<ul>\n";
	print "<li>$text{'delete_goes'}</li>\n";
	print "<li><b>$text{'delete_stays'}</b></li>\n";
	print "</ul>\n";
	print &ui_form_start("save.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("confirm", 1);
	print &ui_form_end([ [ "delete", $text{'delete_ok'} ] ]);
	&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'delete_cancel'});
	exit;
	}
if ($in{'delete'}) {
	delete($cf->{'token'});
	&save_cf($d, $cf);
	&webmin_log("deltoken", "cloudflare", $d->{'dom'});
	&redirect("index.cgi?dom=$d->{'id'}");
	exit;
	}

# An empty token field keeps the current value: it is displayed masked, so it
# should not have to be retyped on every save.
if ($in{'token'} =~ /\S/) {
	$in{'token'} =~ /^[A-Za-z0-9_\-]{20,}$/ || &error($text{'save_etoken'});
	$cf->{'token'} = $in{'token'};
	}
$cf->{'enabled'} = $in{'enabled'} ? 1 : 0;
$cf->{'proxy'} = $in{'proxy'} ? 1 : 0;
&save_cf($d, $cf);

&webmin_log("save", "cloudflare", $d->{'dom'});
&redirect("index.cgi?dom=$d->{'id'}");
