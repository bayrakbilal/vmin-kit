#!/usr/bin/perl
# Updates the shared Roundcube and STREAMS each step live.
#
# The name MUST end in "_progressive.cgi": that is how the Authentic theme
# decides to stream the response instead of waiting for the whole page (see the
# long note in vmkit-composer/run_progressive.cgi). An unbuffered header and a
# <pre> in the first chunk are required too.
#
# POST only, reached from the Update button on the check page - a deliberate
# click, never a prefetch. Updating is a human decision; this is that human
# pressing the button, with the steps visible, not an automatic update.
use strict;
use warnings;
our (%text, %in);

require './vmkit-check-lib.pl';
&ReadParse();
&virtual_server::master_admin() || &error($text{'index_eaccess'});

# The target version comes from the page (the latest tag it found); accept only
# a version-shaped value, empty means "latest" (webmail_update resolves it).
my $ver = $in{'ver'};
$ver = "" if (!defined($ver) || $ver !~ /^[0-9][0-9.]+$/);

&ui_print_unbuffered_header(undef, $text{'wu_title'}, "", undef, 1, 1);

print "<pre style='white-space:pre-wrap; margin-bottom:16px'>";
my ($ok, $msg) = &webmail_update($ver, sub { print &html_escape($_[0]), "\n"; });
print "</pre>\n";

&webmin_log("webmail-update", "check", $ver || "latest",
	    { 'status' => $ok ? "ok" : "failed" });

print "<p><b>",
      &ui_text_color($ok ? $text{'wu_ok'} : $text{'wu_failed'},
		     $ok ? 'success' : 'danger'),
      "</b></p>\n";
print "<p>",&html_escape($msg),"</p>\n" if (!$ok && $msg);

&ui_print_footer("index.cgi", $text{'index_return'});
