# Webmin runs this once when the module is installed:
# install_module() -> foreign_require(postinstall.pl) -> module_install().
#
# The checks run once here, so the page has a result from the start and the
# dashboard does not have to do the first run.
use strict;
use warnings;

# NO './': when this file runs the working directory may belong to another
# module. foreign_require puts the module directory on @INC, so the library is
# required by name.
require 'vmkit-check-lib.pl';

sub module_install
{
eval { &run_and_save(); };
print STDERR "vmkit-check: $@\n" if ($@);
return undef;
}

1;
