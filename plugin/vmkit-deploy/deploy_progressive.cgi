#!/usr/bin/perl
# Runs a deployment and shows its output on an ordinary page. Webmin's ui-lib
# has no modal or popup support, so the theme's standard page layout is used
# rather than inventing a window of our own.
#
# The op parameter:
#   pull    pull only (the site does not change)
#   deploy  deploy only
#   absent  decided by the deployment's mode: automatic means pull+deploy,
#           manual means pull only. The webhook also arrives without it, so
#           both follow the same rule.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &domain_from_in();

my $dep = &get_deploy($d, $in{'id'});
$dep || &error($text{'edit_egone'});

# An unknown or missing op is decided by the mode.
my $op = $in{'op'} || '';
if ($op !~ /^(pull|deploy|both)$/) {
	$op = ($dep->{'mode'} || 'manual') eq 'auto' ? 'both' : 'pull';
	}

# ---------------------------------------------------------------------------
# THE FILE NAME MATTERS: it MUST end in "_progressive.cgi".
#
# The Authentic theme decides in JavaScript whether to stream a request or to
# wait and print it in one go: unbuffered_header_processor_allow() holds a
# hard-coded list of paths hundreds of lines long (virtual-server/
# enable_dkim.cgi, package-updates/update.cgi, webmin/upgrade.cgi ...).
# Anything not on it goes through ordinary pjax, which only paints once the
# response is complete.
#
# The last two lines of that list are the general door left open for third
# parties:
#     n.indexOf("_progressive.cgi") > -1 || n.indexOf("_saving.cgi") > -1
# so any CGI whose name contains "_progressive.cgi" is streamed.
#
# An unbuffered header is required too (ui_print_unbuffered_header, $| = 1).
#
# The layout follows Virtualmin's own "doing work" pages (enable_dkim.cgi):
# nothing above, output starts immediately, result and notes at the end - the
# result cannot be at the top, it is not known until the work finishes.
&ui_print_unbuffered_header(&virtual_server::domain_in($d), &op_label($op),
			    "", undef, 0, 0);

$dep->{'last_trigger'} = 'panel';
print "<pre style='white-space:pre-wrap; margin-bottom:16px'>";

my ($ok, $out) = &deploy_run($d, $dep, $op, sub {
	print &html_escape($_[0]), "\n";
	});
print "</pre>\n";

&webmin_log($op, "deploy", $dep->{'name'} || $dep->{'id'},
	    { 'status' => $ok ? "ok" : "failed" });

print "<p><b>",
      &ui_text_color($ok ? $text{'deploy_ok'} : $text{'deploy_failed'},
		     $ok ? 'success' : 'danger'),
      "</b></p>\n";

# Pulled but not published: offer the next step right here, since that middle
# state is the whole point of manual mode.
#
# It sits IN A BOX with explanatory text. On its own at the foot of the page,
# just above the footer link, the button was mistaken for "go back" and clicked
# by accident - an unwanted deployment. Publishing a site must not be something
# you click by mistake.
if ($ok && $op eq 'pull' && &pending($d, $dep)) {
	print "<div style='border:1px solid #999; padding:10px; margin:12px 0'>\n";
	print "<b>", $text{'deploy_pending'}, "</b><br>\n";
	print "<font size=-1>",
	      &text('deploy_pending_help', $dep->{'pulled_ref'} || ''),
	      "</font><br><br>\n";
	print &ui_form_start("deploy_progressive.cgi", "post");
	print &ui_hidden("dom", $d->{'id'});
	print &ui_hidden("id", $dep->{'id'});
	print &ui_hidden("op", "deploy");
	print &ui_submit($text{'deploy_now_install'});
	print &ui_form_end();
	print "</div>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
