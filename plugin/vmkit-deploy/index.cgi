#!/usr/bin/perl
# Bir domainin deployment listesi.
use strict;
use warnings;
our (%text, %in, $module_name);

require './vmkit-deploy-lib.pl';
&ReadParse();

my $d;
if ($in{'dom'}) {
	$d = &virtual_server::get_domain($in{'dom'});
	$d || &error($text{'index_edom'});
	&can_edit_domain($d) || &error($text{'index_eaccess'});
	}

&ui_print_header($d ? &virtual_server::domain_in($d) : undef,
		 $text{'index_title'}, "", undef, 1, 1);

no warnings "once";
if (&indexof($module_name, @virtual_server::plugins) < 0) {
	&ui_print_endpage($text{'index_eplugin'});
	}
use warnings "once";

# ---- domain secilmedi: erisebildiklerimizi listele ----
if (!$d) {
	my @doms = grep { $_->{$module_name} && &can_edit_domain($_) }
			&virtual_server::list_domains();
	if (!@doms) {
		&ui_print_endpage($text{'index_edoms'});
		}
	print "<p>$text{'index_pickdom'}</p>\n";
	print &ui_columns_start([ $text{'index_dom'}, $text{'index_count'} ]);
	foreach my $dd (@doms) {
		print &ui_columns_row([
			&ui_link("index.cgi?dom=$dd->{'id'}", $dd->{'dom'}),
			scalar(&list_deploys($dd)) ]);
		}
	print &ui_columns_end();
	&ui_print_footer("/", $text{'index'});
	exit;
	}

if (!$d->{$module_name}) {
	&ui_print_endpage(&text('index_eoff', $d->{'dom'}));
	}

# Webmin'in ui-lib'i surumden surume BUYUYOR: yeni yardimcilar ekleniyor.
# Hedef sunucuda olmayan birini cagirmak sayfayi "Undefined subroutine" ile
# oldurur - ui_badge ile bunu bir kez yasadik (2.660'ta yok). Renk gibi
# suslemeler bu yuzden dogrudan cagrilmiyor: yoksa duz metne dusuyoruz.
sub colour
{
my ($txt, $type) = @_;
return defined(&ui_text_color) ? &ui_text_color($txt, $type) : $txt;
}

my @deps = &list_deploys($d);
if (@deps) {
	# Cekme ve dagitim birer MUTASYON: baglanti degil POST dugmesi. Bir
	# baglantiya tiklamak, onu onbelleklemek ya da tarayicinin onceden
	# getirmesi bir dagitimi tetiklememeli.
	my $btn = sub {
		my ($dep, $op, $label) = @_;
		return &ui_form_start("deploy.cgi", "post", undef,
				      "style='display:inline-block;margin-right:6px'").
		       &ui_hidden("dom", $d->{'id'}).
		       &ui_hidden("id", $dep->{'id'}).
		       &ui_hidden("op", $op).
		       &ui_submit($label).
		       &ui_form_end();
		};

	my @table;
	foreach my $dep (@deps) {
		# Gecerli renk tipleri: success, info, warn, danger. Baska bir ad
		# verilince ui_text_color hicbir renk uygulamiyor - 'good'/'bad'
		# yazmistim ve sessizce renksiz kaliyordu.
		my $last = $dep->{'last_time'}
			? &colour($dep->{'last_status'} eq 'ok'
					 ? $text{'st_ok'} : $text{'st_failed'},
					 $dep->{'last_status'} eq 'ok'
					 ? 'success' : 'danger')." - ".
			  &op_label($dep->{'last_op'} || 'both')." - ".
			  &make_date($dep->{'last_time'}).
			  # Elle mi kancadan mi tetiklendi: kanca calisiyor mu
			  # sorusunun cevabi listede gorunsun.
			  (($dep->{'last_trigger'} || '') eq 'hook'
				? " <small>(".$text{'trigger_hook'}.")</small>" : "")
			: $text{'never'};

		# Yayindaki ve cekilmis ucu ayri gosteriyoruz: manuel modun butun
		# anlami "cekildi ama daha yayinlanmadi" ara durumunu gormek.
		my $state;
		if (&pending($d, $dep)) {
			$state = &colour(&text('state_pending',
						      $dep->{'pulled_ref'}), 'warn').
				 ($dep->{'deployed_ref'}
					? "<br><small>".&text('state_live',
							$dep->{'deployed_ref'}).
					  "</small>"
					: "");
			}
		elsif ($dep->{'deployed_ref'}) {
			$state = &text('state_live', $dep->{'deployed_ref'});
			}
		else {
			$state = "-";
			}

		# Dugme adlari SABIT: "Cek" ve "Dagit". Cekme dugmesi otomatik
		# modda "Cek ve dagit" olurken satirlar farkli genislikte
		# cikiyordu ve liste tutarsiz gorunuyordu; oysa modun ne yaptigi
		# zaten Mod sutununda yaziyor.
		#
		# Islem degismiyor: op gonderilmiyor, ne yapilacagina deploy.cgi
		# modun kendisine bakarak karar veriyor - otomatikse cekip
		# dagitiyor. Boylece bu karar tek yerde, kancayla ayni yerde.
		#
		# DIL ANAHTARLARININ ADI RENGI VE IKONU BELIRLIYOR. Tema once
		# etiketi %text icinde arayip anahtari buluyor, sonra anahtar
		# adinin icinde kelime ariyor (get_button_style/string_contains):
		#   'update'  -> mavi + yenileme ikonu   (cekme)
		#   'install' -> yesil + paket ikonu     (dagitim)
		#   'delete'  -> kirmizi + carpi ikonu
		# Etiketler yine "Cek" ve "Dagit"; degisen yalnizca anahtar adi.
		#
		# DIKKAT: bir dugmenin ETIKET METNI dil dosyasinda BENZERSIZ
		# olmali. Tema anahtari soyle buluyor:
		#     ($keys) = grep { $module_text{$_} eq $label } keys %module_text
		# Ayni metne sahip iki anahtar varsa 'keys' her istekte farkli
		# sirada geldigi icin bazen digeri secilir ve renk gelip gider.
		# Bunu yasadik: 'Pull' hem pull_update hem op_pull idi.
		my @acts = ( &$btn($dep, '', $text{'pull_update'}) );
		push(@acts, &$btn($dep, 'deploy', $text{'deploy_install'}))
			if (-d &deploy_repo_path($d, $dep));
		# Bu listede TAM BOY dugme kullaniliyor: satirdaki dort eylem ayni
		# boyda duruyor ve satirin yuksek olmasi burada sorun degil.
		# (Kucuk cerceveli dugme isteniyorsa ui_link yeter - temanin onu
		# donusturdugu bicim o; karsilastirma tablosunda oyle.)
		# Repo yalnizca ilk cekmeden sonra olusuyor; ikisini de o zaman
		# gosteriyoruz.
		if ($dep->{'last_time'}) {
			push(@acts,
			     &ui_link_button("commits.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
					     $text{'act_commits'}),
			     &ui_link_button("deploylog.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
					     $text{'act_log'}));
			}
		push(@table, [
			# Adi duzenleme sayfasina baglamak Webmin'in kalibi:
			# satirin kimligi tiklanir, ayrica "Duzenle" dugmesi
			# gerekmez.
			&ui_link("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				 $dep->{'name'} || $dep->{'id'}),
			$dep->{'repo'},
			$dep->{'branch'},
			"<tt>".&html_escape(&deploy_target_dir($d, $dep))."</tt>",
			($dep->{'mode'} || 'manual') eq 'auto' ? $text{'mode_auto'}
							       : $text{'mode_manual'},
			$state,
			$last,
			join(" ", @acts),
			]);
		}
	print &ui_columns_table([ $text{'col_name'}, $text{'col_repo'},
				  $text{'col_branch'}, $text{'col_target'},
				  $text{'col_mode'}, $text{'col_state'},
				  $text{'col_last'}, "" ],
				100, \@table);
	}
else {
	print "<p><i>$text{'index_none'}</i></p>\n";
	}

# Sayfa altindaki eylemler: Webmin'in kalibi dugme + yaninda ne yaptigini
# anlatan aciklama (ui_buttons_row). Ikisi de bir sayfaya goturuyor, o yuzden
# form degil baglanti dugmesi.
print &ui_buttons_start();
print &ui_buttons_row("edit_deploy.cgi", $text{'index_add'},
		      $text{'index_add_desc'},
		      [ [ "dom", $d->{'id'} ], [ "new", 1 ] ], undef, undef, "get");
print &ui_buttons_row("sshkey.cgi", $text{'index_sshkey'},
		      $text{'index_sshkey_desc'},
		      [ [ "dom", $d->{'id'} ] ], undef, undef, "get");
print &ui_buttons_end();

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
