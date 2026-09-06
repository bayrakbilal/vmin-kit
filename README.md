# vmin-kit

**Debian 12** üzerinde Virtualmin (GPL) tabanlı bir hosting sunucusunu tek komutla
kuran taşınabilir araç. Kurulum bittiğinde ana domain hazır, SSL'li ve yayında olur.

Amaç basit: **kurulum adımlarını hatırlamak zorunda kalmamak.** Yeni bir VDS'e
taşınırken ya da ikinci sunucuyu açarken tek komut yeter.

## Kurulumdan önce

Ana domain ve hostname için **A kayıtları sunucunun IP'sini göstermeli**:

```
ornek.com        A   <sunucu-ip>
s.ornek.com      A   <sunucu-ip>
```

Cloudflare kullanıyorsanız kurulum sırasında **proxy kapalı (gri bulut)** olsun;
sertifika alındıktan sonra açabilirsiniz.

Araç bunu kendisi kontrol eder — yanlışsa hiçbir şey çalıştırmadan ne yapmanız
gerektiğini yazar.

## Kullanım

```bash
git clone <repo-url>
cd vmin-kit
sudo ./install.sh
```

Tek soru sorulur: **ana domain**. Gerisi varsayılan ya da tespit.

Gözetimsiz çalıştırmak için `config.env` hazırlayın (`config.env.example`'a bakın).
Kurulum başarıyla bittiğinde araç zaten bir `config.env` üretir; ikinci sunucuda
onu kopyalayıp `MAIN_DOMAIN`'i değiştirmeniz yeterlidir.

## Ne yapar

| Adım | Ne yapar |
|------|----------|
| `hostname` | Hostname'i `s.<domain>` yapar + `/etc/hosts` kaydı. **Virtualmin'den önce** — yoksa varsayılan site, SSL isimlendirmesi ve mail kimliği yanlış oturur. |
| `virtualmin` | Resmi installer ile kurar (kuruluysa atlar). |
| `postgres` | PostgreSQL kurar ve Virtualmin özelliğini açar — Virtualmin kurulumuyla gelmiyor. *(isteğe bağlı)* |
| `dns-template` | Yeni domainler için DNS varsayılanları (`bind_master`, `dns_ns`, `dns_prins`, `bind_sub`). |
| `main-domain` | Ana domaini **sade** oluşturur: web + SSL + DNS. Mail ve veritabanı **kapalı**. |
| `host-dns` | Ana domainin zone'una hostname (`s.<domain>`) için A kaydı ekler. |
| `ssl` | Ana domain için Let's Encrypt sertifikası + otomatik yenileme. |
| `docker` | Docker Engine + Portainer CE + `docker.<domain>` proxy sitesi. Tek bayrak (`docker=1`); üçü birlikte gelir. *(isteğe bağlı)* |
| `report` | Araç klasörüne `vmin-kit-rapor.txt` + ikinci sunucu için `config.env` üretir. |

Tüm adımlar **idempotent**: ikinci kez çalıştırmak zarar vermez, kurulu olanı atlar.

### Ana domain neden "sade"?

Mail ve veritabanı **domain başına onay kutusu**. İhtiyaç olduğunda
**Virtualmin → Edit Virtual Server → Enabled features** üzerinden açılır, kapatılır.
Kurulumu sade tutmak hiçbir kapıyı kapatmıyor.

## DNS modları

Araç, domainin NS kayıtlarına bakıp modu **kendisi tespit eder**:

- **Harici DNS** (Cloudflare vb.) — otoriter dışarıda. A kayıtlarını orada yönetirsiniz.
- **BIND** — NS kayıtları bu sunucuyu gösteriyor, sunucu otoriter. Registrar tarafında
  `ns1`/`ns2` için glue kaydı gerekir; rapor bunu hatırlatır.

Her iki modda da Virtualmin'in DNS özelliği **açık kalır** ve zone her zaman
**"NS yönetimi bizde"** modeline göre üretilir: nameserver çifti `ns1.<domain>` /
`ns2.<domain>`, modun ne olduğuna bakılmaksızın. Yerel zone, Virtualmin'in
kayıtları (www, MX, SPF, DKIM, alt domain A kayıtları) doğru üretip güncellediği
çalışma alanıdır; harici modda yayınlanan kopya dışarıdadır ve senkronda NS/SOA
kayıtları gönderilmez, geri kalan her şey aynen gider.

## Yapı

```
install.sh           # tek giriş: durum → cevaplar → DNS kontrol → doğrula → sırayla uygula
config.env.example   # gözetimsiz çalıştırma için hazır cevaplar
lib/common.sh        # yardımcılar (log, ask, set_kv, detect_ip, resolve_a/ns, ensure_pkg)
lib/steps.sh         # adım fonksiyonları (install.sh açık sırayla çağırır)
renew-ssl.sh         # hostname sanal sunucusu için SSL al/yenile
configure-docker.sh  # Portainer kurulum ekranını yeniden açar (yeni setup_token)
```

## `renew-ssl.sh` — hostname sertifikası

Kurulum sırasında domain henüz çözümlemiyorsa (örneğin NS'ler bu sunucuya
delege edilmeden önce) Virtualmin sertifika alamaz, self-signed ile devam eder.
DNS oturduktan sonra:

```bash
sudo ./renew-ssl.sh
```

Hostname sanal sunucusu için gerçek sertifikayı alır ve otomatik yenilemeyi açar.
Ana domain için ayrıca bir şey gerekmez — `./install.sh` tekrar çalıştırıldığında
sertifikası olmayan ana domain için zaten istekte bulunur.

## Portainer

`docker=1` ise kurulum şunları yapar: Docker Engine, Portainer CE (yalnızca
`127.0.0.1:9000`'e bağlı) ve `docker.<domain>` alt sunucusu — kökünden
Portainer'a websocket destekli proxy, kendi SSL sertifikasıyla.

Portainer ilk açılışta bir **setup_token** ister ve bu token kısa ömürlüdür;
birkaç dakika içinde yönetici hesabı oluşturulmazsa kurulum kilitlenir.
Kurulum çıktısında token yazılır. Kaçırırsanız:

```bash
sudo ./configure-docker.sh
```

Konteyneri yeniden başlatır, yeni token'ı okur ve adresle birlikte yazar.

## Kurulum sonrası

- Panel: `https://s.<domain>:10000`
- Rapor: araç klasöründe `vmin-kit-rapor.txt`
- Ana domain sahibinin şifresi rastgele üretilir ve **saklanmaz**. Webmin girişi
  veya FTP gerekirse panelden yeni bir şifre belirleyin
  (*Edit Virtual Server → Password*).

## Plugin'ler (iskelet)

`plugin/` altında iki Webmin modülü var:

| Modül | Kapsam | Panelde nerede |
|---|---|---|
| `vmkit-deploy` | **Domain başına** feature | Edit Virtual Server'da onay kutusu; açıkken domain menüsünde **Git Deploy** |
| `vmkit-cloudflare` | **Sunucu geneli** (feature değil) | System Settings → **Cloudflare DNS Sync** |

Ayrı olmalarının sebebi: bir Webmin modülü tek bir feature tanımlayabiliyor ve
Virtualmin yalnızca `feature_setup` tanımlayan modüllere domain başına onay
kutusu veriyor. Deploy domain başına, Cloudflare senkronu sunucu geneli.

Kurulum:

```bash
sudo ./install-plugins.sh          # kurar / günceller
sudo ./install-plugins.sh --remove
```

Modüller `/usr/share/webmin/` altına **kopyalanır**, symlink kurulmaz —
symlink olsaydı Webmin'in ve bu script'in yazdıkları doğrudan git deposunu
kirletirdi.

**Geliştirme döngüsü:** `git pull && sudo ./install-plugins.sh`. Webmin her
isteği taze bir Perl process'inde çalıştırdığı için derleme yoktur; script
yalnızca `module.info` değiştiğinde Webmin'i yeniden başlatır, diğer
durumlarda dosyaları kopyalar ve sayfayı yenilemeniz yeterlidir.

> Şu an **iskelet**: tanımlar kaydediliyor, ekranlar çalışıyor; git işlemleri ve
> Cloudflare API çağrıları henüz yok.

## Yol haritası

Kurulum tarafı tamamlandıktan sonra asıl iş **Virtualmin plugin'i**: panelde
domain başına çalışan işler (git deploy, composer, Cloudflare DNS senkronu).
