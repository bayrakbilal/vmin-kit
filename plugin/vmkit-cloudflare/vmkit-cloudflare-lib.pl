# vmkit-cloudflare yardimci fonksiyonlari.
#
# Tasarim: yerel BIND zone'u MODEL, Cloudflare YAYIN kopyasidir. Virtualmin
# kayitlari (www, MX, SPF, DKIM, alt domain A kayitlari) zaten dogru uretip
# guncelliyor; biz o zone'u Cloudflare'e basiyoruz.
#
# Tetikleme: zone dosyalarini izlemek. Her degisiklikte SOA serial'i artiyor
# (feature-dns.pl icindeki post_records_change), dolayisiyla zone dosyasi
# degistiyse gercekten bir sey degismistir. Virtualmin'in DNS kod yolunda
# plugin kancasi YOK, o yuzden dosya izleme en saglam yontem.
#
# ISKELET: burada henuz API cagrisi ya da izleme servisi yok.

use strict;
use warnings;
BEGIN { push(@INC, ".."); };
use WebminCore;

our (%config, %text, $module_name, $module_config_directory);

&init_config();
&foreign_require("virtual-server", "virtual-server-lib.pl");

# Senkronu acik olan domain kimlikleri bu dosyada tutulur.
sub domains_file
{
return "$module_config_directory/domains";
}

# list_sync_domains() -> senkronu acik domain kimlikleri
sub list_sync_domains
{
my %ids;
&read_file(&domains_file(), \%ids);
return grep { $ids{$_} } keys %ids;
}

# sync_enabled(&domain)
sub sync_enabled
{
my ($d) = @_;
my %ids;
&read_file(&domains_file(), \%ids);
return $ids{$d->{'id'}} ? 1 : 0;
}

# set_sync_enabled(&domain, 1|0)
sub set_sync_enabled
{
my ($d, $on) = @_;
my $file = &domains_file();
my %ids;
&lock_file($file);
&read_file($file, \%ids);
if ($on) { $ids{$d->{'id'}} = 1; }
else     { delete($ids{$d->{'id'}}); }
&write_file($file, \%ids);
&unlock_file($file);
}

# token_set() -> API token girilmis mi
sub token_set
{
return $config{'api_token'} ? 1 : 0;
}

# Token'in ekranda gosterilecek maskeli hali.
sub masked_token
{
my $t = $config{'api_token'};
return '' if (!$t);
return length($t) <= 8 ? ('*' x length($t))
		       : substr($t, 0, 4).('*' x 8).substr($t, -4);
}

# ISKELET: gercek uygulamada Cloudflare API'sine sorup zone kimligini bulur.
sub zone_status
{
my ($d) = @_;
return $text{'status_unknown'};
}

1;
