# Webmin modul kurulunca bunu bir kez calistirir:
# install_module() -> foreign_require(postinstall.pl) -> module_install().
#
# Otomatik senkron birimlerini burada kuruyoruz. Boylece modul ister
# install-plugins.sh ile ister .wbm.gz olarak standart yoldan kurulsun,
# servis her iki durumda da olusur ve baslar.
use strict;
use warnings;

# './' YOK: bu dosya calistiginda calisma dizini Webmin'in kendi modulunun
# dizini olabiliyor. foreign_require modul dizinini @INC'e ekliyor, o yuzden
# kutuphaneyi adiyla istiyoruz.
require 'vmkit-cloudflare-lib.pl';

sub module_install
{
my ($done, $err) = &ensure_sync_units();
# Kurulum ekranini hatayla kesmiyoruz: modul servis olmadan da calisir,
# yalnizca senkron elle tetiklenir. Durum modulun kendi sayfasinda gorunur.
print STDERR "vmkit-cloudflare: $err\n" if ($err);
return undef;
}

1;
