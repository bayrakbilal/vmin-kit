#!/usr/bin/perl
# Deployment kaydet / sil.
# Burasi yalnizca TANIMI yazar; cekme islemi deploy.cgi -> run_deploy().
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
$in{'mode'} =~ /^(manual|auto)$/  || &error($text{'save_emode'});
$in{'name'} =~ /^[A-Za-z0-9._\- ]*$/ || &error($text{'save_ename'});

# Hedef klasor domainin home'unun disina cikamaz.
# Formdaki alan BELGE KOKUNE gore; depoda ev dizinine gore sakliyoruz ki
# deploy_target_dir ve eski kayitlar ayni bicimi kullansin.
my $target = &target_full($d, $in{'target'});
my $terr = &validate_target($d, $target);
&error($terr) if ($terr);

# Ayni hedefe iki deployment olmasin - hangisinin yazdigi belirsiz olurdu.
foreach my $other (&list_deploys($d)) {
	next if (!$in{'new'} && $other->{'id'} eq $dep->{'id'});
	if ($other->{'target'} eq $target) {
		&error(&text('save_edup', $other->{'name'} || $other->{'id'}));
		}
	}

# Repo gercekten ulasilabilir mi ve dal orada var mi? Formda kontrol edilmis
# olsa da burada tekrar bakiyoruz: form ile kaydet arasinda erisim degismis
# olabilir ve calismayan bir tanimi kaydetmek istemiyoruz.
my ($defbranch, $branches, $rerr) = &remote_branches($d, $in{'repo'});
&error(&text('save_ereporeach', "<pre>".&html_escape($rerr)."</pre>")) if ($rerr);
&indexof($in{'branch'}, @$branches) >= 0 || &error($text{'save_ebranchgone'});

# ---- kaydet ----
$dep->{'name'}   = $in{'name'};
$dep->{'repo'}   = $in{'repo'};
$dep->{'branch'} = $in{'branch'};
$dep->{'target'} = $target;
$dep->{'mode'}   = $in{'mode'};
$dep->{'actions_on'} = $in{'actions_on'} ? 1 : 0;
&save_deploy($d, $dep);

# Komut metni DOGRULANMIYOR: serbest bicimli kabuk satirlari, sablon yok.
# Yetki acisindan yeni bir sey acmiyor - komutlar domainin kendi kullanicisi
# olarak calisiyor ve bu formu yalnizca root ya da domainin sahibi aciyor;
# domain sahibi ayni komutlari zaten SSH ya da cron ile calistirabiliyor.
#
# Kayit save_deploy'dan SONRA: yeni deployment'in kimligi orada uretiliyor ve
# komut dosyasinin adi o kimlige bagli.
&actions_write($d, $dep, $in{'actions'});

&webmin_log($in{'new'} ? "create" : "modify", "deploy",
	    $dep->{'name'} || $dep->{'id'});
&redirect("index.cgi?dom=$d->{'id'}");
