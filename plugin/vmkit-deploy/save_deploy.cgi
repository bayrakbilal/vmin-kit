#!/usr/bin/perl
# Deployment kaydet / sil.
# ISKELET: tanim kaydediliyor, git islemi henuz yapilmiyor.
use strict;
use warnings;
our (%text, %in);

require './vmkit-deploy-lib.pl';
&ReadParse();
&error_setup($text{'save_err'});

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});

my $dep;
if ($in{'new'}) {
	$dep = { };
	}
else {
	$dep = &get_deploy($d, $in{'id'});
	$dep || &error($text{'edit_egone'});
	}

# ---- silme ----
if ($in{'delete'}) {
	&delete_deploy($d, $dep);
	&webmin_log("delete", "deploy", $dep->{'name'} || $dep->{'id'});
	&redirect("index.cgi?dom=$d->{'id'}");
	exit;
	}

# ---- dogrulama ----
$in{'source'} =~ /^(local|remote)$/ || &error($text{'save_esource'});
$in{'mode'}   =~ /^(manual|auto)$/  || &error($text{'save_emode'});

$in{'name'} =~ /^[A-Za-z0-9._\- ]*$/ || &error($text{'save_ename'});

if ($in{'source'} eq 'remote') {
	$in{'repo'} =~ /\S/ || &error($text{'save_erepo'});
	$in{'repo'} =~ /^(https?:\/\/|git\@|ssh:\/\/)\S+$/
		|| &error($text{'save_erepourl'});
	}

$in{'branch'} =~ /^[A-Za-z0-9._\-\/]+$/ || &error($text{'save_ebranch'});

# Hedef klasor domainin home'unun disina cikamaz.
my $terr = &validate_target($d, $in{'target'});
&error($terr) if ($terr);

# Ayni hedefe iki deployment olmasin - hangisinin yazdigi belirsiz olurdu.
foreach my $other (&list_deploys($d)) {
	next if (!$in{'new'} && $other->{'id'} eq $dep->{'id'});
	if ($other->{'target'} eq $in{'target'}) {
		&error(&text('save_edup', $other->{'name'} || $other->{'id'}));
		}
	}

# ---- kaydet ----
$dep->{'name'}   = $in{'name'};
$dep->{'source'} = $in{'source'};
$dep->{'repo'}   = $in{'source'} eq 'remote' ? $in{'repo'} : '';
$dep->{'branch'} = $in{'branch'};
$dep->{'target'} = $in{'target'};
$dep->{'mode'}   = $in{'mode'};
&save_deploy($d, $dep);

&webmin_log($in{'new'} ? "create" : "modify", "deploy",
	    $dep->{'name'} || $dep->{'id'});
&redirect("index.cgi?dom=$d->{'id'}");
