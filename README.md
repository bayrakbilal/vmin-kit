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

Tek soru sorulur: **ana domain**. Ardından kullanılacak ayarların özeti gösterilir
ve onay istenir; yanlış bir şey görürseniz iptal edip `config.env`'i düzeltir,
yeniden çalıştırırsınız.

Diğer her şey `config.env`'den gelir. O dosya **depoda durur** ve tercihlerin
yeridir: değiştirin, commit'leyin — sonraki sunucu depoyu çektiğinde aynı şekilde
kurulur, hatırlanacak bir şey kalmaz. Ana domain orada tutulmaz; her sunucuda
farklı olan tek değer odur. Betikten çalıştırmak için ortam değişkeni olarak
verilebilir: `MAIN_DOMAIN=ornek.com sudo -E ./install.sh`.

## Ne yapar

| Adım | Ne yapar |
|------|----------|
| `hostname` | Hostname'i `s.<domain>` yapar + `/etc/hosts` kaydı. **Virtualmin'den önce** — yoksa varsayılan site, SSL isimlendirmesi ve mail kimliği yanlış oturur. |
| `virtualmin` | Resmi installer ile kurar (kuruluysa atlar). |
| `postgres` | PostgreSQL kurar ve Virtualmin özelliğini açar — Virtualmin kurulumuyla gelmiyor. *(isteğe bağlı)* |
| `composer` | Composer kurar (`vmkit-composer` eklentisinin gereksinimi). *(isteğe bağlı)* |
| `dns-template` | Yeni domainler için DNS varsayılanları (`bind_master`, `dns_ns`, `dns_prins`, `bind_sub`). |
| `admin-redirect` | *(`NO_ADMIN_REDIRECT=1` ise)* Yeni domainlere eklenen `admin.<domain>` → panel (`:10000`) yönlendirmesini kapatır (`web_admin=0`). Tek ayar hem DNS kaydını hem Apache yönlendirmesini kapatıyor; **domain oluşmadan önce** çalışmalı, sonradan kapatmak var olanları temizlemiyor. `webmail.<domain>` bilerek açık bırakıldı. |
| `main-domain` | Ana domaini **sade** oluşturur: web + SSL + DNS. Mail ve veritabanı **kapalı**. |
| `host-dns` | Ana domainin zone'una hostname (`s.<domain>`) için A kaydı ekler. |
| `ssl` | Ana domain için Let's Encrypt sertifikası + otomatik yenileme. |
| `docker` | Docker Engine + Portainer CE + `docker.<domain>` proxy sitesi. Tek bayrak (`DOCKER=1`); üçü birlikte gelir. *(isteğe bağlı)* |
| `report` | Araç klasörüne `vmin-kit-rapor.txt` üretir: ne yapıldı, panel adresi, sırada ne var. |

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
install.sh           # tek giriş: durum → ayarlar+domain → DNS kontrol → onay → sırayla uygula
config.env           # varsayılan ayarlar (depoda; ana domain burada tutulmaz)
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

`DOCKER=1` ise kurulum şunları yapar: Docker Engine, Portainer CE (yalnızca
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

| Modül | Panelde nerede |
|---|---|
| `vmkit-deploy` | Edit Virtual Server'da onay kutusu; açıkken domain menüsünde **Git Deploy** |
| `vmkit-composer` | Edit Virtual Server'da onay kutusu; açıkken domain menüsünde **Composer** |
| `vmkit-cloudflare` | Edit Virtual Server'da onay kutusu; açıkken domain menüsünde **Cloudflare DNS** |

İkisi de **domain başına** feature. Ayrı modüller olmalarının sebebi: bir Webmin
modülü tek bir feature tanımlayabiliyor.

**Her domain kendi Cloudflare API token'ını taşır.** Global token yok — bir
Cloudflare token'ı tek bir hesaba ve onun zone'larına bağlıdır, domainler farklı
hesaplarda olabilir.

**Yetki:** root bütün domainleri yönetir; domain sahibi kendi hesabıyla girip
yalnızca kendi domaininin ayarlarını görür (`feature_webmin` + `can_edit_domain`).

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

**Cloudflare DNS:** yerel BIND zone'u model, Cloudflare yayınlanan kopya.
Yalnızca `vmkit` etiketli kayıtlara dokunulur — elle eklenenler, tüneller ve
Email Routing kayıtları hiç etkilenmez. Karşılaştırma sayfası ne olacağını
önce gösterir; kapsam dışı kayıtlar için içe aktar / sahiplen / sil düğmeleri
vardır.

Senkron elle çalıştırılabilir, ama asıl çalışma biçimi otomatiktir: modül
kurulduğunda kendi systemd birimlerini kendisi oluşturup başlatır
(`postinstall.pl`). `vmkit-cloudflare-sync.path` zone dosyası değiştiği anda
tetikler — DNS-01 wildcard doğrulaması için gereken hız buradan gelir;
`.timer` yalnızca kaçan bir olayı yakalamak için 15 dakikada bir çalışır.
Zone değişmediyse hiçbir API çağrısı yapılmaz. Modülün kendi sayfası servisin
durumunu gösterir ve durmuşsa açılışta yeniden başlatır.

**Composer:** domainin ana dizini altında `composer.json` içeren klasörleri
kendiliğinden bulur ve her birini **kendi PHP sürümüyle** çalıştırır (Virtualmin
klasör başına PHP sürümü tutabiliyor). İşlemler: install, update, dump-autoload.

**Git Deploy:** kaynak her zaman **uzak repodur** — sunucuda repo barındırmıyoruz.
Repo adresi girilip *Kontrol et* denince `git ls-remote` ile sorgulanır; dallar
listeden seçilir, ulaşılamayan bir repo hiç kaydedilmez. Bir domainde birden çok
deployment olabilir; her biri kendi hedef klasörüne çalışır.

## Yol haritası

Kurulum tarafı tamamlandıktan sonra asıl iş **Virtualmin plugin'i**: panelde
domain başına çalışan işler (git deploy, composer, Cloudflare DNS senkronu).
