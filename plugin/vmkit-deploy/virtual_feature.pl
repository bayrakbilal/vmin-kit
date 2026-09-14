# vmkit-deploy - the Virtualmin feature contract.
#
# The feature is enabled per domain, and enabling it INSTALLS NOTHING: it only
# means "deployments may be defined for this domain". The real work happens in
# the deployments the user defines - see vmkit-deploy-lib.pl.
use strict;
use warnings;
our (%text, %config);
our $module_name;

require 'vmkit-deploy-lib.pl';

# feature_name()
sub feature_name
{
return $text{'feat_name'};
}

# feature_label(in-edit-form)
# The label shown on the create and edit domain forms.
sub feature_label
{
my ($edit) = @_;
return $edit ? $text{'feat_label2'} : $text{'feat_label'};
}

# feature_losing(&domain)
sub feature_losing
{
return $text{'feat_losing'};
}

# feature_disname(&domain)
sub feature_disname
{
return $text{'feat_disname'};
}

# feature_check()
# Is the feature usable at all? Returns an error when git is missing.
sub feature_check
{
return &has_command("git") ? undef : $text{'feat_echeck'};
}

# feature_suitable(&parentdom, &aliasdom, &subdom)
# Meaningless on alias domains; fine on top-level domains and sub-servers.
sub feature_suitable
{
my ($parentdom, $aliasdom, $subdom) = @_;
return $aliasdom ? 0 : 1;
}

# feature_depends(&domain)
# Deploying needs a directory to deploy into, so the web feature is required.
sub feature_depends
{
my ($d) = @_;
return $d->{'web'} ? undef : $text{'feat_edepweb'};
}

# feature_setup(&domain)
# Nothing to install: deployments are added by the user from the panel. The
# feature only grants access to the menu.
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'setup_start'});
# Make sure the hook's access is set up on the first domain: the module may
# have been copied by hand, in which case postinstall.pl never ran.
&ensure_hook_access();
&$virtual_server::second_print($virtual_server::text{'setup_done'});
}

# feature_modify(&domain, &olddomain)
sub feature_modify
{
}

# feature_delete(&domain)
# Removes every deployment definition for this domain when the feature is
# turned off.
sub feature_delete
{
my ($d) = @_;
&$virtual_server::first_print($text{'delete_start'});
&delete_domain_deploys($d);
&$virtual_server::second_print($virtual_server::text{'setup_done'});
}

# feature_disable(&domain) / feature_enable(&domain)
# Called when a domain is suspended and restored. Nothing to do: the
# definitions stay on disk, and a deploy only ever runs when triggered.
# Deleting is feature_delete's job.
sub feature_disable
{
}

sub feature_enable
{
}

# feature_validate(&domain)
sub feature_validate
{
return undef;
}

# feature_links(&domain)
# Adds an icon to the domain's menu. The core shortcuts leave room between
# 500 (web apps) and 600 (File Manager).
sub feature_links
{
my ($d) = @_;
return ( { 'mod'   => $module_name,
	   'desc'  => $text{'links_link'},
	   'page'  => 'index.cgi?dom='.$d->{'id'},
	   'cat'   => 'server',
	   'order' => 550 } );
}

# feature_webmin(&main-domain, &all-domains)
# Lets the domain owner see this module under their own account.
sub feature_webmin
{
my ($d, $alldoms) = @_;
my @doms = map { $_->{'dom'} } grep { $_->{$module_name} } @$alldoms;
return @doms ? ( [ $module_name, { 'dom' => join(" ", @doms),
				   'noconfig' => 1 } ] ) : ( );
}

# feature_modules()
# Appears in the list of modules a server template can grant to domain owners.
sub feature_modules
{
return ( [ $module_name, $text{'feat_module'} ] );
}

# ---------------------------------------------------------------------------
# BACKUP AND RESTORE
#
# Webmin has no database: everything is files, and our files do NOT travel with
# a Virtualmin domain backup by themselves. The only thing that gets in is what
# feature_backup writes, called once per feature.
#
# What travels: only what lives under /etc/webmin/vmkit-deploy - the deployment
# definitions (repository, branch, target, mode, hook UUID) and the post-deploy
# command text. Nothing from the domain's HOME is included, because the 'dir'
# feature already backs that up: ~/.vmkit/repos/<id>.git,
# ~/.vmkit/actions-<id>.sh, ~/.vmkit/bin/php and ~/.ssh/id_ed25519.
#
# LOGS ARE NOT INCLUDED: the output of a past run would be misleading on
# another server, and it is single-use anyway.
#
# THE DOMAIN ID CHANGES: our file names are "<domainid>-<deploymentid>" and a
# restored domain can get a NEW id. So the domain id is left out of the backup
# and the records are rebuilt with the current $d->{'id'} on restore.
# ---------------------------------------------------------------------------

# feature_backup_name()
# Describes on the backup screens what this feature stores.
sub feature_backup_name
{
return $text{'backup_name'};
}

# feature_backup(&domain, file, &opts, homeformat?, differential?, as-owner,
#                &all-opts, &destinations)
# 1 = success, 0 = failure.
sub feature_backup
{
my ($d, $file, $opts, $homefmt, $increment, $asd) = @_;
&$virtual_server::first_print($text{'backup_doing'});

my @deps = &list_deploys($d);
my @recs;
foreach my $dep (@deps) {
	my %copy = %$dep;
	# 'file' is a local path and 'dom' a local domain id: both belong to
	# this server and are rebuilt on restore.
	delete($copy{'file'});
	delete($copy{'dom'});
	push(@recs, { 'dep'     => \%copy,
		      'actions' => &actions_read($d, $dep) });
	}

# serialise_variable is Webmin's own format, which Virtualmin also uses for
# backup metadata. Better than inventing a separator: it carries nested
# structures and multi-line text without trouble.
my $data = &serialise_variable(\@recs);
my $err;
eval {
	no strict "subs";
	&open_tempfile(BACKUP, ">$file", 0, 1);
	&print_tempfile(BACKUP, $data);
	&close_tempfile(BACKUP);
	use strict "subs";
	};
$err = $@;
if ($err) {
	$err =~ s/\s+at\s+\S+\s+line\s+\d+.*//;
	&$virtual_server::second_print(&text('backup_efile', $err));
	return 0;
	}

# When the domain owner takes their own backup ($asd is set) the file must be
# readable by them, not root - they are the one packing the archive. The
# content is theirs anyway; the hook URL and commands are already visible to
# them in the panel.
if ($asd) {
	&set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0600, $file);
	}
else {
	&set_ownership_permissions(undef, undef, 0600, $file);
	}

&$virtual_server::second_print(&text('backup_done', scalar(@recs)));
return 1;
}

# feature_restore(&domain, file, &opts, &all-opts)
sub feature_restore
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'restore_doing'});

my $data = &read_file_contents($file);
if (!defined($data)) {
	&$virtual_server::second_print($text{'restore_eread'});
	return 0;
	}
my $recs = &unserialise_variable($data);
if (ref($recs) ne 'ARRAY') {
	&$virtual_server::second_print($text{'restore_ebad'});
	return 0;
	}

# Existing definitions for this domain are cleared first, otherwise an old
# deployment that is not in the backup would survive the restore.
#
# delete_deploy is NOT used: it also removes the bare repository, which lives
# in the home directory and is restored by the 'dir' feature. Removing it here
# would destroy the repository of anyone restoring only this feature.
foreach my $old (&list_deploys($d)) {
	unlink($old->{'file'}) if ($old->{'file'});
	unlink(&actions_path($d, $old));
	}

my $n = 0;
foreach my $r (@$recs) {
	my $dep = $r->{'dep'};
	next if (ref($dep) ne 'HASH' || !$dep->{'id'});
	# save_deploy rebuilds the 'dom' field and the file name from the
	# current domain id - the backup deliberately carries no domain id.
	&save_deploy($d, $dep);
	&actions_write($d, $dep, $r->{'actions'});
	$n++;
	}

&$virtual_server::second_print(&text('restore_done', $n));
return 1;
}

1;
