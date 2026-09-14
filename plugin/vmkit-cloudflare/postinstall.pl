# Webmin runs this once when the module is installed:
# install_module() -> foreign_require(postinstall.pl) -> module_install().
#
# The automatic sync units are installed here, so the service is created and
# started whether the module arrives through install-plugins.sh or as a
# .wbm.gz by the standard route.
use strict;
use warnings;

# NO './': when this file runs the working directory may belong to another
# module. foreign_require puts the module directory on @INC, so the library is
# required by name.
require 'vmkit-cloudflare-lib.pl';

sub module_install
{
my ($done, $err) = &ensure_sync_units();
# An error does not abort the installation screen: the module works without
# the service, the sync just has to be triggered by hand. The state is visible
# on the module's own page.
print STDERR "vmkit-cloudflare: $err\n" if ($err);
return undef;
}

1;
