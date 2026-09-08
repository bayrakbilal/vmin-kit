#!/usr/bin/perl
# Bir deployment'in dalindaki son commit'ler.
# Yalnizca OKUR: bare repoya git log calistirir, hicbir sey degistirmez.
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
