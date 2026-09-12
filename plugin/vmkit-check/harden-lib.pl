# The single implementation of the server-wide hardening from the 2026-09-12
# pentest. Used two ways from one file, so there is no second copy to drift:
#   - the installer runs it:   perl harden-lib.pl apply-all   (from the checkout)
#   - the Check plugin requires it and calls the subs for status and Repair
#
# Standalone Perl on purpose: NO WebminCore, only system commands and file I/O,
# so it behaves identically whether bash runs it at install time or Webmin
# requires it in a CGI. fail2ban is deliberately NOT here - it has its own panel
# and lives only in the installer.
#
# Each measure is a hash: id, title, where (the file it lives in), why, and two
# subs - check() returns 1 when the measure is in effect, apply() (re)applies it
# idempotently and returns (ok, message). BIND and Apache validate their config
# before reload and revert on failure, so a bad edit never takes a service down.
package vmkit_harden;
use strict;
use warnings;

sub _run    { system($_[0]." >/dev/null 2>&1") == 0 }
sub _out    { my $o = `$_[0] 2>/dev/null`; chomp($o); return $o }
sub _has    { _run("command -v ".$_[0]) }
sub _reload { _run("systemctl reload $_[0]") || _run("systemctl restart $_[0]") }

# ---- Postfix: VRFY off, AUTH only after TLS --------------------------------
sub postfix_check {
	return (_out("postconf -h disable_vrfy_command") eq 'yes' &&
		_out("postconf -h smtpd_tls_auth_only")  eq 'yes') ? 1 : 0;
}
sub postfix_apply {
	_has("postconf") or return (0, "postconf not found");
	_run("postconf -e 'disable_vrfy_command=yes' 'smtpd_tls_auth_only=yes'")
		or return (0, "postconf failed");
	_reload("postfix");
	return postfix_check() ? (1, "VRFY disabled, AUTH only after TLS")
			       : (0, "applied but not in effect");
}

# ---- Dovecot: no cleartext auth without TLS --------------------------------
# The setting name differs by version: 2.3 disable_plaintext_auth=yes,
# 2.4 auth_allow_cleartext=no. The running Dovecot is asked which it knows.
sub _dovecot_setting {
	my $all = _out("doveconf -a");
	return ('auth_allow_cleartext', 'no')    if ($all =~ /^auth_allow_cleartext/m);
	return ('disable_plaintext_auth', 'yes') if ($all =~ /^disable_plaintext_auth/m);
	return ();
}
sub dovecot_check {
	my ($k, $v) = _dovecot_setting();
	return 0 if (!$k);
	return _out("doveconf -h $k") eq $v ? 1 : 0;
}
sub dovecot_apply {
	_has("doveconf") or return (0, "doveconf not found");
	my ($k, $v) = _dovecot_setting();
	return (0, "no known cleartext-auth setting") if (!$k);
	my $dir = "/etc/dovecot/conf.d";
	return (0, "conf.d not found") if (!-d $dir);
	my $f = "$dir/99-vmkit-security.conf";
	open(my $fh, ">", $f) or return (0, "cannot write drop-in");
	print $fh "# vmin-kit: no cleartext auth on non-TLS connections\n$k = $v\n";
	close($fh);
	chmod(0644, $f);
	# Parse BEFORE reloading - a bad drop-in must not reach a restart.
	if (!_run("doveconf -n")) {
		unlink($f);
		return (0, "drop-in did not parse; removed");
	}
	_reload("dovecot");
	return dovecot_check() ? (1, "cleartext auth disabled ($k)")
			       : (0, "not in effect after reload");
}

# ---- BIND: hide the version -----------------------------------------------
sub _bind_opts { "/etc/bind/named.conf.options" }
sub bind_check {
	my $f = _bind_opts();
	return 0 if (!-r $f);
	local $/; open(my $fh, "<", $f) or return 0; my $c = <$fh>; close($fh);
	return $c =~ /^\s*version\s/m ? 1 : 0;
}
sub bind_apply {
	my $f = _bind_opts();
	return (0, "named.conf.options not found") if (!-f $f);
	return (1, "already hidden") if (bind_check());
	local $/; open(my $in, "<", $f) or return (0, "cannot read"); my $c = <$in>; close($in);
	_run("cp -a $f $f.vmin-kit.bak");
	# Insert right after the first 'options {'.
	$c =~ s/(options\s*\{)/$1\n\tversion "not available";/
		or return (0, "no options block found");
	open(my $o, ">", $f) or return (0, "cannot write"); print $o $c; close($o);
	if (!_run("named-checkconf")) {
		_run("cp -a $f.vmin-kit.bak $f");
		return (0, "config check failed; reverted");
	}
	_run("rndc reconfig") || _reload("named") || _reload("bind9");
	return (1, "version hidden");
}

# ---- Apache: HSTS + nosniff on every vhost --------------------------------
sub _apache_conf { "/etc/apache2/conf-available/vmkit-security.conf" }
sub apache_check {
	# a2query -c exits 0 when the conf is enabled.
	return _run("a2query -c vmkit-security") ? 1 : 0;
}
sub apache_apply {
	my $d = "/etc/apache2/conf-available";
	return (0, "conf-available not found") if (!-d $d);
	my $f = _apache_conf();
	open(my $o, ">", $f) or return (0, "cannot write conf");
	print $o "# vmin-kit: security headers for all vhosts\n".
		 "<IfModule mod_headers.c>\n".
		 "  Header always set Strict-Transport-Security \"max-age=15768000\"\n".
		 "  Header always set X-Content-Type-Options \"nosniff\"\n".
		 "</IfModule>\n";
	close($o);
	_run("a2enmod headers");
	_run("a2enconf vmkit-security");
	if (!_run("apachectl configtest")) {
		_run("a2disconf vmkit-security");
		return (0, "config test failed; conf disabled");
	}
	_reload("apache2");
	return (1, "HSTS and nosniff set");
}

# ---- the measures, in order ------------------------------------------------
sub measures {
	return (
	  { 'id'    => 'postfix',
	    'title' => 'Postfix: VRFY off, AUTH only after TLS',
	    'where' => '/etc/postfix/main.cf',
	    'why'   => 'VRFY let anyone enumerate local users; 587 offered AUTH before STARTTLS',
	    'check' => \&postfix_check, 'apply' => \&postfix_apply },
	  { 'id'    => 'dovecot',
	    'title' => 'Dovecot: no cleartext auth without TLS',
	    'where' => '/etc/dovecot/conf.d/99-vmkit-security.conf',
	    'why'   => 'IMAP/POP accepted the mailbox password on a bare connection',
	    'check' => \&dovecot_check, 'apply' => \&dovecot_apply },
	  { 'id'    => 'bind',
	    'title' => 'BIND: version hidden',
	    'where' => '/etc/bind/named.conf.options',
	    'why'   => 'version.bind revealed the exact package version',
	    'check' => \&bind_check, 'apply' => \&bind_apply },
	  { 'id'    => 'apache',
	    'title' => 'Apache: HSTS + nosniff on every vhost',
	    'where' => '/etc/apache2/conf-available/vmkit-security.conf',
	    'why'   => 'no HSTS on the Apache vhosts (webmail login, the proxy sites)',
	    'check' => \&apache_check, 'apply' => \&apache_apply },
	);
}

sub measure_by_id {
	my ($id) = @_;
	my ($m) = grep { $_->{'id'} eq $id } &measures();
	return $m;
}

# ---- CLI, only when run directly (bash uses this; require() skips it) -------
# 'caller' is true when the file is require'd, false when run as a script.
unless (caller()) {
	my $cmd = shift(@ARGV) || '';
	my $rc = 0;
	if ($cmd eq 'apply-all') {
		foreach my $m (&measures()) {
			my ($ok, $msg) = $m->{'apply'}->();
			printf("%s\t%s\t%s\n", ($ok ? 'ok' : 'fail'), $m->{'title'}, $msg);
			$rc = 1 if (!$ok);
		}
	}
	elsif ($cmd eq 'check-all') {
		foreach my $m (&measures()) {
			printf("%s\t%s\n", ($m->{'check'}->() ? 'ok' : 'bad'), $m->{'title'});
			$rc = 1 if (!$m->{'check'}->());
		}
	}
	else {
		print STDERR "usage: harden-lib.pl apply-all|check-all\n";
		$rc = 2;
	}
	exit($rc);
}

1;
