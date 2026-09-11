#!/usr/bin/perl
# Runs a composer command in a project and STREAMS its output.
#
# ---------------------------------------------------------------------------
# THE FILE NAME MATTERS: it MUST end in "_progressive.cgi".
#
# The Authentic theme decides in JavaScript whether to stream a request or to
# wait and print it in one go: unbuffered_header_processor_allow() holds a
# hard-coded list of paths hundreds of lines long (virtual-server/
# enable_dkim.cgi, package-updates/update.cgi ...). Anything not on it goes
# through ordinary pjax, which only paints once the response is complete.
#
# The last two lines of that list are the general door left open for third
# parties:
#     n.indexOf("_progressive.cgi") > -1 || n.indexOf("_saving.cgi") > -1
#
# An unbuffered header is required too (ui_print_unbuffered_header, $| = 1),
# and the theme wants to see a <pre> in the first chunk of content - hence the
# <pre> opening right after the header.
# ---------------------------------------------------------------------------
#
# NO CONFIRMATION PAGE. All four buttons in the list are POST forms, so a
# command only runs on a deliberate click; a cache or a prefetch cannot
# trigger it. Pull and deploy on the git side ask for no confirmation either -
# same rule.
use strict;
use warnings;
our (%text, %in);

require './vmkit-composer-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-composer'} || &error(&text('index_eoff', $d->{'dom'}));

# A directory arriving from a link is not trusted: it has to be one of the
# projects the scan found, or a command could be run outside the home.
my $p = &valid_project($d, $in{'dir'});
$p || &error($text{'run_edir'});

# The field is 'act', NOT 'action': a field named "action" shadows the form's
# own .action property, which is where the theme takes its streaming decision
# from (see the long note in index.cgi).
my $act = $in{'act'};
$act =~ /^(install|update|dump-autoload)$/ || &error($text{'err_action'});

# The layout follows Virtualmin's own "doing work" pages: nothing above,
# output starts immediately, result at the end - it is not known until the
# work finishes.
&ui_print_unbuffered_header(&virtual_server::domain_in($d),
			    &text('run_title', $act, $p->{'dir'}),
			    "", undef, 0, 0);

# The <pre> holds ONLY the command's raw output: what a terminal would show.
print "<pre style='white-space:pre-wrap; margin-bottom:16px'>";
my ($ok, $out) = &run_composer($d, $p, $act, sub {
	print &html_escape($_[0]), "\n";
	});
print "</pre>\n";

&webmin_log("composer", "composer", $p->{'dir'},
	    { 'action' => $act, 'status' => $ok ? "ok" : "failed" });

print "<p><b>",
      &ui_text_color($ok ? $text{'run_ok'} : $text{'run_failed'},
		     $ok ? 'success' : 'danger'),
      "</b></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'run_return'});
