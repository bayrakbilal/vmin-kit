#!/usr/bin/perl
# Yerel zone ile Cloudflare'i karsilastirir. HICBIR SEY YAZMAZ.
#
# Siniflandirma sync_plan()'dan geliyor: senkronun kullandigi kodun AYNISI.
# Bu ekranda yazan ile gerceklesecek olan boylece ayrisamaz. (Eskiden burada
# ayni mantigin ikinci bir kopyasi vardi ve zamanla ayristi.)
#
# Karsilastirma ad+tip GRUBU uzerinden yapilir, tek tek kayit uzerinden degil:
# ayni ad ve tipte degeri farkli bir kayit, iki ayri satir degil TEK BIR
# CAKISMADIR.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-cloudflare-lib.pl';
&ReadParse();

my $d = &virtual_server::get_domain($in{'dom'});
$d || &error($text{'index_edom'});
&can_edit_domain($d) || &error($text{'index_eaccess'});
$d->{'vmkit-cloudflare'} || &error(&text('index_eoff', $d->{'dom'}));

&ui_print_header(&virtual_server::domain_in($d), $text{'cmp_title'},
		 "", undef, 0, 0);

my ($plan, $err) = &sync_plan($d);
if ($err) {
	print "<p><b>$text{'cmp_eapi'}</b></p>\n";
	print "<pre style='white-space:pre-wrap'>",&html_escape($err),"</pre>\n";
	&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
	exit;
	}

print "<p><b>",&html_escape($in{'msg'}),"</b></p>\n" if ($in{'msg'});

my $cf = &get_cf($d);

# Islem baglantisi. Tablo icindeki kucuk cerceveli dugme gorunumunu tema
# ui_links_row'un icindeki baglantilara veriyor (Virtualmin'in kendi
# "Features and Plugins" sayfasi da boyle yapiyor).
#
# Baglanti GET demek, yani onbellek ya da onceden getirme onu tetikleyebilir.
# Bu yuzden BAGLANTI HICBIR SEY DEGISTIRMIYOR: yalnizca onay sayfasini aciyor,
# islem oradaki POST ile oluyor. Kural, silme kadar sahiplenme ve iceri
# aktarma icin de gecerli - tiklamadan hicbir sey olmamali.
#
# RENK: ui_link'in ucuncu parametresi olan 'class' ile veriliyor.
#
# Iki yol denendi ve ikisi de olmadi: etiketi ui_text_color ile sarmak
# tutmuyor, cunku tema etiketten isaretlemeyi sokup metni kendi <span>'ine
# sariyor; dugmelerdeki "dil anahtarina gore renk" yontemi de burada
# gecersiz, uretilen baglantida data-entry bile yok.
#
# Sinif tema tarafindan taniniyorsa renk geliyor, tanimiyorsa sessizce yok
# sayiliyor - baglanti yine calisir, yalnizca renksiz olur. Bu yuzden
# gorunume bagli bir bozulma riski tasimiyor.
my $lnk = sub {
	my ($id, $act, $label, $class) = @_;
	return &ui_link("action.cgi?dom=$d->{'id'}&id=".&urlize($id).
			"&act=".&urlize($act), $label, $class);
	};

# Proxy hucresi: yazili dugme degil BULUT SIMGESI.
#
# Yazili dugmeler satirlari dikeyde buyutuyordu; simge yer kaplamiyor ve
# Cloudflare'in kendi turuncu/gri bulut gosterimiyle ayni dili konusuyor.
# Ayrica dugme rengini temanin dil anahtarina gore vermesi sorunu da
# ortadan kalkiyor: burada rengi metin olarak biz veriyoruz.
my $cloud = sub {
	my ($on) = @_;
	return $on ? &ui_text_color("&#9729;", 'warn')
		   : "<span style='opacity:0.45'>&#9729;</span>";
	};

# Tiklanabilir bulut: govdesi HTML olabilsin diye ui_submit degil duz bir
# <button type=submit>. Tema SINIFI VERILMIYOR - dugme gorunumu istemiyoruz
# zaten, yalnizca tiklanabilir bir simge. Islem mutasyon oldugu icin POST.
my $cloud_btn = sub {
	my ($id, $on) = @_;
	return &ui_form_start("action.cgi", "post", undef,
			      "style='display:inline-block;margin:0'").
	       &ui_hidden("dom", $d->{'id'}).
	       &ui_hidden("id", $id).
	       &ui_hidden("act", "proxy").
	       "<button type='submit' title=\"".
	       &quote_escape($on ? $text{'proxy_on'} : $text{'proxy_off'})."\" ".
	       "style='border:0;background:none;padding:0;cursor:pointer;".
	       "font-size:1.3em;line-height:1'>".&$cloud($on)."</button>".
	       &ui_form_end();
	};

# Bizim kayitlarimizda simge tiklanabilir; bizim olmayanlarda (tunel gibi)
# yalnizca durumu gosterir. Proxy yalnizca A, AAAA ve CNAME icin gecerli.
# Simge tek basina yeterince acik olmadigi icin anlami her zaman title'da.
my $proxy_cell = sub {
	my ($e) = @_;
	return "-" if ($e->{'type'} !~ /^(A|AAAA|CNAME)$/);
	my @cr = @{$e->{'crecs'}};
	if (!@cr) {
		# Kayit henuz yok: olusturuldugunda alacagi durum, soluk.
		my $on = $cf->{'proxy'} &&
			 !&never_proxy(&record_label($d, $e->{'name'})) ? 1 : 0;
		return "<span style='opacity:0.5' title=\"".
		       &quote_escape(&text('proxy_new',
				$on ? $text{'proxy_on'} : $text{'proxy_off'})).
		       "\">".&$cloud($on)."</span>";
		}
	return join(" ", map {
		my $on = $_->{'proxied'} ? 1 : 0;
		&cf_is_ours($_)
			? &$cloud_btn($_->{'id'}, $on)
			: "<span title=\"".
			  &quote_escape($on ? $text{'proxy_on'} : $text{'proxy_off'}).
			  "\">".&$cloud($on)."</span>";
		} @cr);
	};

my ($lcount, $ccount) = (0, 0);
foreach my $e (@$plan) {
	$lcount += scalar(@{$e->{'lvals'}});
	$ccount += scalar(@{$e->{'crecs'}});
	}
print "<p>",&text('cmp_counts', $lcount, $ccount),"</p>\n";

my (@insync, @outside);
foreach my $e (@$plan) {
	my @lv = @{$e->{'lvals'}};
	my @cv = @{$e->{'cvals'}};
	my @cr = @{$e->{'crecs'}};
	my $lcol = @lv ? "<tt>".&short_value(join(", ", sort @lv))."</tt>" : "-";
	my $ccol = @cv ? "<tt>".&short_value(join(", ", sort @cv))."</tt>" : "-";

	# Durum METNI ve RENK TIPI ayri tutuluyor; renk en sonda, uyari
	# simgesiyle BIRLIKTE uygulaniyor. Eskiden simge renkli metnin disinda
	# kaliyordu ve tek basina renksiz duruyordu.
	#
	# Gecerli tipler: success / info / warn / danger. Baska bir ad verilirse
	# ui_text_color sessizce renksiz birakiyor.
	my ($state, $type, $note, $out, $acts) = ("", "", "", 0, "");
	my $op = $e->{'op'};
	if    ($op eq 'create') { ($state, $type) = ($text{'st_willcreate'}, 'success'); }
	elsif ($op eq 'delete') { ($state, $type) = ($text{'st_willdelete'}, 'danger'); }
	elsif ($op eq 'update') { ($state, $type) = ($text{'st_willupdate'}, 'warn'); }
	elsif ($op eq 'adopt')  { ($state, $type) = ($text{'st_willadopt'}, 'info'); }
	# Senkron olan satirlar da yesil: tablonun cogunlugu bunlar ve "her sey
	# yerinde" bilgisi renksiz birakilinca gorunmuyordu.
	elsif ($op eq 'none')   { ($state, $type) = ($text{'st_insync'}, 'success'); }
	else {
		# skip: kapsam disi. Neden oldugu 'why' alaninda.
		$out = 1;
		my @links;
		if ($e->{'why'} eq 'cnameclash') {
			($state, $type, $note) =
				($text{'st_blocked'}, 'danger', $text{'st_cnameclash'});
			push(@links, &$lnk($e->{'blocker'}->{'id'}, 'delete',
					   $text{'act_delcname'}, 'btn-danger'));
			}
		elsif ($e->{'why'} eq 'notours') {
			($state, $type) = ($text{'st_notours'}, 'info');
			# Proxy'li kayitlara eylem YOK: tipik ornek Cloudflare
			# tuneli; icerigi yerel zone'da anlamsiz, silinmesi
			# calisan bir kurulumu bozar.
			foreach my $r (@cr) {
				next if ($r->{'proxied'});
				push(@links,
				     &$lnk($r->{'id'}, 'import', $text{'act_import'}, 'btn-info'),
				     &$lnk($r->{'id'}, 'delete', $text{'act_delete'}, 'btn-danger'));
				}
			}
		else {
			($state, $type, $note) =
				($text{'st_conflict'}, 'warn', $text{'st_conflict_note'});
			foreach my $r (@cr) {
				next if ($r->{'proxied'});
				push(@links,
				     &$lnk($r->{'id'}, 'adopt', $text{'act_adopt'}, 'btn-warning'),
				     &$lnk($r->{'id'}, 'import', $text{'act_import'}, 'btn-info'));
				}
			}
		# Kucuk cerceveli gorunumu veren sarmalayici bu.
		$acts = @links ? &ui_links_row(\@links) : "";
		# Eylem cikmamasinin sebebini not olarak acikla.
		$note = $text{'st_proxied2'} if (!@links && $e->{'proxied'});
		}

	# Not, ayri bir sutun yerine durumun basindaki uyari simgesinde:
	# ilk tabloda not hic olmuyordu, ikincide uzun metin satiri sisiriyordu.
	#
	# Simge metnin ICINDE renklendiriliyor, ipucu ise disaridaki sarmalayicida.
	my $scell = $note ? "&#9888; ".$state : $state;
	$scell = &ui_text_color($scell, $type) if ($type);
	$scell = "<span title=\"".&quote_escape($note)."\">".$scell."</span>"
		if ($note);
	my $row = [ $e->{'name'}, $e->{'type'}, $lcol, $ccol, &$proxy_cell($e), $scell ];
	if ($out) { push(@outside, [ @$row, $acts ]); }
	else      { push(@insync,  $row); }
	}

my @heads = ( $text{'cmp_name'}, $text{'cmp_type'}, $text{'cmp_local'},
	      $text{'cmp_cf'}, $text{'cmp_proxy'}, $text{'cmp_state'} );

print &ui_subheading($text{'cmp_tbl_sync'});
if (@insync) {
	print &ui_columns_table(\@heads, 100, \@insync);
	}
else {
	print "<p><i>$text{'cmp_none_sync'}</i></p>\n";
	}

print &ui_subheading($text{'cmp_tbl_outside'});
if (@outside) {
	print "<p>$text{'cmp_outside_intro'}</p>\n";
	print &ui_columns_table([ @heads, $text{'cmp_actions'} ], 100, \@outside);
	}
else {
	print "<p><i>$text{'cmp_none_outside'}</i></p>\n";
	}

print "<p><font size=-1>$text{'cmp_readonly'} $text{'cmp_proxy_help'}</font></p>\n";

&ui_print_footer("index.cgi?dom=$d->{'id'}", $text{'index_return2'});
