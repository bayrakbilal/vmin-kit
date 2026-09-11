#!/usr/bin/perl
# A manual sync: applies the operations in the plan and prints every step.
#
# ---------------------------------------------------------------------------
# THE FILE NAME MATTERS: it MUST end in "_progressive.cgi".
#
# The Authentic theme decides in JavaScript whether to stream a request or to
# wait and print it in one go: unbuffered_header_processor_allow() holds a
# hard-coded list of paths hundreds of lines long. Anything not on it goes
# through pjax, which only paints once the response is complete. At the end of
# that list is a general door for third parties:
#     n.indexOf("_progressive.cgi") > -1 || n.indexOf("_saving.cgi") > -1
#
# An unbuffered header is required too ($| = 1), and the theme wants to see a
# <pre> in the first chunk of content - hence the <pre> right after the header.
#
# A form posting here may NOT have a FIELD NAMED 'action' or 'target': a
# field's name shadows the form's own property, and the theme opens the door
# through e.target.action.
# ---------------------------------------------------------------------------
#
# The output here is NOT the raw output of a shell command - the sync runs no
# external command, it steps through the Cloudflare API. The lines are written
# here, one short line per step saying what was just done (created / updated /
# deleted / adopted, or an error).
use strict;
use warnings;
our (%text, %in);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

&ui_print_unbuffered_header(&virtual_server::domain_in($d), $text{'sync_title'},
			    "", undef, 0, 0);

print "<pre style='white-space:pre-wrap; margin-bottom:16px'>";
my ($ok, $err) = &run_sync($d, sub {
	print &html_escape($_[0]), "\n";
	});
print "</pre>\n";

# The result line is coloured, in the same language as the list and comparison
# pages. This branch covers errors that stop the run before any step: the plan
# could not be built, or the zone was not found. The <pre> above is empty then
# and the error is shown here.
if ($err) {
	print "<p><b>",&ui_text_color($text{'sync_failed'}, 'danger'),"</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	}
else {
	print "<p><b>",
	      &ui_text_color($ok ? $text{'sync_ok'} : $text{'sync_partial'},
			     $ok ? 'success' : 'warn'),
	      "</b></p>\n";
	}

&webmin_log("sync", "cloudflare", $d->{'dom'},
	    { 'status' => $err ? "error" : ($ok ? "ok" : "partial") });

# Navigation goes in the footer, not the body: comparison and settings, both
# presented the same way.
&ui_print_footer("compare.cgi?dom=$d->{'id'}", $text{'index_compare'},
		 "index.cgi?dom=$d->{'id'}", $text{'index_return2'});
