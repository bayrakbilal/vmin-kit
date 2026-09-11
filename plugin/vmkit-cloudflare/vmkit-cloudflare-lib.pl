# vmkit-cloudflare helper functions.
#
# Design: the local BIND zone is the MODEL, Cloudflare is the PUBLISHED copy.
# Virtualmin already generates and maintains the records correctly (www, MX,
# SPF, DKIM, A records of sub-domains); we push that zone to Cloudflare. SOA
# and NS are not sent - Cloudflare owns those.
#
# Trigger: a background service watching the zone files. Every change bumps the
# SOA serial (post_records_change in feature-dns.pl), so a changed zone file
# really does mean something changed. Virtualmin's DNS code path has NO plugin
# hook, which makes watching files the most reliable method. The service
# (systemd .path + .timer + .service) is installed and checked by this module
# itself - see the "automatic sync service" section at the end of this file.
#
# Settings are kept PER DOMAIN. There is no global token: each domain may live
# in a different Cloudflare account, and a token is account/zone scoped.
#   /etc/webmin/vmkit-cloudflare/domains/<domain-id>
# The files are 0600 because they contain a token.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, $module_name, $module_config_directory,
     $module_root_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

sub domains_dir
{
return "$module_config_directory/domains";
}

sub domain_file
{
my ($d) = @_;
return &domains_dir()."/$d->{'id'}";
}

# ---------------------------------------------------------------------------
# STORING THE TOKEN ON DISK
#
# THIS IS NOT A SECURITY LAYER, IT IS OBFUSCATION. The key sits below in the
# plugin's source, so anyone reading the code can undo it. That is deliberate:
# the token belongs to the domain's owner anyway, we are not hiding it from
# them.
#
# The aim is to reduce the places the token sits in PLAIN TEXT:
#   - Virtualmin's domain backup (a backup file can change hands)
#   - /etc backups
#   - etckeeper: /etc is a git repository, so every change is written to
#     HISTORY as well
#   - file contents pasted around while debugging
# Whoever ends up with a backup sees a meaningless hex string, which is enough.
#
# Format:  v1:<hex>   ->  hex = 8 byte salt + the token XORed with a key stream
#                         derived from that salt
# WITHOUT the prefix the value is plain text (older records); it is returned as
# it is and moves to the encoded form by itself on the next save_cf.
#
# Hex rather than base64: even Webmin loads MIME::Base64 optionally with
# 'eval "use ..."', while unpack("H*") needs nothing. The token is short, so
# doubling its size does not matter.
# ---------------------------------------------------------------------------

# Fixed key. Changing it makes EXISTING RECORDS UNREADABLE - do not change it.
sub obf_secret
{
return 'vmkit-cloudflare/v1/8c1f4a6b2e9d70335af8c264d1b0e97a';
}

# Digest::SHA is part of core Perl but Webmin itself does not use it, so its
# presence cannot be assumed. Without it we fall back to Digest::MD5, and
# without that to nothing at all: the token is written in plain text as before
# and the module keeps working. Falling back quietly beats breaking quietly.
my $obf_digest;
sub obf_digest_kind
{
return $obf_digest if (defined($obf_digest));
if (eval { require Digest::SHA; 1 })    { $obf_digest = 'sha'; }
elsif (eval { require Digest::MD5; 1 }) { $obf_digest = 'md5'; }
else                                    { $obf_digest = ''; }
return $obf_digest;
}

sub obf_hash
{
my ($data) = @_;
my $k = &obf_digest_kind();
return $k eq 'sha' ? Digest::SHA::sha256($data) :
       $k eq 'md5' ? Digest::MD5::md5($data) : undef;
}

# A key stream of the requested length: hash(key + salt + counter) blocks.
sub obf_stream
{
my ($salt, $len) = @_;
my ($out, $i) = ("", 0);
while (length($out) < $len) {
	$out .= &obf_hash(&obf_secret().$salt.pack("N", $i));
	$i++;
	}
return substr($out, 0, $len);
}

sub obf_encrypt
{
my ($plain) = @_;
return $plain if (!defined($plain) || $plain eq '');
return $plain if (!&obf_digest_kind());
# A fresh salt per record, so one token does not produce the same hex on two
# domains.
my $salt = '';
if (open(my $RND, "<", "/dev/urandom")) {
	binmode($RND);
	read($RND, $salt, 8);
	close($RND);
	}
if (!defined($salt) || length($salt) != 8) {
	$salt = '';
	$salt .= chr(int(rand(256))) for (1..8);
	}
my $ct = $plain ^ &obf_stream($salt, length($plain));
return "v1:".unpack("H*", $salt.$ct);
}

sub obf_decrypt
{
my ($v) = @_;
return $v if (!defined($v) || $v !~ /^v1:([0-9a-f]+)$/);
# Prefixed but no module to decode it: return empty. Better than sending a
# wrong string to Cloudflare as if it were the token.
return "" if (!&obf_digest_kind());
my $raw = pack("H*", $1);
return "" if (length($raw) <= 8);
my $salt = substr($raw, 0, 8);
my $ct   = substr($raw, 8);
return $ct ^ &obf_stream($salt, length($ct));
}

# get_cf(&domain) -> the settings hash, or the defaults
sub get_cf
{
my ($d) = @_;
my %cf;
&read_file(&domain_file($d), \%cf);
# Encoded on disk, plain in memory: the caller always sees a usable token.
# Older (unprefixed) records come back as they are.
$cf{'token'} = &obf_decrypt($cf{'token'}) if (defined($cf{'token'}));
$cf{'proxy'} = 0 if (!defined($cf{'proxy'}));
# Automatic sync is ON by default, and a missing key (older records) counts as
# on so the behaviour does not change under them.
$cf{'enabled'} = 1 if (!defined($cf{'enabled'}));
return \%cf;
}

# save_cf(&domain, &cf)
sub save_cf
{
my ($d, $cf) = @_;
my $dir = &domains_dir();
-d $dir || &make_dir($dir, 0700, 1);
my $file = &domain_file($d);
# Work on a COPY: polluting the caller's hash with the encoded value would
# break code that uses the token again in the same request (cf_zone_id, for
# instance, saves first and then calls the API).
my %out = %$cf;
$out{'token'} = &obf_encrypt($out{'token'}) if (defined($out{'token'}));
&lock_file($file);
&write_file($file, \%out);
&unlock_file($file);
# The token is a secret.
chmod(0600, $file);
}

# delete_cf(&domain)
sub delete_cf
{
my ($d) = @_;
my $file = &domain_file($d);
&lock_file($file);
unlink($file);
&unlock_file($file);
}

# can_edit_domain(&domain)
# Virtualmin's own check: root may edit every domain, an owner only their own.
sub can_edit_domain
{
my ($d) = @_;
return &virtual_server::can_edit_domain($d);
}

# The masked form of the token, for display.
sub masked_token
{
my ($t) = @_;
return '' if (!$t);
return length($t) <= 8 ? ('*' x length($t))
		       : substr($t, 0, 4).('*' x 8).substr($t, -4);
}

# The domain's status for display. It does NOT call the API: it reads what the
# last sync left behind, so opening a page makes no request to Cloudflare.
sub zone_status
{
my ($d) = @_;
my $cf = &get_cf($d);
return $text{'status_notoken'} if (!$cf->{'token'});

# Disk holds a CODE ('ok' / 'partial'), not translated text: when the language
# changed, older records still showed the old one. The translation happens here,
# at display time. An unrecognised value (a sentence left by an older version)
# counts as "unknown" and fixes itself on the first sync.
my $st = $cf->{'last_status'} || '';
return $text{'status_ok'}      if ($st eq 'ok');
return $text{'status_partial'} if ($st eq 'partial');
return $text{'status_unknown'};
}

# ---- Cloudflare API ------------------------------------------------------
# The token NEVER goes on a command line: argv is visible to every user through
# /proc. Webmin's own HTTP client is used and the token travels in a header.
sub cf_api_get
{
my ($d, $path) = @_;
my $cf = &get_cf($d);
return (undef, $text{'err_notoken'}) if (!$cf->{'token'});
my ($out, $err);
my %headers = ( 'Authorization' => 'Bearer '.$cf->{'token'},
		'Accept'        => 'application/json' );
&http_download("api.cloudflare.com", 443, "/client/v4".$path, \$out, \$err,
	       undef, 1, undef, undef, 30, 0, 0, \%headers);
return (undef, $err) if ($err);
my $json = eval { &convert_from_json($out) };
return (undef, $text{'err_badjson'}) if ($@ || !ref($json));
if (!$json->{'success'}) {
	my @m = map { $_->{'message'} } @{$json->{'errors'} || []};
	return (undef, @m ? join("; ", @m) : $text{'err_apifail'});
	}
return ($json, undef);
}

# cf_zone_id(&domain) -> (zone-id, error)
# The id found is stored in the domain's record rather than looked up again.
sub cf_zone_id
{
my ($d) = @_;
my $cf = &get_cf($d);
return ($cf->{'zone_id'}, undef) if ($cf->{'zone_id'});
my ($json, $err) = &cf_api_get($d, "/zones?name=".&urlize($d->{'dom'}));
return (undef, $err) if ($err);
my $z = $json->{'result'}->[0];
return (undef, &text('err_nozone', $d->{'dom'})) if (!$z);
$cf->{'zone_id'} = $z->{'id'};
&save_cf($d, $cf);
return ($z->{'id'}, undef);
}

# cf_records(&domain) -> (\@records, error)
# Pagination is followed so zones with more than 100 records arrive complete.
sub cf_records
{
my ($d) = @_;
my ($zid, $err) = &cf_zone_id($d);
return (undef, $err) if ($err);
my @rv;
my $page = 1;
while(1) {
	my ($json, $err) = &cf_api_get($d,
		"/zones/$zid/dns_records?per_page=100&page=$page");
	return (undef, $err) if ($err);
	push(@rv, @{$json->{'result'}});
	my $ri = $json->{'result_info'} || {};
	last if (!$ri->{'total_pages'} || $page >= $ri->{'total_pages'});
	$page++;
	}
return (\@rv, undef);
}

# ---- record matching -----------------------------------------------------
# The types we send to Cloudflare. SOA and NS are deliberately absent:
# Cloudflare owns those and the local zone's values are not pushed.
sub synced_types
{
return ( "A", "AAAA", "CNAME", "MX", "TXT", "SRV", "CAA" );
}

# How records we created are marked. Nothing without the tag is ever touched,
# which keeps Cloudflare tunnels, Email Routing MX records and anything added
# by hand safe.
sub cf_tag
{
return "vmkit";
}

sub cf_is_ours
{
my ($r) = @_;
return ($r->{'comment'} || '') eq &cf_tag() ? 1 : 0;
}

# Names NOT sent to Cloudflare. They stay in the zone, they just do not go into
# the published copy.
#
# ns1/ns2: the local zone is always generated on the "we manage NS" model, so
# it carries A records for our own nameserver pair. When delegation lives at
# Cloudflare those records have no business in the published copy.
sub skip_name
{
my ($label) = @_;
return $label =~ /^ns\d*$/ ? 1 : 0;
}

# The record's label relative to the domain: ns1.example.com -> ns1,
# example.com -> @
sub record_label
{
my ($d, $name) = @_;
my $dom = lc($d->{'dom'});
my $lc = lc($name);
$lc =~ s/\.$//;
return '@' if ($lc eq $dom);
return $1 if ($lc =~ /^(.*)\.\Q$dom\E$/);
return $lc;
}

# Names that must not be proxied even when the proxy preference is ON.
# Cloudflare's proxy only carries HTTP/HTTPS; proxying mail and autoconfig
# names breaks SMTP/IMAP connections and client discovery. A record the user
# proxies by hand is left alone - this list only applies while WE create a
# record.
#
# The list comes from the configuration but the default lives IN CODE:
# upgrading the module does not add new keys to an existing config file
# (update-plugins.sh only copies it when absent), so the setting can arrive
# empty and the old behaviour has to continue unchanged.
sub never_proxy_names
{
my $v = $config{'never_proxy'};
$v = 'mail smtp imap pop pop3 mta-sts autoconfig autodiscover'
	if (!defined($v) || $v !~ /\S/);
my @rv = grep { /\S/ } split(/[\s,]+/, lc($v));
return @rv;
}

sub never_proxy
{
my ($label) = @_;
my $l = lc($label);
foreach my $n (&never_proxy_names()) {
	return 1 if ($l eq $n);
	}
return 0;
}

# local_records(&domain) -> [ { name, type, value, ttl } ]
# From the local BIND zone, limited to the types we send.
sub local_records
{
my ($d) = @_;
my %ok = map { $_, 1 } &synced_types();
my @rv;
foreach my $r (&virtual_server::get_domain_dns_records($d)) {
	# Webmin's bind8 parser labels some TXT records by MEANING and returns
	# them as separate types, SPF and DMARC. In the zone file both are TXT,
	# and at Cloudflare they must be TXT too - it has no SPF or DMARC record
	# type. Without this mapping those two records are never synced: they
	# fail the type list and are dropped silently.
	my $type = uc($r->{'type'});
	$type = "TXT" if ($type eq "SPF" || $type eq "DMARC");
	next if (!$ok{$type});
	my $name = $r->{'name'};
	$name =~ s/\.$//;
	next if (&skip_name(&record_label($d, $name)));
	push(@rv, { 'name'  => lc($name),
		    'type'  => $type,
		    'value' => join(" ", @{$r->{'values'}}),
		    'ttl'   => $r->{'ttl'} });
	}
return @rv;
}

# norm_value(type, value) -> a comparable form
# BIND and Cloudflare write the same record differently: BIND adds a trailing
# dot and keeps TXT values in quotes, Cloudflare does neither.
#
# TXT and quotes: values are sent to Cloudflare unquoted as well. The
# documentation says Cloudflare adds the quotes itself when a value is stored
# without them; sending quoted values risks a doubly quoted ""value"" if
# Cloudflare does not notice.
#
# BIND splits TXT values longer than 255 characters into quoted chunks
# ("aaa" "bbb"). The first substitution below rejoins them - without it DKIM
# keys would be sent truncated.
sub norm_value
{
my ($type, $v) = @_;
$v = '' if (!defined($v));
$v =~ s/^\s+//; $v =~ s/\s+$//;
if ($type eq 'TXT') {
	# Rejoin the quoted chunks BIND splits long TXT values into.
	$v =~ s/"\s+"//g;
	$v =~ s/^"//; $v =~ s/"$//;
	return $v;
	}
if ($type eq 'CAA') {
	# Webmin's bind8 parser strips the quotes from a CAA value while
	# Cloudflare returns them. Without levelling this the record would look
	# "different" on every sync and be rewritten.
	$v =~ s/"//g;
	$v =~ s/\s+/ /g;
	return lc($v);
	}
$v =~ s/\.$//;
return lc($v);
}

# cf_value(&cf-record) -> a comparable value
# For MX the priority arrives in its own field; in BIND it is part of the value.
sub cf_value
{
my ($r) = @_;
my $t = uc($r->{'type'});
my $dt = $r->{'data'};
return &norm_value($t, $r->{'priority'}." ".$r->{'content'}) if ($t eq 'MX');
# For SRV and CAA the parts live in 'data'; 'content' alone is incomplete or
# formatted differently, so the value is built from 'data' when it is there.
if ($t eq 'SRV' && ref($dt) && defined($dt->{'target'})) {
	return &norm_value($t, join(" ", $dt->{'priority'}, $dt->{'weight'},
					 $dt->{'port'}, $dt->{'target'}));
	}
if ($t eq 'CAA' && ref($dt) && defined($dt->{'value'})) {
	return &norm_value($t, join(" ", $dt->{'flags'}, $dt->{'tag'},
					 $dt->{'value'}));
	}
return &norm_value($t, $r->{'content'});
}

# short_value(value) -> shortened when long, the whole value in the title
# Very long TXT values such as DKIM keys otherwise break the table.
sub short_value
{
my ($v, $max) = @_;
# 40 characters: the table has seven columns and long values bloated the
# rows. The full value is in the title, visible on hover.
$max ||= 40;
return &html_escape($v) if (length($v) <= $max);
return "<span title=\"".&quote_escape($v)."\">".
       &html_escape(substr($v, 0, $max))."...</span>";
}

# cf_api_req(&domain, method, path, [body-hashref]) -> (json, error)
# Works for methods other than GET too. The token still travels only in a
# header: never on a command line or in a temporary file.
sub cf_api_req
{
my ($d, $method, $path, $data) = @_;
my $cf = &get_cf($d);
return (undef, $text{'err_notoken'}) if (!$cf->{'token'});

my $host = "api.cloudflare.com";
my $body = defined($data) ? &convert_to_json($data) : undef;
my @headers = ( [ "Host", $host ],
		[ "User-Agent", "vmkit" ],
		[ "Authorization", "Bearer ".$cf->{'token'} ],
		[ "Accept", "application/json" ] );
if (defined($body)) {
	push(@headers, [ "Content-Type", "application/json" ],
		       [ "Content-Length", length($body) ]);
	}

my $h = &make_http_connection($host, 443, 1, $method, "/client/v4".$path,
			      \@headers);
return (undef, ref($h) ? $text{'err_apifail'} : ($h || $text{'err_apifail'}))
	if (!ref($h));
&write_http_connection($h, $body) if (defined($body));

my ($out, $err);
&complete_http_download($h, \$out, \$err, undef, 0, $host, 443, \@headers,
			1, 1, 30);
# Cloudflare returns JSON on errors too, so the body is decoded first and the
# real reason shown instead of "400 Bad Request".
my $json = eval { &convert_from_json($out) };
if (!$@ && ref($json)) {
	return ($json, undef) if ($json->{'success'});
	my @m = map { $_->{'message'} } @{$json->{'errors'} || []};
	return (undef, @m ? join("; ", @m) : $text{'err_apifail'});
	}
return (undef, $err || $text{'err_badjson'});
}

# ---- operations -----------------------------------------------------------

# cf_to_bind(&cf-record) -> (\@values, error)
# Converts a Cloudflare record into the value list BIND expects. It differs per
# type: MX carries the priority in its own field, SRV and CAA keep their parts
# in 'data'.
sub cf_to_bind
{
my ($r) = @_;
my $t = uc($r->{'type'});
my $dt = $r->{'data'} || { };
my $dot = sub { my ($v) = @_; $v .= "." if ($v !~ /\.$/); return $v; };
return ([ $r->{'content'} ], undef)                    if ($t eq 'A');
return ([ $r->{'content'} ], undef)                    if ($t eq 'AAAA');
return ([ &$dot($r->{'content'}) ], undef)             if ($t eq 'CNAME');
return ([ $r->{'content'} ], undef)                    if ($t eq 'TXT');
return ([ $r->{'priority'}, &$dot($r->{'content'}) ], undef) if ($t eq 'MX');
if ($t eq 'SRV' && defined($dt->{'target'})) {
	return ([ $dt->{'priority'}, $dt->{'weight'}, $dt->{'port'},
		  &$dot($dt->{'target'}) ], undef);
	}
if ($t eq 'CAA' && defined($dt->{'value'})) {
	return ([ $dt->{'flags'}, $dt->{'tag'}, '"'.$dt->{'value'}.'"' ], undef);
	}
return (undef, $text{'err_noconv'});
}

# cf_find_record(&domain, record-id) -> (&record, error)
sub cf_find_record
{
my ($d, $id) = @_;
my ($recs, $err) = &cf_records($d);
return (undef, $err) if ($err);
my ($r) = grep { $_->{'id'} eq $id } @$recs;
return (undef, $text{'err_norec'}) if (!$r);
return ($r, undef);
}

# cf_tag_record(&domain, &record) -> error
# Takes a record under our tag; from then on the sync manages it.
sub cf_tag_record
{
my ($d, $r) = @_;
my ($zid, $err) = &cf_zone_id($d);
return $err if ($err);
(undef, $err) = &cf_api_req($d, "PATCH",
	"/zones/$zid/dns_records/$r->{'id'}", { 'comment' => &cf_tag() });
return $err;
}

# cf_set_proxy(&domain, &cfrecord, 1|0)
# Changes one record's proxy state. Only meaningful for A, AAAA and CNAME;
# Cloudflare does not accept the field on other types.
sub cf_set_proxy
{
my ($d, $r, $on) = @_;
my ($zid, $err) = &cf_zone_id($d);
return $err if ($err);
return $text{'err_noproxytype'}
	if (uc($r->{'type'}) !~ /^(A|AAAA|CNAME)$/);
my ($out, $e) = &cf_api_req($d, "PATCH",
			    "/zones/$zid/dns_records/$r->{'id'}",
			    { 'proxied' => $on ? \1 : \0 });
return $e;
}

# cf_delete_record(&domain, &record) -> error
sub cf_delete_record
{
my ($d, $r) = @_;
my ($zid, $err) = &cf_zone_id($d);
return $err if ($err);
(undef, $err) = &cf_api_req($d, "DELETE",
	"/zones/$zid/dns_records/$r->{'id'}");
return $err;
}

# import_record(&domain, &cf-record) -> error
# Writes the record into the local BIND zone. Virtualmin's own functions are
# used rather than the CLI: 'modify-dns --add-record' splits the value on
# whitespace, which would corrupt any TXT record containing a space.
sub import_record
{
my ($d, $r) = @_;
my ($vals, $err) = &cf_to_bind($r);
return $err if ($err);
my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
return $text{'err_nozonefile'} if (!$file);
my $name = $r->{'name'};
$name .= "." if ($name !~ /\.$/);
# At Cloudflare ttl=1 means "automatic", not a number to pass to BIND.
my $ttl = ($r->{'ttl'} && $r->{'ttl'} != 1) ? $r->{'ttl'} : undef;
&virtual_server::create_dns_record($recs, $file,
	{ 'name'   => $name,
	  'type'   => uc($r->{'type'}),
	  'class'  => 'IN',
	  'ttl'    => $ttl,
	  'values' => $vals });
my $perr = &virtual_server::post_records_change($d, $recs, $file);
return $perr if ($perr);
return undef;
}

# ---- the sync plan ---------------------------------------------------------
# The SINGLE source of the comparison. Both the preview page and the sync
# engine use it; classifying separately, the table could show one thing while
# the engine did another.
#
# Each entry: name, type, lvals, crecs, cvals, op, why
#   op: create | update | delete | adopt | none | skip
sub sync_plan
{
my ($d) = @_;
my ($cfrecs, $err) = &cf_records($d);
return (undef, $err) if ($err);

my (%lg, %cg, %cfcname);
foreach my $r (&local_records($d)) {
	push(@{$lg{lc($r->{'name'})."|".$r->{'type'}}}, $r);
	}
foreach my $r (@$cfrecs) {
	push(@{$cg{lc($r->{'name'})."|".uc($r->{'type'})}}, $r);
	# While a name holds a CNAME, Cloudflare accepts no other type on it.
	$cfcname{lc($r->{'name'})} = $r if (uc($r->{'type'}) eq 'CNAME');
	}

my %allk = map { $_ => 1 } (keys %lg, keys %cg);
my @plan;
foreach my $k (sort keys %allk) {
	my ($n, $t) = split(/\|/, $k, 2);
	my @lr = @{$lg{$k} || [ ]};
	my @cr = @{$cg{$k} || [ ]};
	my @lv = map { &norm_value($t, $_->{'value'}) } @lr;
	my @cv = map { &cf_value($_) } @cr;
	my $ours    = @cr && !(grep { !&cf_is_ours($_) } @cr);
	my $proxied = (grep { $_->{'proxied'} } @cr) ? 1 : 0;
	my $same    = join("\n", sort @lv) eq join("\n", sort @cv);

	my $e = { 'name' => $n, 'type' => $t, 'lvals' => \@lv,
		  'crecs' => \@cr, 'cvals' => \@cv, 'lttl' => $lr[0]->{'ttl'},
		  'ours' => $ours, 'proxied' => $proxied };
	# Proxying is NOT a reason to skip: ownership decides who manages a
	# record, and what protects a tunnel is ownership ('notours'), not the
	# proxy flag. Proxying is only displayed, and preserved on update.
	if (@lv && !@cr) {
		if ($t ne 'CNAME' && $cfcname{$n}) {
			$e->{'op'} = 'skip'; $e->{'why'} = 'cnameclash';
			$e->{'blocker'} = $cfcname{$n};
			}
		else { $e->{'op'} = 'create'; }
		}
	elsif (!@lv && @cr) {
		if ($ours) { $e->{'op'} = 'delete'; }
		else { $e->{'op'} = 'skip'; $e->{'why'} = 'notours'; }
		}
	elsif ($same) {
		$e->{'op'} = $ours ? 'none' : 'adopt';
		}
	else {
		if ($ours) { $e->{'op'} = 'update'; }
		else { $e->{'op'} = 'skip'; $e->{'why'} = 'conflict'; }
		}
	push(@plan, $e);
	}
return (\@plan, undef);
}

# cf_body(name, type, value, ttl, proxy) -> a Cloudflare record body
# MX priority, and the SRV and CAA parts, go into separate fields.
sub cf_body
{
my ($name, $type, $value, $ttl, $proxy) = @_;
# At Cloudflare ttl=1 means "automatic", used when the local record has none.
my %r = ( 'type' => $type, 'name' => $name,
	  'ttl' => ($ttl && $ttl >= 60 ? int($ttl) : 1),
	  'comment' => &cf_tag() );
if ($type eq 'MX') {
	return undef if ($value !~ /^(\d+)\s+(\S+)$/);
	$r{'priority'} = int($1);
	$r{'content'}  = $2;
	}
elsif ($type eq 'SRV') {
	my @p = split(/\s+/, $value);
	return undef if (@p != 4);
	$r{'data'} = { 'priority' => int($p[0]), 'weight' => int($p[1]),
		       'port' => int($p[2]), 'target' => $p[3] };
	}
elsif ($type eq 'CAA') {
	my @p = split(/\s+/, $value, 3);
	return undef if (@p != 3);
	my $v = $p[2];
	$v =~ s/^"//; $v =~ s/"$//;
	$r{'data'} = { 'flags' => int($p[0]), 'tag' => $p[1], 'value' => $v };
	}
else {
	$r{'content'} = $value;
	}
# Proxying applies to A, AAAA and CNAME only; the field is not sent otherwise.
if ($type eq 'A' || $type eq 'AAAA' || $type eq 'CNAME') {
	$r{'proxied'} = $proxy ? \1 : \0;
	}
return \%r;
}

# run_sync(&domain, &callback) -> (success?, error)
# Applies the operations in the plan, handing every line to the callback so the
# page can show what was done one item at a time.
sub run_sync
{
my ($d, $cb) = @_;
my ($plan, $err) = &sync_plan($d);
return (0, $err) if ($err);
my ($zid, $zerr) = &cf_zone_id($d);
return (0, $zerr) if ($zerr);
my $cf = &get_cf($d);
my $base = "/zones/$zid/dns_records";
my $ok = 1;
my $n = 0;

foreach my $e (@$plan) {
	my $op = $e->{'op'};
	next if ($op eq 'none' || $op eq 'skip');
	my $what = $e->{'name'}." ".$e->{'type'};

	if ($op eq 'adopt') {
		# The value already matches; only the tag is added.
		foreach my $r (@{$e->{'crecs'}}) {
			next if (&cf_is_ours($r));
			my (undef, $aerr) = &cf_api_req($d, "PATCH",
				"$base/$r->{'id'}", { 'comment' => &cf_tag() });
			$n++;
			&$cb($aerr ? &text('sync_efail', $what, $aerr)
				   : &text('sync_adopted', $what));
			$ok = 0 if ($aerr);
			}
		next;
		}

	if ($op eq 'delete') {
		foreach my $r (@{$e->{'crecs'}}) {
			my (undef, $derr) = &cf_api_req($d, "DELETE",
							"$base/$r->{'id'}");
			$n++;
			&$cb($derr ? &text('sync_efail', $what, $derr)
				   : &text('sync_deleted', $what));
			$ok = 0 if ($derr);
			}
		next;
		}

	# create and update: local values are matched one to one against the
	# Cloudflare records. Surplus records are deleted, missing ones created.
	# Deleting everything and recreating would be simpler but would leave a
	# window in which the record does not exist at all.
	my @lv = @{$e->{'lvals'}};
	my @cr = @{$e->{'crecs'}};
	my $max = @lv > @cr ? @lv : @cr;
	for(my $i = 0; $i < $max; $i++) {
		if ($i < @lv && $i < @cr) {
			# An existing record's proxy state is NOT touched, so a
			# preference set by hand is not undone.
			my $body = &cf_body($e->{'name'}, $e->{'type'}, $lv[$i],
					    $e->{'lttl'}, $cr[$i]->{'proxied'});
			if (!$body) { &$cb(&text('sync_ebody', $what)); $ok = 0; next; }
			my (undef, $uerr) = &cf_api_req($d, "PUT",
					"$base/$cr[$i]->{'id'}", $body);
			$n++;
			&$cb($uerr ? &text('sync_efail', $what, $uerr)
				   : &text('sync_updated', $what, $lv[$i]));
			$ok = 0 if ($uerr);
			}
		elsif ($i < @lv) {
			# A new record: the default proxy preference applies
			# here, except for mail names (never_proxy).
			my $px = $cf->{'proxy'} &&
				 !&never_proxy(&record_label($d, $e->{'name'}))
					? 1 : 0;
			my $body = &cf_body($e->{'name'}, $e->{'type'}, $lv[$i],
					    $e->{'lttl'}, $px);
			if (!$body) { &$cb(&text('sync_ebody', $what)); $ok = 0; next; }
			my (undef, $cerr) = &cf_api_req($d, "POST", $base, $body);
			$n++;
			&$cb($cerr ? &text('sync_efail', $what, $cerr)
				   : &text('sync_created', $what, $lv[$i]));
			$ok = 0 if ($cerr);
			}
		else {
			my (undef, $derr) = &cf_api_req($d, "DELETE",
					"$base/$cr[$i]->{'id'}");
			$n++;
			&$cb($derr ? &text('sync_efail', $what, $derr)
				   : &text('sync_deleted', $what));
			$ok = 0 if ($derr);
			}
		}
	}

&$cb($text{'sync_nothing'}) if (!$n);
# A code is stored, not text - zone_status does the translation.
$cf->{'last_status'} = $ok ? "ok" : "partial";
$cf->{'last_time'} = time();
&save_cf($d, $cf);
return ($ok, undef);
}

# zone_mtime(&domain) -> the zone file's modification time, or 0
# This is the signal that triggers a sync. On every DNS change Virtualmin bumps
# the SOA serial and rewrites the file, so a changed mtime really does mean
# something changed.
sub zone_mtime
{
my ($d) = @_;
my $file = eval { &virtual_server::get_domain_dns_file($d) };
return 0 if ($@ || !$file);
# When BIND runs under a chroot the real path differs: Virtualmin gives the
# file's name as seen INSIDE the chroot while we stat it from outside. The
# helper for this is bind8::make_chroot - the same one used to find the
# watched directory (see zone_watch_dirs).
#
# bind8 is loaded HERE: it is not loaded at the top of the module, only
# requested inside zone_watch_dirs, and zone_mtime can be called before that.
# All of it sits in an eval because this function runs on every sync check and
# must never die; if the chroot cannot be resolved the unchrooted path is used.
eval {
	local $main::error_must_die = 1;
	&foreign_require("bind8");
	$file = &bind8::make_chroot($file);
	};
my @st = stat($file);
return @st ? $st[9] : 0;
}

# needs_sync(&domain) -> has the zone changed since the last sync?
sub needs_sync
{
my ($d) = @_;
my $cf = &get_cf($d);
return 0 if (!$cf->{'token'});
my $m = &zone_mtime($d);
return 0 if (!$m);
return ($cf->{'synced_mtime'} || 0) < $m ? 1 : 0;
}

# mark_synced(&domain)
sub mark_synced
{
my ($d) = @_;
my $cf = &get_cf($d);
$cf->{'synced_mtime'} = &zone_mtime($d);
&save_cf($d, $cf);
}

# sync_domains() -> the domains taking part in AUTOMATIC sync: the feature on,
# a token present, and automatic sync not switched off.
#
# 'enabled' only stops the automatic path (path/timer -> sync-all.pl); the
# panel's "Sync now" button keeps working, because that is an explicit user
# action. The token is not deleted: switching back on is one click.
sub sync_domains
{
my @rv;
foreach my $d (&virtual_server::list_domains()) {
	next if (!$d->{'vmkit-cloudflare'});
	my $cf = &get_cf($d);
	next if (!$cf->{'token'} || !$cf->{'enabled'});
	push(@rv, $d);
	}
return @rv;
}


# ---- the automatic sync service -------------------------------------------
# THIS MODULE generates and manages the units. They used to be created by
# install-plugins.sh, which meant that installing the module the standard way
# (as a .wbm.gz) never installed the service at all. There is one source now,
# called from three places:
#   postinstall.pl   when the module is installed (Webmin's standard hook)
#   feature_setup    when the feature is enabled on a domain
#   index.cgi        every time the page is opened - it restarts a stopped unit
#
# The units:
#   .path     triggers a sync the moment the zone file changes (the real
#             trigger)
#   .timer    every 15 minutes - a safety net for a missed event or a failed
#             run
#   .service  the one-shot job both of them start

sub sync_service
{
return "vmkit-cloudflare-sync";
}

sub sync_unit_dir
{
return "/etc/systemd/system";
}

# Is systemd running? If not, nothing is installed and the panel says so,
# rather than failing silently.
sub have_systemd
{
return &has_command("systemctl") && -d "/run/systemd/system" ? 1 : 0;
}

# systemctl(args...) -> (success?, output)
sub systemctl
{
my @args = @_;
my $cmd = "systemctl ".join(" ", map { quotemeta($_) } @args)." 2>&1 </dev/null";
my $out = &backquote_command($cmd);
return ($? ? 0 : 1, $out);
}

# The zone directory to watch. Nothing is guessed: a .path unit watching a
# directory that does not exist fails. BIND's own configuration is consulted
# first, then the two common locations.
sub zone_watch_dirs
{
my @dirs;
eval {
	local $main::error_must_die = 1;
	&foreign_require("bind8");
	my %bconfig = &foreign_config("bind8");
	my $base = $bconfig{'master_dir'} ||
		   &bind8::base_directory(&bind8::get_config());
	push(@dirs, &bind8::make_chroot($base)) if ($base);
	};
push(@dirs, "/var/lib/bind", "/var/cache/bind");
my %seen;
return grep { -d $_ && !$seen{$_}++ } @dirs;
}

# sync_unit_files() -> ( file name => the content it should have )
# Installation and checking generate the same text, which is what makes the
# "has it changed" comparison reliable. Without a zone directory no .path unit
# is generated.
sub sync_unit_files
{
my $svc = &sync_service();
my $exec = "$module_root_directory/sync-all.pl";
my %f;

$f{$svc.".service"} =
"[Unit]\n".
"Description=VminKit Cloudflare DNS sync\n".
"After=network-online.target bind9.service\n".
"Wants=network-online.target\n".
"\n".
"[Service]\n".
"Type=oneshot\n".
"# When the zone has not changed the script exits without any API call.\n".
"ExecStart=$exec\n".
"# NO delay: in DNS-01 validation the challenge record has to reach\n".
"# Cloudflare within seconds.\n".
"Nice=10\n";

$f{$svc.".timer"} =
"[Unit]\n".
"Description=VminKit Cloudflare DNS sync (safety net)\n".
"\n".
"[Timer]\n".
"# The real trigger is the .path unit, which fires the moment the zone\n".
"# file changes. This timer only catches a missed event or a failed run.\n".
"OnBootSec=3min\n".
"OnUnitActiveSec=15min\n".
"AccuracySec=1min\n".
"Unit=$svc.service\n".
"\n".
"[Install]\n".
"WantedBy=timers.target\n";

my @wd = &zone_watch_dirs();
if (@wd) {
	$f{$svc.".path"} =
	"[Unit]\n".
	"Description=VminKit Cloudflare DNS sync on zone change\n".
	"\n".
	"[Path]\n".
	join("", map { "PathChanged=$_\n" } @wd).
	"Unit=$svc.service\n".
	"\n".
	"[Install]\n".
	"WantedBy=multi-user.target\n";
	}
return %f;
}

# sync_units_status() -> a status hash
#   systemd  is systemd present
#   nowatch  no zone directory to watch - instant triggering cannot be set up
#   path,timer,service  each as { exists, current, enabled, active }
#   lastrun, lastresult  the service's last run
#   ok       is automatic sync genuinely up
sub sync_units_status
{
my $svc = &sync_service();
my %st = ( 'systemd' => &have_systemd() );
return \%st if (!$st{'systemd'});

my %want = &sync_unit_files();
$st{'nowatch'} = $want{$svc.".path"} ? 0 : 1;

foreach my $k ("path", "timer", "service") {
	my $u = "$svc.$k";
	my $file = &sync_unit_dir()."/$u";
	my $cur = -r $file ? &read_file_contents($file) : undef;
	my %u = ( 'name'    => $u,
		  'exists'  => defined($cur) ? 1 : 0,
		  'current' => (defined($cur) && defined($want{$u}) &&
				$cur eq $want{$u}) ? 1 : 0 );
	if ($u{'exists'}) {
		my ($e) = &systemctl("is-enabled", $u);
		my ($a) = &systemctl("is-active", $u);
		$u{'enabled'} = $e;
		$u{'active'} = $a;
		}
	$st{$k} = \%u;
	}

# The .service is one-shot (Type=oneshot): showing as 'inactive' while idle is
# normal, and the health indicator is the last run's result.
my (undef, $out) = &systemctl("show", "$svc.service",
			      "-p", "Result", "-p", "ExecMainExitTimestamp");
foreach my $l (split(/\r?\n/, $out)) {
	$st{'lastresult'} = $1 if ($l =~ /^Result=(.*)/);
	$st{'lastrun'} = $1 if ($l =~ /^ExecMainExitTimestamp=(.+)/);
	}

# Instant triggering is the real mechanism: the timer alone is far too slow for
# DNS-01 wildcard validation. So 'ok' requires both, and with only the timer up
# the panel reports it as running incompletely.
$st{'ok'} = ($st{'timer'}->{'active'} && !$st{'nowatch'} &&
	     $st{'path'}->{'active'}) ? 1 : 0;
return \%st;
}


# sync_units_healthy(&status) -> are the files current and the units up?
# Checked first when the page opens: if everything is in place ensure is not
# called, so a healthy system makes no needless systemctl calls.
sub sync_units_healthy
{
my ($st) = @_;
return 0 if (!$st->{'systemd'});
return 0 if (!$st->{'timer'}->{'current'} || !$st->{'timer'}->{'active'});
return 0 if (!$st->{'service'}->{'current'});
# With no zone directory to watch there is no .path unit to install, and
# retrying endlessly would be pointless - the panel already warns.
return 1 if ($st->{'nowatch'});
return 0 if (!$st->{'path'}->{'current'} || !$st->{'path'}->{'active'});
return 1;
}
# ensure_sync_units([force]) -> ( list of what was done, error )
# Writes a missing or outdated file, enables what is not enabled and starts
# what is stopped. Idempotent: with everything in place it does nothing and
# returns an empty list, which is why it can be called on every page load.
sub ensure_sync_units
{
my ($force) = @_;
return ([ ], $text{'svc_enosystemd'}) if (!&have_systemd());
my $svc = &sync_service();
my %want = &sync_unit_files();
my @done;
my $reload = 0;

# If the zone directory is gone, do not leave the old .path unit behind: a
# unit watching a directory that does not exist fails every time it starts.
if (!$want{$svc.".path"} && -e &sync_unit_dir()."/$svc.path") {
	&systemctl("disable", "--now", "$svc.path");
	unlink(&sync_unit_dir()."/$svc.path");
	push(@done, "removed $svc.path");
	$reload = 1;
	}

my @changed;
foreach my $u (sort keys %want) {
	my $file = &sync_unit_dir()."/$u";
	my $cur = -r $file ? &read_file_contents($file) : "";
	next if (!$force && $cur eq $want{$u});
	eval {
		local $main::error_must_die = 1;
		&write_file_contents($file, $want{$u});
		};
	return (\@done, &text('svc_ewrite', $file, "$@")) if ($@);
	push(@changed, $u);
	push(@done, ($cur ? "updated " : "installed ").$u);
	$reload = 1;
	}

&systemctl("daemon-reload") if ($reload);

foreach my $u (sort keys %want) {
	next if ($u =~ /\.service$/);	# one-shot job: not enabled or started
	my ($en) = &systemctl("is-enabled", $u);
	if (!$en) {
		&systemctl("enable", $u);
		push(@done, "enabled $u");
		}
	# daemon-reload re-reads the file but a RUNNING unit carries on with its
	# old configuration - a changed watch directory would never take effect.
	# So a changed file means a restart.
	if (&indexof($u, @changed) >= 0) {
		&systemctl("restart", $u);
		push(@done, "restarted $u");
		next;
		}
	my ($ac) = &systemctl("is-active", $u);
	if (!$ac) {
		my ($ok, $out) = &systemctl("start", $u);
		push(@done, $ok ? "started $u" : "could not start $u: $out");
		}
	}
return (\@done, undef);
}

# remove_sync_units() - takes the units with it when the module is removed.
sub remove_sync_units
{
return 0 if (!&have_systemd());
my $svc = &sync_service();
my $n = 0;
foreach my $u ("$svc.path", "$svc.timer", "$svc.service") {
	my $file = &sync_unit_dir()."/$u";
	next if (!-e $file);
	&systemctl("disable", "--now", $u);
	unlink($file);
	$n++;
	}
&systemctl("daemon-reload") if ($n);
return $n;
}

1;
