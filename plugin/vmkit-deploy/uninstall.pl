# Modul silinirken Webmin bunu calistirir (delete_module -> module_uninstall).
# Kanca yolunu miniserv'in listesinden cikariyoruz: olmayan bir modulun
# adresi orada durmasin.
use strict;
use warnings;

require 'vmkit-deploy-lib.pl';

sub module_uninstall
{
&remove_hook_path();
return undef;
}

1;
