# vmkit-cloudflare - the Virtualmin feature contract.
#
# SYMMETRIC with vmkit-deploy: one feature per domain. Each domain has its own
# Cloudflare API token, because a token is account/zone scoped and domains may
# live in different Cloudflare accounts. There is no global token.
#
# Enabling the feature on a domain creates its record file and makes sure the
# automatic sync service is up. The syncing itself starts once a token is
# entered.
use strict;
use warnings;
our (%text, %config);
our $module_name;

require 'vmkit-cloudflare-lib.pl';

# feature_name()
sub feature_name
{
return $text{'feat_name'};
}

# feature_label(in-edit-form)
sub feature_label
{
my ($edit) = @_;
return $edit ? $text{'feat_label2'} : $text{'feat_label'};
}

sub feature_losing
{
return $text{'feat_losing'};
}

sub feature_disname
{
return $text{'feat_disname'};
}

# feature_check()
sub feature_check
{
return undef;
}

# feature_suitable(&parentdom, &aliasdom, &subdom)
# Alias domains have no zone of their own, and a sub-server's records go into
# the parent zone. So this is only meaningful for top-level servers.
sub feature_suitable
{
my ($parentdom, $aliasdom, $subdom) = @_;
return $aliasdom || $parentdom ? 0 : 1;
}

# feature_depends(&domain)
# Syncing needs a zone, so the DNS feature is required.
sub feature_depends
{
my ($d) = @_;
return $d->{'dns'} ? undef : $text{'feat_edepdns'};
}

# feature_setup(&domain)
# Creates the record file with the defaults; the token is entered from the
# panel. Until it is, the domain takes no part in syncing (sync_domains).
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'setup_start'});
# The default comes from the module configuration (Features and Plugins ->
# Configure).
&save_cf($d, { 'proxy'   => $config{'default_proxy'} ? 1 : 0,
	       'enabled' => 1 });
# Make sure the watch service is up on the first domain: the module may have
# been copied by hand, in which case postinstall.pl never ran.
&ensure_sync_units();
&$virtual_server::second_print($text{'setup_done_token'});
}

sub feature_modify
{
}

# feature_delete(&domain)
# Removing the feature deletes every setting, the token included.
sub feature_delete
{
my ($d) = @_;
&$virtual_server::first_print($text{'delete_start'});
&delete_cf($d);
&$virtual_server::second_print($virtual_server::text{'setup_done'});
}

sub feature_disable
{
}

sub feature_enable
{
}

sub feature_validate
{
return undef;
}

# feature_links(&domain)
# Adds an icon to the domain's menu.
sub feature_links
{
my ($d) = @_;
return ( { 'mod'   => $module_name,
	   'desc'  => $text{'links_link'},
	   'page'  => 'index.cgi?dom='.$d->{'id'},
	   'cat'   => 'server',
	   'order' => 560 } );
}

# feature_webmin(&main-domain, &all-domains)
# Lets a domain owner manage their own domain's Cloudflare settings.
sub feature_webmin
{
my ($d, $alldoms) = @_;
my @doms = map { $_->{'dom'} } grep { $_->{$module_name} } @$alldoms;
return @doms ? ( [ $module_name, { 'dom' => join(" ", @doms),
				   'noconfig' => 1 } ] ) : ( );
}

sub feature_modules
{
return ( [ $module_name, $text{'feat_module'} ] );
}

# ---------------------------------------------------------------------------
# BACKUP AND RESTORE
#
# What travels: the token, the proxy preference and the automatic sync switch.
#
# THE TOKEN IS READ FROM THE RAW FILE (not through get_cf): on disk it is
# already obfuscated and it should stay that way. Reading it with get_cf would
# write plain text into the backup - and backups are one of the main reasons
# for obfuscating it.
#
# What does not travel:
#   zone_id      Cloudflare's zone id. Without it cf_zone_id looks it up and
#                stores it; a stale id (a domain moved to another account)
#                would cause silent, confusing errors.
#   last_status  the result of an old run on another server; misleading.
#   last_time
# ---------------------------------------------------------------------------

# feature_backup_name()
sub feature_backup_name
{
return $text{'backup_name'};
}

# feature_backup(&domain, file, &opts, homeformat?, differential?, as-owner,
#                &all-opts, &destinations)
sub feature_backup
{
my ($d, $file, $opts, $homefmt, $increment, $asd) = @_;
&$virtual_server::first_print($text{'backup_doing'});

my %cf;
&read_file(&domain_file($d), \%cf);
my %out;
foreach my $k ('token', 'proxy', 'enabled') {
	$out{$k} = $cf{$k} if (defined($cf{$k}));
	}

my $err;
eval { &write_file($file, \%out); };
$err = $@;
if ($err) {
	$err =~ s/\s+at\s+\S+\s+line\s+\d+.*//;
	&$virtual_server::second_print(&text('backup_efile', $err));
	return 0;
	}

# When the domain owner takes their own backup they are the one packing the
# archive and must be able to read the file. For root it stays 0600 root.
if ($asd) {
	&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0600, $file);
	}
else {
	&set_ownership_permissions(undef, undef, 0600, $file);
	}

&$virtual_server::second_print($out{'token'} ? $text{'backup_done'}
					     : $text{'backup_done_notoken'});
return 1;
}

# feature_restore(&domain, file, &opts, &all-opts)
sub feature_restore
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'restore_doing'});

my %in;
if (!&read_file($file, \%in)) {
	&$virtual_server::second_print($text{'restore_eread'});
	return 0;
	}

# save_cf is NOT used: it writes the token encoded, and the value from the
# backup is already in that form - encoding it twice would corrupt it. The
# existing record is overwritten, deliberately dropping zone_id and the last
# run information; both are recreated by themselves.
my $file2 = &domain_file($d);
my $dir = &domains_dir();
-d $dir || &make_dir($dir, 0700, 1);
&lock_file($file2);
&write_file($file2, \%in);
&unlock_file($file2);
chmod(0600, $file2);

&$virtual_server::second_print($in{'token'} ? $text{'restore_done'}
					   : $text{'restore_done_notoken'});
return 1;
}

1;
