# Webmin runs this when the module is deleted (delete_module ->
# module_uninstall). The hook path is removed from miniserv's list so no URL of
# a module that no longer exists is left behind.
use strict;
use warnings;

require 'vmkit-deploy-lib.pl';

sub module_uninstall
{
&remove_hook_path();
return undef;
}

1;
