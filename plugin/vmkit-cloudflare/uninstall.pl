# Webmin runs this when the module is deleted (delete_module ->
# module_uninstall). The systemd units are stopped and removed so nothing is
# left running in the background.
use strict;
use warnings;

require 'vmkit-cloudflare-lib.pl';

sub module_uninstall
{
&remove_sync_units();
return undef;
}

1;
