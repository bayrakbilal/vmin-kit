#!/usr/bin/perl
# Son deploy kaydini DUZ METIN olarak dondurur (modal icin).
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();

print "Content-type: text/plain; charset=utf-8\n\n";

my $d = &virtual_server::get_domain($in{'dom'});
if (!$d) { print $text{'index_edom'},"\n"; exit; }
if (!&can_edit_domain($d)) { print $text{'index_eaccess'},"\n"; exit; }

my $dep = &get_deploy($d, $in{'id'});
if (!$dep) { print $text{'edit_egone'},"\n"; exit; }

my $log = &deploy_log_read($d, $dep);
print defined($log) && $log ne '' ? $log : $text{'deploy_nolog'}, "\n";
