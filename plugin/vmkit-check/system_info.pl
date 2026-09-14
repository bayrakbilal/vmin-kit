# The dashboard block - Webmin's own mechanism (list_combined_system_info in
# web-lib): every module with a system_info.pl is asked for blocks when the
# System Information page is drawn. This is what makes the checks PUSH: after
# an upgrade the stamp no longer matches, the checks run on the next dashboard
# load, and a failure is a red box at the top of the first page the
# administrator sees. Nothing is shown while everything passes.
use strict;
use warnings;
our (%text, $module_name);

require 'vmkit-check-lib.pl';

# list_system_info(&data, &in, &modskip)
sub list_system_info
{
return ( ) if (!&virtual_server::master_admin());
my $r = &load_results();
$r = &run_and_save() if (!&results_current($r));
return ( ) if (!$r->{'failed'});
return ( { 'type'     => 'warning',
	   'id'       => $module_name,
	   'level'    => 'danger',
	   'priority' => 100,
	   'warning'  => &text('sysinfo_failed', $r->{'failed'}, $r->{'total'},
			       "<a href='/$module_name/'>$text{'index_title'}</a>") } );
}

1;
