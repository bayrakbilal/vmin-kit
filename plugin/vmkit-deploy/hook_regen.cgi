#!/usr/bin/perl
# Web kancasi adresini yeniden uretir. Eski adres bu andan itibaren gecersiz.
#
# Kaydet formundan AYRI: adresi degistirmek icin repo kontrolunun basarili
# olmasini beklemek ya da baska alanlari yeniden kaydetmek gerekmesin.
# Mutasyon oldugu icin yalnizca POST.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();
&error_setup($text{'save_err'});

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-deploy'} || &error(&text('index_eoff', $d->{'dom'}));

my $dep = &get_deploy($d, $in{'id'});
$dep || &error($text{'edit_egone'});

$dep->{'uuid'} = &new_uuid();
&save_deploy($d, $dep);

&webmin_log("hookregen", "deploy", $dep->{'name'} || $dep->{'id'});
&redirect("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}");
