# Webmin modul kurulunca bunu bir kez calistirir:
# install_module() -> foreign_require(postinstall.pl) -> module_install().
#
# Web kancasinin adresi giris istemeden erisilebilir olmali; miniserv'in
# kimlik dogrulamasi istemeyen yol listesine burada ekleniyor. Boylece modul
# ister .wbm.gz ile ister update-plugins.sh ile kurulsun ayni sey oluyor.
use strict;
use warnings;

# './' YOK: bu dosya calistiginda calisma dizini baska bir modulun dizini
# olabiliyor. foreign_require modul dizinini @INC'e ekliyor, o yuzden
# kutuphaneyi adiyla istiyoruz.
require 'vmkit-deploy-lib.pl';

sub module_install
{
my ($changed, $err) = &ensure_hook_path();
# Kurulumu hatayla kesmiyoruz: kanca olmadan da modul calisir, yalnizca
# tetikleme elle olur. Durum modulun kendi sayfasinda gorunuyor.
print STDERR "vmkit-deploy: $err\n" if ($err);
return undef;
}

1;
