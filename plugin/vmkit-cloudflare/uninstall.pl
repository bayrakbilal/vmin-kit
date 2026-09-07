# Modul silinirken Webmin bunu calistirir (delete_module -> module_uninstall).
# Arkada calisan systemd birimleri kalmasin: birimleri durdurup kaldiriyoruz.
use strict;
use warnings;

require 'vmkit-cloudflare-lib.pl';

sub module_uninstall
{
&remove_sync_units();
return undef;
}

1;
