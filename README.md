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
| `panel-redirects` | Virtualmin'in her domaine eklediği iki kısayolu kapatır: `admin.<domain>` → panel (`:10000`) ve `webmail.<domain>` → Usermin (`:20000`). Bayraklar: `NO_ADMIN_REDIRECT`, `NO_WEBMAIL_REDIRECT` (ikisi de varsayılan 1). Her anahtar hem DNS kaydını hem Apache yönlendirmesini kapatıyor; **domain oluşmadan önce** çalışmalı, sonradan kapatmak var olanları temizlemiyor. |
| `domain-defaults` | İlk domain oluşmadan önce Virtualmin varsayılanları: **spam ve virüs taraması kapalı** (kurulum sonrası sihirbaz da bunları kapalı öneriyor; domain onlarla oluşursa sihirbaz kapatmaya izin vermiyor) ve `append_style=6` — posta kutusu adları `<ad>@<domain>` olur, webmail'e **e-posta adresiyle** girilir; ve rol adresleri `admin@<domain>`'a yönlenir (`newdom_aliases`). |
| `plugins` | Eklentileri `.wbm.gz` olarak paketleyip Webmin'in `install-module.pl`'i ile kurar, Virtualmin'in `plugins=` listesine ekler. Hangileri: `PLUGIN_*` bayrakları. |
| `main-domain` | Ana domaini **Virtualmin'in kendi varsayılanlarıyla** oluşturur (`--default-features`) — panelden açtığın domainlerle birebir aynı. Açılan özellikler kurulum kaydına yazılır. |
| `admin-mailbox` | `admin@<domain>` posta kutusunu açar ve **domain sahibinin kutusunu kapatır** — site kullanıcısı ile posta kutusu ayrılır. Rol adresleri (postmaster, abuse, hostmaster, webmaster) `domain-defaults` sayesinde zaten bu kutuya yönlenmiştir. Şifre rastgele üretilir ve saklanmaz. |
| `host-dns` | Ana domainin zone'una hostname (`s.<domain>`) için A kaydı ekler. |
| `ssl` | Ana domain için Let's Encrypt sertifikası + otomatik yenileme. |
| `panel-sites` | Webmin ve Usermin'i ana domain altında birer alt alan olarak yayınlar: `webmin.<domain>` → `127.0.0.1:10000`, `usermin.<domain>` → `127.0.0.1:20000`. `PANEL_PROXY=1`. |
| `docker` | Docker Engine + Portainer CE + `docker.<domain>` proxy sitesi. Tek bayrak (`DOCKER=1`); üçü birlikte gelir. *(isteğe bağlı)* |
| `webmail` | `webmail.<domain>` alt sunucusu + Virtualmin'in kendi Install Scripts'i ile **Roundcube**. Domain sahibinin kimlik adresi Postfix'in `virtual` haritasından çözülür (`virtuser_file` eklentisi). `ROUNDCUBE=1`. |
| `lock-panel-ports` | Vekilin çalıştığı **doğrulandıktan sonra** 10000/20000 portlarını yalnızca `127.0.0.1`'e bağlar. `LOCK_PANEL_PORTS=1`. Doğrulanamazsa kilitlemez. |
| `report` | Araç klasörüne `vmin-kit-rapor.txt` üretir: ne yapıldı, panel adresi, sırada ne var. |

Tüm adımlar **idempotent**: ikinci kez çalıştırmak zarar vermez, kurulu olanı atlar.

### Ana domainde ne açık?

Ana domain `--default-features` ile oluşturuluyor: panelden **Create Virtual
Server** dediğinde ne açılıyorsa aynısı. Ana domain böylece özel bir durum
olmuyor; sonradan panelden açtığın domainlerle aynı şekilde kuruluyor. Üç
eklentimiz de o listede (`plugins_inactive`'e yazmadığımız için yeni
domainlerde varsayılan açıklar) — bu yüzden `plugins` adımı `main-domain`'den
**önce** çalışıyor.

Sonuç Virtualmin'in global yapılandırmasından geliyor, ama pratikte sunucudan
sunucuya değişmiyor: post-install sihirbazı panele **ilk girişte** çalışır,
kurulum ise domaini ondan önce CLI'dan oluşturur. Yani okunan değerler
Virtualmin'in paketten gelen varsayılanlarıdır, sihirbaz cevapları değil.
Yine de varsayım yapmamak için açılan özellik ve eklenti listesi hem kurulum
çıktısına hem rapora yazılıyor.

Posta açıksa Virtualmin zone'a `mail.<domain>` A kaydı ve MX ekler. Ayrıca
domain sahibi unix kullanıcısı o anda bir posta kutusuna dönüşür: adresi
`<kullanıcı>@<domain>` olur (`blnk.tr` için `blnk@blnk.tr`). Ayrı bir hesap
açılmaz, var olan hesap adres kazanır. Şifresi kurulumda rastgele üretilip
**atıldığı** için kutuyu kullanmadan önce panelden bir şifre belirlemek
gerekir: **Edit Virtual Server → Password**.

`webmail.<domain>` kısayolu posta açık olsa bile kapalıdır
(`NO_WEBMAIL_REDIRECT=1`); Usermin'e panel adresinden girilir.

### Yönetim arayüzleri neden port değil alt alan?

Dışarıya açık yönetim portu bırakmıyoruz. Webmin, Usermin ve Portainer
`127.0.0.1`'de dinler; dışarıya Apache üzerinden, her biri kendi alt alanı ve
kendi sertifikasıyla çıkar:

| Adres | Arkasında |
|---|---|
| `webmin.<ana-domain>` | `127.0.0.1:10000` |
| `usermin.<ana-domain>` | `127.0.0.1:20000` |
| `docker.<ana-domain>` | `127.0.0.1:9000` (Portainer) |

Üçü de aynı kalıp (`ensure_proxy_site`): alt sunucu + `create-proxy --websockets`.
Webmin ve Usermin kendi SSL'lerinde kalır, vekil onlara `https://127.0.0.1:<port>`
ile gider.

Tek ek ayar **güvenilen referer**: adres `/etc/webmin/config` içindeki `referers`
satırına eklenir (panelde Webmin Configuration → Trusted Referrers). Referer
kontrolü adı **ve portu** karşılaştırıyor; referer 443'ten, panel kendi
portundan (10000) geldiği için eşleşmiyor ve istek "Security Warning" ile
reddediliyor. Bunun dışında Virtualmin'in getirdiği ayarlara dokunulmaz.

**Kilitleme adımı en sonda ve koşulludur.** `bind=127.0.0.1` yazıldıktan sonra
panele tek erişim vekil üzerindedir; bu yüzden önce vekilin gerçekten cevap
verdiği doğrulanır (`curl --resolve` ile doğrudan yerel Apache'ye, DNS'e
bağlı olmadan). Doğrulanamazsa port kapatılmaz. Kurtarma: SSH ile
`/etc/webmin/miniserv.conf` içindeki `bind=` satırını silip
`systemctl restart webmin`.

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
lib/common.sh        # yardımcılar (log, ask, set_kv, detect_ip, resolve_a/ns, webmin/plugins)
lib/steps.sh         # adım fonksiyonları (install.sh açık sırayla çağırır)
plugin/              # Webmin modüllerinin kaynağı (düzenlenen yer)
build-plugins.sh     # plugin/ → dist/<modül>.wbm.gz  (dist/ depoda tutulmaz)
update-plugins.sh    # GELİŞTİRME döngüsü: dosyaları doğrudan /usr/share/webmin'e kopyalar
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

**Kurulum — `install.sh` hallediyor.** `step_plugins` modülleri kurulum anında
kaynaktan `.wbm.gz` olarak paketler (`build-plugins.sh`) ve Webmin'in kendi
`install-module.pl`'i ile kurar. Bu standart yol; dosyaları yerine koymak,
`webmin.acl`, `/etc/webmin/<modül>/config` (mevcut değerleri koruyarak
birleştirir), önbellek temizliği ve `postinstall.pl` hepsi ona ait.
Virtualmin'in `plugins=` listesine ekleme onda yok, onu `install.sh` yapıyor.

Hangilerinin kurulacağı `config.env`'den: `PLUGIN_DEPLOY`, `PLUGIN_COMPOSER`,
`PLUGIN_CLOUDFLARE` (varsayılan 1). **0 yapmak kurulu olanı sökmez**, yalnızca
kurmaz — kaldırmak için `sudo ./update-plugins.sh --remove`.

Paketler depoda tutulmaz, her zaman kaynaktan üretilir; `dist/` altında durur.
Elle paketlemek için: `./build-plugins.sh` (ya da tek modül adıyla).

**Geliştirme döngüsü:** `git pull && sudo ./update-plugins.sh`. Bu script
paketlemeyi atlayıp dosyaları doğrudan `/usr/share/webmin/` altına **kopyalar**
(symlink değil — symlink olsaydı Webmin'in yazdıkları git deposunu kirletirdi).
Webmin her
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
