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

# Islem dugmesi. Mutasyonlar POST ile gonderiliyor: bir baglantiya tiklamak
# ya da onu onbelleklemek kayit silmemeli.
my $btn = sub {
	my ($id, $act, $label) = @_;
	# Her dugme kendi formu; form blok eleman oldugu icin varsayilan olarak
	# alt alta diziliyorlar. inline-block ile yan yana duruyorlar.
	return &ui_form_start("action.cgi", "post", undef, "style='display:inline-block;margin-right:6px'").
	       &ui_hidden("dom", $d->{'id'}).
	       &ui_hidden("id", $id).
	       &ui_hidden("act", $act).
	       &ui_submit($label).
	       &ui_form_end();
	};

# Proxy hucresi: sutunun kendisi dugme. Bizim kayitlarimizda tiklayinca
# tersine cevirir; bizim olmayanlarda (tunel gibi) yalnizca durumu yazar.
# Proxy yalnizca A, AAAA ve CNAME icin gecerli.
my $proxy_cell = sub {
	my ($e) = @_;
	return "-" if ($e->{'type'} !~ /^(A|AAAA|CNAME)$/);
	my @cr = @{$e->{'crecs'}};
	if (!@cr) {
		# Kayit henuz yok: olusturuldugunda ne olacagini yaziyoruz.
		my $on = $cf->{'proxy'} &&
			 !&never_proxy(&record_label($d, $e->{'name'})) ? 1 : 0;
		return "<font size=-1>".
		       &text('proxy_new', $on ? $text{'proxy_on'} : $text{'proxy_off'}).
		       "</font>";
		}
	return join(" ", map {
		my $lbl = $_->{'proxied'} ? $text{'proxy_on'} : $text{'proxy_off'};
		&cf_is_ours($_) ? &$btn($_->{'id'}, 'proxy', $lbl) : $lbl;
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

	my ($state, $note, $out, $acts) = ("", "", 0, "");
	my $op = $e->{'op'};
	if    ($op eq 'create') { $state = $text{'st_willcreate'}; }
	elsif ($op eq 'delete') { $state = $text{'st_willdelete'}; }
	elsif ($op eq 'update') { $state = $text{'st_willupdate'}; }
	elsif ($op eq 'adopt')  { $state = $text{'st_willadopt'}; }
	elsif ($op eq 'none')   { $state = $text{'st_insync'}; }
	else {
		# skip: kapsam disi. Neden oldugu 'why' alaninda.
		$out = 1;
		if ($e->{'why'} eq 'cnameclash') {
			($state, $note) = ($text{'st_blocked'}, $text{'st_cnameclash'});
			$acts = &$btn($e->{'blocker'}->{'id'}, 'delete',
				      $text{'act_delcname'});
			}
		elsif ($e->{'why'} eq 'notours') {
			$state = $text{'st_notours'};
			# Proxy'li kayitlara dugme YOK: tipik ornek Cloudflare
			# tuneli; icerigi yerel zone'da anlamsiz, silinmesi
			# calisan bir kurulumu bozar.
			$acts = join(" ", map {
				$_->{'proxied'} ? "" :
					&$btn($_->{'id'}, 'import', $text{'act_import'}).
					&$btn($_->{'id'}, 'delete', $text{'act_delete'})
				} @cr);
			}
		else {
			($state, $note) = ($text{'st_conflict'}, $text{'st_conflict_note'});
			$acts = join(" ", map {
				$_->{'proxied'} ? "" :
					&$btn($_->{'id'}, 'adopt', $text{'act_adopt'}).
					&$btn($_->{'id'}, 'import', $text{'act_import'})
				} @cr);
			}
		# Dugme cikmamasinin sebebini not olarak acikla.
		$note = $text{'st_proxied2'} if (!$acts && $e->{'proxied'});
		}

	# Not, ayri bir sutun yerine durumun basindaki uyari simgesinde:
	# ilk tabloda not hic olmuyordu, ikincide uzun metin satiri sisiriyordu.
	my $scell = $note
		? "<span title=\"".&quote_escape($note)."\">&#9888;</span> ".$state
		: $state;
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
