# Webmin runs this once when the module is installed:
# install_module() -> foreign_require(postinstall.pl) -> module_install().
#
# The webhook URL has to be reachable without a login, so its path is added to
# miniserv's no-authentication list here. That way installing from a .wbm.gz
# and installing with update-plugins.sh do the same thing.
use strict;
use warnings;

# NO './': when this file runs the working directory may belong to another
# module. foreign_require puts the module directory on @INC, so the library is
# required by name.
require 'vmkit-deploy-lib.pl';

sub module_install
{
my ($changed, $err) = &ensure_hook_access();
# An error does not abort the installation: the module works without the hook,
# deployments just have to be triggered by hand. The state is visible on the
# module's own page.
print STDERR "vmkit-deploy: $err\n" if ($err);
return undef;
}

1;
