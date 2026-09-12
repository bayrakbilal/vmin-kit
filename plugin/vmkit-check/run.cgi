#!/usr/bin/perl
# Runs the checks and stores the result.
use strict;
use warnings;
our (%text, %in);

require './vmkit-check-lib.pl';
&ReadParse();
&error_setup($text{'run_err'});
&virtual_server::master_admin() || &error($text{'index_eaccess'});

my $r = &run_and_save();
&webmin_log("run", "check", undef,
	    { 'total' => $r->{'total'}, 'failed' => $r->{'failed'} });
&redirect("index.cgi");
