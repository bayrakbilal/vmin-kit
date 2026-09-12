#!/usr/bin/perl
# Applies one repair, then runs the checks again so the page shows the result.
use strict;
use warnings;
our (%text, %in);

require './vmkit-check-lib.pl';
&ReadParse();
&error_setup($text{'fix_err'});
&virtual_server::master_admin() || &error($text{'index_eaccess'});

$in{'id'} =~ /^[a-z_]+$/ || &error($text{'fix_eunknown'});
my $err = &apply_fix($in{'id'});
&error($err) if ($err);
&run_and_save();
&webmin_log("fix", "check", $in{'id'});
&redirect("index.cgi?msg=".&urlize($text{'fix_done'}));
