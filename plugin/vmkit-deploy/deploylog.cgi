#!/usr/bin/perl
# Shows the last deployment's log.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &domain_from_in();

my $dep = &get_deploy($d, $in{'id'});
$dep || &error($text{'edit_egone'});

&ui_print_header(&virtual_server::domain_in($d), $text{'log_title'},
		 "", undef, 0, 0);

# The log file is RAW output: no date header, no status line. Both live in the
# deployment record and are printed below from there. Writing them into the
# file as well would mix formatting into it - the theme OVERRIDES make_date and
# returns a <span ...>, which showed up as plain text on this page.
#
# Same layout as the running page: output first, result line after.
my $log = &deploy_log_read($d, $dep);
if (!defined($log) || $log !~ /\S/) {
	print "<p><i>$text{'deploy_nolog'}</i></p>\n";
	}
else {
	print "<pre style='white-space:pre-wrap; margin-bottom:16px'>",
	      &html_escape($log), "</pre>\n";
	}
if ($dep->{'last_time'}) {
	print "<p><b>",
	      &ui_text_color($dep->{'last_status'} eq 'ok' ? $text{'st_ok'}
							   : $text{'st_failed'},
			     $dep->{'last_status'} eq 'ok' ? 'success' : 'danger'),
	      "</b> - ", &op_label($dep->{'last_op'} || 'both'),
	      " - ", &make_date($dep->{'last_time'}), "</p>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
