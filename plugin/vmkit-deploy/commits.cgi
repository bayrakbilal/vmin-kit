#!/usr/bin/perl
# The latest commits on a deployment's branch.
# READ ONLY: runs git log against the bare repository, changes nothing.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d = &domain_from_in();

my $dep = &get_deploy($d, $in{'id'});
$dep || &error($text{'edit_egone'});

&ui_print_header(&virtual_server::domain_in($d),
		 &text('commits_title', $dep->{'name'} || $dep->{'id'},
		       $dep->{'branch'}), "", undef, 0, 0);

my ($commits, $err) = &deploy_commits($d, $dep);
if ($err) {
	print "<p><b>",&html_escape($err),"</b></p>\n";
	}
elsif (!@$commits) {
	print "<p><i>$text{'commits_none'}</i></p>\n";
	}
else {
	my @table;
	foreach my $c (@$commits) {
		push(@table, [ "<tt>".&html_escape($c->{'hash'})."</tt>",
			       &html_escape($c->{'date'}),
			       &html_escape($c->{'author'}),
			       &html_escape($c->{'subject'}) ]);
		}
	print &ui_columns_table([ $text{'commits_hash'}, $text{'commits_date'},
				  $text{'commits_author'}, $text{'commits_subject'} ],
				100, \@table);
	print "<p><font size=-1>$text{'commits_note'}</font></p>\n";
	}

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'edit_return'});
