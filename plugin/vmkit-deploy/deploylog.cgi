#!/usr/bin/perl
# Son deploy kaydini gosterir.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-deploy'} || &error(&text('index_eoff', $d->{'dom'}));

my $dep = &get_deploy($d, $in{'id'});
$dep || &error($text{'edit_egone'});

&ui_print_header(&virtual_server::domain_in($d), $text{'log_title'},
		 "", undef, 0, 0);

my $log = &deploy_log_read($d, $dep);
if (defined($log) && $log ne '') {
	print "<pre style='white-space:pre-wrap'>", &html_escape($log), "</pre>\n";
	}
else {
	print "<p><i>$text{'deploy_nolog'}</i></p>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
