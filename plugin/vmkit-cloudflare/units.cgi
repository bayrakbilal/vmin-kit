#!/usr/bin/perl
# Reinstalls and starts the automatic sync units.
# The files are rewritten unconditionally (force), so a unit file that is
# corrupt or was edited by hand is repaired by this button too.
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();
&error_setup($text{'svc_err'});

# A system service: the server administrator only. A domain owner must not be
# able to restart system units from their own page.
&virtual_server::master_admin() || &error($text{'svc_eaccess'});

my ($done, $err) = &ensure_sync_units(1);
&error($err) if ($err);

&webmin_log("units", "cloudflare", undef, { 'done' => join(", ", @$done) });

my @args = ( "msg=".&urlize($text{'svc_repaired'}) );
push(@args, "dom=".&urlize($in{'dom'})) if ($in{'dom'});
&redirect("index.cgi?".join("&", @args));
