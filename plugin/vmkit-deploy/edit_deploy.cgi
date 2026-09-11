#!/usr/bin/perl
# Add or edit a deployment.
#
# The form itself lives in the library (print_deploy_form) because
# save_deploy.cgi draws the same form when "Check repository" is pressed - see
# the note there.
use strict;
use warnings;
our (%text, %in, %config, $module_name);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-deploy'} || &error(&text('index_eoff', $d->{'dom'}));

my ($dep, $actions, $new) = &deploy_from_in($d);
$dep || &error($text{'edit_egone'});

&ui_print_header(&virtual_server::domain_in($d),
		 $new ? $text{'edit_title_new'} : $text{'edit_title'},
		 "", undef, 0, 0);

&print_deploy_form($d, $dep, $actions, $new);

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
