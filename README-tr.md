# vmin-kit

*[English](README.md)*

Virtualmin (GPL) tabanlı bir hosting sunucusunu tek komutla kurar.

**Desteklenen sistemler:** Debian 12, Debian 13, Ubuntu 22.04 LTS, Ubuntu 24.04
LTS. Bunların dışındaki bir sistemde kurulum başlamadan durur
(`ALLOW_ANY_OS=1` ile zorlanabilir). Dördünde de temiz kurulum doğrulandı.

RHEL ailesi (AlmaLinux, Rocky, RHEL) **bilerek kapsam dışı**: Virtualmin
onları destekliyor ama bu araç `apt`/`dpkg` üzerine kurulu. Desteklediğini
iddia edip yarım kurulum bırakmak, hiç desteklememekten kötü olurdu.

Kurulum bittiğinde ana domain oluşmuş, sertifikası alınmış ve yayında olur;
panel, webmail ve Docker arayüzü kendi alt alanlarından erişilebilir olur.

Yanında dört Webmin eklentisi gelir: **Git Deploy**, **Composer** ve
**Cloudflare DNS** Virtualmin panelinde domain başına çalışır; **Check
vmin-kit** ise bir Webmin ya da Virtualmin güncellemesinin bunlardan birini
bozup bozmadığını panelden söyler.

---

## 1. Kurulum

### Önce DNS

Ana domain ve hostname için **A kayıtları sunucunun IP'sini göstermeli**:

```
ornek.com        A   <sunucu-ip>
s.ornek.com      A   <sunucu-ip>
```

Cloudflare kullanıyorsanız kurulum sırasında **proxy kapalı (gri bulut)**
olsun; sertifikalar alındıktan sonra açabilirsiniz.

Kurulum bunu kendisi kontrol eder; yanlışsa hiçbir şey çalıştırmadan ne
yapmanız gerektiğini yazar.

### Çalıştır

```bash
git clone <repo-url>
cd vmin-kit
sudo ./install.sh
```

Tek soru sorulur: **ana domain**. Ardından kullanılacak ayarların özeti
gösterilir ve onay istenir.

Betikten çalıştırmak için domain ortam değişkeni olarak verilebilir:

```bash
MAIN_DOMAIN=ornek.com sudo -E ./install.sh
```

**Tekrar çalıştırmak zararsızdır.** Bütün adımlar idempotent: kurulu olanı
atlar, eksik olanı tamamlar. Yarıda kalan bir kurulumu sürdürmenin yolu da
budur.

### Kurulum kaydı

Ekranda yalnızca adımların sonucu görünür; çalıştırılan komutların ayrıntılı
çıktısı `vmin-kit-install-<tarih>.log` dosyasına yazılır. Dosya her kurulumda
oluşur, ayrıca bir seçenek gerekmez. Bir adım başarısız olursa ekranda bu
görünür, sebebi de kayıtta durur.

Tek istisna Virtualmin kurucusudur: dakikalarca sürdüğü için çıktısı ekranda
da akar.

Her şeyi ekranda görmek isterseniz:

```bash
sudo ./install.sh --verbose
```

---

## 2. Ayarlar — `config.env`

Ana domain dışındaki her şey bu dosyadan gelir. Dosya **depoda durur**:
değiştirin, commit'leyin — sonraki sunucu depoyu çektiğinde aynı şekilde
kurulur.

| Ayar | Ne yapar | Varsayılan |
|---|---|---|
| `POSTGRES` | PostgreSQL kurar (Virtualmin onu kendisi görür; veritabanı seçeneklerinde çıkar) | 1 |
| `COMPOSER` | Composer kurar (Composer eklentisinin gereksinimi) | 1 |
| `DOCKER` | Docker Engine + Portainer + `docker.<domain>` sitesi | 1 |
| `PLUGIN_DEPLOY` | Git Deploy eklentisini kurar | 1 |
| `PLUGIN_COMPOSER` | Composer eklentisini kurar | 1 |
| `PLUGIN_CLOUDFLARE` | Cloudflare DNS eklentisini kurar | 1 |
| `PLUGIN_CHECK` | Check VminKit eklentisini kurar | 1 |
| `PANEL_PROXY` | `webmin.<domain>` ve `usermin.<domain>` alt alanlarını yayınlar | 1 |
| `LOCK_PANEL_PORTS` | 10000/20000 portlarını yalnızca `127.0.0.1`'e bağlar | 1 |
| `ROUNDCUBE` | `webmail.<domain>` alt sunucusu + Roundcube | 1 |
| `ROLE_ALIASES` | Yeni domainlerde açık kalacak rol adresleri | `postmaster abuse` |
| `NO_ADMIN_REDIRECT` | Virtualmin'in `admin.<domain>` → panel kısayolunu kapatır | 1 |
| `NO_WEBMAIL_REDIRECT` | `webmail.<domain>` → Usermin kısayolunu kapatır | 1 |
| `HOST_PREFIX` | Hostname ve panel adı | `s` |
| `NS1_PREFIX` / `NS2_PREFIX` | Zone'un nameserver çifti | `ns1` / `ns2` |
| `DOCKER_PREFIX` `WEBMIN_PREFIX` `USERMIN_PREFIX` `WEBMAIL_PREFIX` | Arayüzlerin alt alan adları | `docker` `webmin` `usermin` `webmail` |
| `PORTAINER_IMAGE` / `PORTAINER_PORT` | Portainer konteyneri | `ce:lts` / `9000` |
| `PORTAINER_BIND_LOCAL` | Portainer portunu `127.0.0.1`'e bağlar (erişim ters vekil üzerinden) | `yes` |

Eklenti bayrağını 0 yapmak **kurulu olanı sökmez**, yalnızca kurmaz. Kaldırmak
için: `sudo ./update-plugins.sh --remove`.

Dosyanın sonunda kaçış kapıları var (`SKIP_DNS_CHECK`, `ALLOW_ANY_OS`,
`SERVER_IP`, `DNS_RESOLVER`) — normalde gerekmez, yorum satırında dururlar.

---

## 3. Kurulum ne yapar

| Adım | Ne yapar |
|------|----------|
| `hostname` | Hostname'i `s.<domain>` yapar |
| `virtualmin` | Resmi installer ile Virtualmin kurar |
| `host-domain` | Hostname sanal sunucusu (sunucunun varsayılan sitesi ve servis sertifikalarının kaynağı); sertifika alınamasa da oluşturulur |
| `postgres` / `composer` | PostgreSQL ve Composer paketleri *(isteğe bağlı)* |
| `dns-template` | Yeni domainler için DNS varsayılanları |
| `panel-redirects` | `admin.<domain>` ve `webmail.<domain>` kısayollarını kapatır |
| `domain-defaults` | SPF + DMARC açık, rol adresleri sınırlı |
| `dkim` | DKIM'i açar; bundan sonra oluşan her domain giden postayı imzalar |
| `hardening` | Sunucu geneli: Postfix VRFY'yi kapatır ve AUTH'u TLS sonrasına bırakır, Dovecot TLS'siz bağlantıda düz-metin girişi yasaklar, BIND sürümünü gizler, Apache her vhost'a HSTS ve nosniff gönderir |
| `plugins` | Eklentileri paketleyip kurar ve Virtualmin'e tanıtır |
| `main-domain` | Ana domaini açık bir özellik listesiyle oluşturur (spam/virüs ve PostgreSQL hariç — onlara kurulum sihirbazı karar verir) |
| `host-dns` | Hostname için A kaydı ekler |
| `ssl` | Let's Encrypt sertifikası + otomatik yenileme |
| `panel-sites` | `webmin.` ve `usermin.` alt alanlarını yayınlar |
| `webmail` | `webmail.` alt alanı + Roundcube *(isteğe bağlı)* |
| `docker` / `portainer` / `docker-site` | Docker Engine, Portainer konteyneri ve `docker.` alt alanı *(isteğe bağlı)* |
| `lock-panel-ports` | Vekilin çalıştığı doğrulandıktan **ve** alt alanın geçerli sertifikası olduğu görüldükten sonra panel portlarını kapatır |
| `report` | Özeti ekrana ve kurulum kaydına yazar |

Bir adım hata verirse kurulum durmaz; o adım atlanır, kalanlar çalışır ve durum
raporda görünür.

**Sertifika ve port ilişkisi.** Her alt alan (`webmin.`, `usermin.`,
`webmail.`, `docker.`) oluşturulduğu adımda sertifikası kontrol edilir; yoksa
bir kez daha istenir. Sertifika alınamazsa — DNS henüz yayılmamışsa ya da
Let's Encrypt kotası dolmuşsa — **o servisin yönetim portu dışarıya
kapatılmaz**: tarayıcı self-signed sertifikalı vekil adresine güvenmeyeceği
için port da kapanırsa hiçbir erişim yolu kalmaz. Engel kalktığında
`./install.sh` tekrar çalıştırıldığında sertifika istenir ve port kapatılır.

---

## 4. Kurulumdan sonra

### Adresler

| Adres | Ne |
|---|---|
| `https://webmin.<domain>` | Virtualmin / Webmin paneli |
| `https://usermin.<domain>` | Usermin (kullanıcı arayüzü) |
| `https://webmail.<domain>` | Roundcube |
| `https://docker.<domain>` | Portainer |
| `https://s.<domain>:10000` | Panelin doğrudan adresi — `LOCK_PANEL_PORTS=1` ise kapalıdır |

Dışarıya açık yönetim portu bırakılmaz: Webmin, Usermin ve Portainer
`127.0.0.1`'de dinler, dışarıya Apache üzerinden kendi sertifikalarıyla çıkar.

### İlk yapılacaklar

1. **Özeti okuyun:** kurulum bitince ekrana basılır — ne yapıldı, ne yapılmadı,
   sırada ne var. Başarısız olan adımlar, dışarıya açık dinleyen portlar ve
   sunucunun hangi vmin-kit sürümüyle kurulduğu da oradadır. Aynısı kurulum
   kaydının sonunda durur.
2. **Ana domain şifresi** rastgele üretilir ve **saklanmaz**. Panel girişi ya da
   FTP gerekirse *Edit Virtual Server → Password* ile yeni şifre belirleyin.
3. **Portainer** ilk açılışta bir kurulum token'ı ister ve token kısa ömürlüdür.
   Token kurulum çıktısındadır; kaçırırsanız `sudo ./configure-docker.sh`.
4. **BIND modundaysanız** registrar tarafında `ns1` / `ns2` için glue kaydı
   gerekir.

### Posta

Domain sahibinin unix hesabı aynı zamanda bir posta kutusudur ve rol adresleri
(postmaster, abuse) oraya düşer. Kendi adreslerinizi ayrı kutular olarak açın
(*Edit Users → Add a user to this server*). Kullanıcı adı e-posta adresinin
kendisidir; webmail'e tam adresle girilir.

Giden postalar DKIM ile imzalanır; SPF ve DMARC kayıtları da her yeni domaine
eklenir. Kurulum bunları ilk domainden önce açar. DMARC `p=none` ile başlar —
birkaç hafta sonra panelden `quarantine`'e sıkabilirsiniz.

### DNS

Araç, domainin NS kayıtlarına bakıp modu kendisi tespit eder:

- **Harici DNS** (Cloudflare vb.) — A kayıtlarını orada yönetirsiniz; Cloudflare
  eklentisi yerel zone'u oraya senkronlayabilir.
- **BIND** — sunucu otoriter, kayıtlar panelden yönetilir.

İki modda da yerel zone her zaman üretilir ve nameserver çifti
`ns1.<domain>` / `ns2.<domain>`'dir.

---

## 5. Eklentiler

İlk üçü **domain başına** çalışır. Bir domainde kullanmak için *Edit Virtual
Server* içinde ilgili onay kutusu açık olmalı (yeni domainlerde varsayılan
açıktır). Açıkken sol menüde domainin altında görünürler.

Root bütün domainleri yönetir; domain sahibi kendi hesabıyla girip yalnızca
kendi domainini görür.

### Git Deploy

Uzak bir git reposundan sunucuya deploy eder — repo sunucuda barındırılmaz.

1. **Git Deploy → Add a deployment.**
2. Repo adresini yazıp **Kontrol et** deyin; ulaşılabiliyorsa dallar listeden
   seçilir, ulaşılamıyorsa kayıt hiç oluşmaz.
3. **Hedef dizin:** web dizininin altındaki bir klasör. Formda sabit önek
   (`/home/<kullanıcı>/public_html/`) yazar, siz yalnızca alt klasörü
   yazarsınız; boş bırakırsanız o dizinin kendisine deploy edilir.
4. **Dağıtım modu:** *Manuel* — çekmek siteye dokunmaz, dağıtımı siz
   başlatırsınız. *Otomatik* — her çekmeden hemen sonra dağıtır.
5. İsterseniz **dağıtım sonrası komutlar** yazın (her komut ayrı satırda).

**Çekme ve dağıtım ayrı işlemlerdir.** Çekme uzak repodan yerel kopyaya alır,
site değişmez; **Commits** sayfasından ne geldiğine bakıp sonra **Dağıt**
dersiniz. Listedeki *Durum* sütunu yayındaki ve çekilmiş commit'i ayrı gösterir,
yani bekleyen bir dağıtım olduğunu oradan görürsünüz. **Log** son işlemin
çıktısıdır.

Dağıtım sonrası komutlar hedef klasörde, domainin kendi kullanıcısı olarak bir
kabuk betiği gibi çalışır — tek oturumdur, yani bir satırdaki `cd` sonraki
satırda da geçerlidir ve `if` / `for` gibi çok satırlı yapılar çalışır. O
klasörün PHP sürümü `php` adıyla hazırdır, bu yüzden `php artisan migrate` ve
`composer install` olduğu gibi çalışır, tam yol yazmanız gerekmez. Hata veren
ilk komutta dağıtım durur ve başarısız işaretlenir; çalışan her komut log'a
yazılır.

**Web kancası.** Formda her deployment için bir kanca adresi görünür:
`https://webmin.<ana-domain>/vmkit-deploy/nph-hook.cgi?uuid=...`. Bu adresi git
sunucunuzun webhook ayarına yazın — sağlayıcı fark etmez (GitHub, GitLab,
Gitea) ve `curl` ile elle de çağırabilirsiniz. Çağrıldığında dağıtım moduna
uyar: otomatikse çeker ve dağıtır, manuelse yalnızca çeker.

Adresteki UUID **paroladır**: giriş istemez, adresi bilen tetikler. Sunucu
loglarına düştüğü için paylaşmayın; sızarsa formdaki "yeni adres üret" ile
eskisi anında geçersiz olur.

Özel (private) repolar için **Domain SSH key** sayfasındaki açık anahtarı
GitHub'da **hesabınıza** ekleyin (Settings → SSH keys). Tek bir repoya deploy
key olarak eklemeyin: GitHub bir deploy anahtarını yalnızca tek repoda kabul
eder, ikinci özel repo eklendiğinde tıkanır.

Uygulama bir alt klasörden yayın yapıyorsa (Laravel gibi) Virtualmin'in kendi
ayarını kullanın: *Website Options → Website documents sub-directory =
`public_html/public`*. Deploy kökü yine `public_html` kalır.

### Composer

Web dizini altında `composer.json` içeren klasörleri kendiliğinden bulur ve her
birini **kendi PHP sürümüyle** çalıştırır (Virtualmin klasör başına PHP sürümü
tutabilir).

- **İşlemler:** install, update, dump-autoload.
- **Paketler** sayfası kurulu paketleri, son sürümlerini ve güncellenebilir
  olanları listeler — yalnızca okur, bir şey değiştirmez.

Komutlar varsayılan olarak `--no-dev --optimize-autoloader` ile çalışır, yani
Composer'ın üretim için önerdiği biçimde: geliştirme paketleri kurulmaz ve
otoyükleyici hızlandırılır. Bir projede geliştirme paketlerine ihtiyacınız
varsa modül ayarlarından kapatabilirsiniz — ayar sunucu geneli, tek bir proje
için istisna yapılamaz.

Ev dizininin tamamı değil yalnızca web dizini taranır; alt sunucuların dizinleri
kendi panellerinde görünür.

### Cloudflare DNS

Yerel BIND zone'u modeldir, Cloudflare yayınlanan kopyadır.

1. **Cloudflare DNS** sayfasında domainin **API token**'ını girin. Token domain
   başınadır — her domain kendi hesabının token'ını taşır.
2. **Senkronizasyon** anahtarı o domainin takibini açıp kapatır; token kayıtlı
   kalır. Token boşsa domain zaten işleme alınmaz.
3. **Local zone vs Cloudflare** sayfası ne olacağını **önce gösterir**, hiçbir şey
   yazmaz. Kapsam dışı kayıtlar için içe aktar / sahiplen / sil düğmeleri vardır.
   Proxy sütunundaki duruma tıklayarak turuncu/gri bulutu değiştirebilirsiniz.

Yalnızca `vmkit` etiketli kayıtlara dokunulur: elle eklediğiniz kayıtlar,
tüneller ve Email Routing kayıtları etkilenmez.

Senkron elle çalıştırılabilir ama asıl çalışma biçimi otomatiktir: eklenti
kurulduğunda kendi systemd birimlerini oluşturur, zone dosyası değiştiği anda
tetiklenir ve ayrıca 15 dakikada bir kontrol eder. Zone değişmediyse hiçbir API
çağrısı yapılmaz. Eklentinin ana sayfası servisin durumunu gösterir ve durmuşsa
yeniden başlatır.

### Check VminKit

*System Settings → Check VminKit.* Üç eklenti Virtualmin'i, Webmin'in arayüz
kütüphanesini ve birkaç Webmin modülünü çağırır; hiçbiri kararlı bir arayüz
vaat etmez. Bir güncelleme bir fonksiyonun adını değiştirebilir ya da bir
kancayı çağırmayı bırakabilir, ve eklenti ancak biri sayfayı açtığında bozulur.
Bu eklenti bunu önce öğrenir.

Eklentilerin kendi kaynağını tarayıp çağırdıkları her şeyi çalışan sistemde
arar, uyguladıkları her kancanın Virtualmin tarafından hâlâ çağrıldığını
denetler ve her eklentinin çalışmak için ihtiyaç duyduğunu doğrular: kancanın
Webmin kullanıcısı ve anonim erişim girdisi, Cloudflare senkron birimleri,
`composer` komutu. Yapabildiği yerde bir **Onar** düğmesi düzeltir.

Çalıştırmayı hatırlamanız gerekmez: bir Webmin ya da Virtualmin
güncellemesinden sonra (ve günde bir kez) kontroller Virtualmin panosu
açıldığında kendiliğinden yeniden çalışır ve bir hata orada uyarı olarak
görünür. Sayfanın kendisi yalnızca son sonucu gösterir.

---

## 6. Yardımcı betikler

```bash
sudo ./install.sh                    # kurulum (tekrar çalıştırmak zararsız)
sudo ./update-plugins.sh             # eklentileri güncelle (git pull sonrası)
sudo ./update-plugins.sh --remove    # eklentileri kaldır
sudo ./configure-docker.sh           # Portainer kurulum ekranını yeni token'la aç
./build-plugins.sh [modül]           # eklentileri .wbm.gz olarak paketle (dist/)
```

**DNS sonradan oturduysa:** ayrı bir betik yok, `sudo ./install.sh` yeter.
Hostname dahil bütün adresler için sertifikası olmayanlar tekrar istenir,
alındığında yönetim portları kapatılır.

**`update-plugins.sh` ne yapar:** eklenti dosyalarını doğrudan Webmin'in modül
dizinine kopyalar. Derleme yoktur, sayfayı yenilemeniz yeterlidir. Geliştirme
döngüsü: `git pull && sudo ./update-plugins.sh`.

---

## 7. Sorun giderme

**Panele erişemiyorum — portlar kilitli, vekil de çalışmıyor.**
SSH ile girin, `/etc/webmin/miniserv.conf` içindeki `bind=` satırını silin ve
`systemctl restart webmin` deyin. Panel yine `:10000`'den açılır.

**Sertifika alınamadı, self-signed kaldı.**
DNS'in sunucuyu gösterdiğinden emin olun (Cloudflare'de gri bulut), sonra
`sudo ./install.sh` tekrar çalıştırın.

**Portainer kurulum ekranı "timed out" diyor.**
`sudo ./configure-docker.sh` — konteyneri yeniden başlatır ve yeni token verir.

**Cloudflare senkronu çalışmıyor.**
Eklentinin ana sayfasındaki servis durumuna bakın; durmuşsa sayfa açıldığında
yeniden başlatılır. Ayrıca: `systemctl status vmkit-cloudflare-sync.path`.

**Bir kurulum adımı hata verdi.**
Hatayı düzeltip `sudo ./install.sh` tekrar çalıştırın; tamamlanmış adımlar
atlanır.

---

## 8. Dosya düzeni

```
install.sh           # tek giriş noktası
config.env           # ayarlar (depoda tutulur)
lib/common.sh        # yardımcı fonksiyonlar
lib/steps.sh         # kurulum adımları
plugin/              # Webmin eklentilerinin kaynağı
build-plugins.sh     # plugin/ -> dist/<modül>.wbm.gz
update-plugins.sh    # eklentileri sunucuya kopyala (geliştirme)
configure-docker.sh  # Portainer kurulum ekranı
```
