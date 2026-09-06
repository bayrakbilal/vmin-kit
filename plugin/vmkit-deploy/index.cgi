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

my @deps = &list_deploys($d);
if (@deps) {
	my @table;
	foreach my $dep (@deps) {
		my $last = $dep->{'last_time'}
			? ($dep->{'last_status'} eq 'ok' ? $text{'st_ok'}
							 : $text{'st_failed'}).
			  " - ".&make_date($dep->{'last_time'})
			: $text{'never'};
		my @acts = (
			"<a href='javascript:void(0)' onclick=\"vmkitRun('deploy.cgi?dom=".
			  $d->{'id'}."&id=".$dep->{'id'}."','".
			  &quote_escape($text{'deploy_running'})."',1)\">".
			  $text{'act_deploy'}."</a>",
			&ui_link("edit_deploy.cgi?dom=$d->{'id'}&id=$dep->{'id'}",
				 $text{'act_edit'}),
			);
		push(@acts,
			"<a href='javascript:void(0)' onclick=\"vmkitRun('deploylog.cgi?dom=".
			  $d->{'id'}."&id=".$dep->{'id'}."','".
			  &quote_escape($text{'act_log'})."',0)\">".
			  $text{'act_log'}."</a>")
			if ($dep->{'last_time'});
		push(@table, [
			$dep->{'name'} || $dep->{'id'},
			$dep->{'repo'},
			$dep->{'branch'},
			$dep->{'target'},
			$dep->{'mode'} eq 'auto' ? $text{'mode_auto'}
						 : $text{'mode_manual'},
			$last,
			&ui_links_row(\@acts),
			]);
		}
	print &ui_columns_table([ $text{'col_name'}, $text{'col_repo'},
				  $text{'col_branch'}, $text{'col_target'},
				  $text{'col_mode'}, $text{'col_last'},
				  "" ],
				100, \@table);
	}
else {
	print "<p><i>$text{'index_none'}</i></p>\n";
	}

print &ui_link("edit_deploy.cgi?dom=$d->{'id'}&new=1", $text{'index_add'}),
      "<br>\n";
print &ui_link("sshkey.cgi?dom=$d->{'id'}", $text{'index_sshkey'}),
      "<br>\n";

# ---- log penceresi ----
# Kendi kendine yeten basit bir modal: temanin ic yapisina bagli degil,
# renkleri acik/koyu temada da okunur olsun diye acikca veriliyor.
print <<"MODAL";
<div id="vmkitModal" style="display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.55);z-index:9999">
 <div style="max-width:900px;margin:5vh auto;background:#f5f5f5;color:#222;border-radius:6px;overflow:hidden;box-shadow:0 6px 30px rgba(0,0,0,.4)">
  <div id="vmkitModalTitle" style="padding:10px 14px;border-bottom:1px solid #ccc;font-weight:bold"></div>
  <pre id="vmkitModalLog" style="margin:0;padding:14px;max-height:60vh;overflow:auto;white-space:pre-wrap;background:#1b1b1b;color:#e8e8e8;font-size:12px;line-height:1.45"></pre>
  <div style="padding:10px 14px;text-align:right;border-top:1px solid #ccc">
   <button type="button" onclick="vmkitClose()">$text{'act_close'}</button>
  </div>
 </div>
</div>
<script>
var vmkitReload = 0;
function vmkitClose() {
  document.getElementById('vmkitModal').style.display = 'none';
  if (vmkitReload) { location.reload(); }
}
function vmkitRun(url, title, reload) {
  vmkitReload = 0;
  document.getElementById('vmkitModalTitle').textContent = title;
  document.getElementById('vmkitModalLog').textContent = '$text{'deploy_wait'}';
  document.getElementById('vmkitModal').style.display = 'block';
  fetch(url, { credentials: 'same-origin' })
    .then(function(r) { return r.text(); })
    .then(function(t) {
      document.getElementById('vmkitModalLog').textContent = t;
      vmkitReload = reload;
    })
    .catch(function(e) {
      document.getElementById('vmkitModalLog').textContent = '' + e;
    });
}
</script>
MODAL

&ui_print_footer("/virtual-server/summary_domain.cgi?dom=$d->{'id'}",
		 $text{'index_return'});
