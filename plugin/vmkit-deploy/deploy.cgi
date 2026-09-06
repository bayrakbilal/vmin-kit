#!/usr/bin/perl
# Bir deployment'i calistirir ve ciktisini DUZ METIN olarak dondurur.
# Sayfadaki modal bu ciktiyi fetch ile alip gosteriyor.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();

print "Content-type: text/plain; charset=utf-8\n\n";

my $d = &virtual_server::get_domain($in{'dom'});
if (!$d) { print $text{'index_edom'},"\n"; exit; }
if (!&can_edit_domain($d)) { print $text{'index_eaccess'},"\n"; exit; }
if (!$d->{'vmkit-deploy'}) { print &text('index_eoff', $d->{'dom'}),"\n"; exit; }

my $dep = &get_deploy($d, $in{'id'});
if (!$dep) { print $text{'edit_egone'},"\n"; exit; }

my ($ok, $out) = &run_deploy($d, $dep);
print $ok ? $text{'deploy_ok'} : $text{'deploy_failed'}, "\n\n";
print $out, "\n";
&webmin_log("deploy", "deploy", $dep->{'name'} || $dep->{'id'},
	    { 'status' => $ok ? "ok" : "failed" });
