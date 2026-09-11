#!/usr/bin/perl
# Turns a domain's AUTOMATIC sync on or off in one click.
# The button on the list page posts here, so the settings page is not needed.
# The token is untouched - switching off only stops the automatic pushing.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'toggle_err'});

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

my $cf = &get_cf($d);
$cf->{'enabled'} = $cf->{'enabled'} ? 0 : 1;
&save_cf($d, $cf);

&webmin_log($cf->{'enabled'} ? "enable" : "disable", "cloudflare", $d->{'dom'});

# Back to wherever this came from: the list, or the domain's own page.
my $msg = &text($cf->{'enabled'} ? 'toggle_on' : 'toggle_off', $d->{'dom'});
if (($in{'back'} || '') eq 'dom') {
	&redirect("index.cgi?dom=$d->{'id'}&msg=".&urlize($msg));
	}
else {
	&redirect("index.cgi?msg=".&urlize($msg));
	}
