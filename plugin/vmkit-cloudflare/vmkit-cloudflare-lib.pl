# vmkit-cloudflare yardimci fonksiyonlari.
#
# Tasarim: yerel BIND zone'u MODEL, Cloudflare YAYIN kopyasidir. Virtualmin
# kayitlari (www, MX, SPF, DKIM, alt domain A kayitlari) zaten dogru uretip
# guncelliyor; biz o zone'u Cloudflare'e basiyoruz. SOA ve NS gonderilmez,
# onlarin sahibi Cloudflare'dir.
#
# Tetikleme: zone dosyalarini izleyen bir arka plan servisi. Her degisiklikte
# SOA serial'i artiyor (feature-dns.pl icindeki post_records_change), dolayisiyla
# zone dosyasi degistiyse gercekten bir sey degismistir. Virtualmin'in DNS kod
# yolunda plugin kancasi YOK, o yuzden dosya izleme en saglam yontem.
# Bu modul o servisin kontrol panelidir; servisin kendisi ayri gelecek.
#
# Ayarlar DOMAIN BASINA tutulur. Global token yoktur: her domain baska bir
# Cloudflare hesabinda olabilir, token da hesap/zone bazlidir.
#   /etc/webmin/vmkit-cloudflare/domains/<domain-id>
# Dosyalar token icerdigi icin 0600.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, $module_name, $module_config_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

sub domains_dir
{
return "$module_config_directory/domains";
}

sub domain_file
{
my ($d) = @_;
return &domains_dir()."/$d->{'id'}";
}

# get_cf(&domain) -> ayar hash'i (yoksa varsayilanlar)
sub get_cf
{
my ($d) = @_;
my %cf;
&read_file(&domain_file($d), \%cf);
$cf{'proxy'} = 0 if (!defined($cf{'proxy'}));
return \%cf;
}

# save_cf(&domain, &cf)
sub save_cf
{
my ($d, $cf) = @_;
my $dir = &domains_dir();
-d $dir || &make_dir($dir, 0700, 1);
my $file = &domain_file($d);
&lock_file($file);
&write_file($file, $cf);
&unlock_file($file);
# Token bir sirdir.
chmod(0600, $file);
}

# delete_cf(&domain)
sub delete_cf
{
my ($d) = @_;
my $file = &domain_file($d);
&lock_file($file);
unlink($file);
&unlock_file($file);
}

# can_edit_domain(&domain)
# Virtualmin'in yetki kontrolu: root hepsini, domain sahibi kendisininkini.
sub can_edit_domain
{
my ($d) = @_;
return &virtual_server::can_edit_domain($d);
}

# Token'in ekranda gosterilecek maskeli hali.
sub masked_token
{
my ($t) = @_;
return '' if (!$t);
return length($t) <= 8 ? ('*' x length($t))
		       : substr($t, 0, 4).('*' x 8).substr($t, -4);
}

# ISKELET: gercek uygulamada Cloudflare API'sine sorup zone kimligini ve
# son senkron durumunu dondurur.
sub zone_status
{
my ($d) = @_;
my $cf = &get_cf($d);
return $text{'status_notoken'} if (!$cf->{'token'});
return $cf->{'last_status'} || $text{'status_unknown'};
}

1;
