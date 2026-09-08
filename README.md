# vmin-kit

**Debian 12** üzerinde Virtualmin (GPL) tabanlı bir hosting sunucusunu tek
komutla kurar. Kurulum bittiğinde ana domain hazır, SSL'li ve yayında olur;
panel, webmail ve Docker arayüzü kendi alt alanlarından erişilebilir olur.

Yanında üç Webmin eklentisi gelir: **Git Deploy**, **Composer**, **Cloudflare
DNS** — üçü de Virtualmin panelinde domain başına çalışır.

---

## 1. Kurulum

### Önce DNS

Ana domain ve hostname için **A kayıtları sunucunun IP'sini göstermeli**:

```
ornek.com        A   <sunucu-ip>
s.ornek.com      A   <sunucu-ip>
```

Cloudflare kullanıyorsanız kurulum sırasında **proxy kapalı (gri bulut)** olsun;
sertifika alındıktan sonra açabilirsiniz.

Kurulum bunu kendisi kontrol eder; yanlışsa hiçbir şey çalıştırmadan ne yapmanız
gerektiğini yazar.

### Çalıştır

```bash
git clone <repo-url>
cd vmin-kit
sudo ./install.sh
```

Tek soru sorulur: **ana domain**. Ardından kullanılacak ayarların özeti gösterilir
ve onay istenir.

Betikten çalıştırmak için domain ortam değişkeni olarak verilebilir:

```bash
MAIN_DOMAIN=ornek.com sudo -E ./install.sh
```

**Tekrar çalıştırmak zararsızdır.** Bütün adımlar idempotent: kurulu olanı atlar,
eksik olanı tamamlar. Yarıda kalan bir kurulumu sürdürmenin yolu da budur.

---

## 2. Ayarlar — `config.env`

Ana domain dışındaki her şey bu dosyadan gelir. Dosya **depoda durur**:
değiştirin, commit'leyin — sonraki sunucu depoyu çektiğinde aynı şekilde kurulur.

| Ayar | Ne yapar | Varsayılan |
|---|---|---|
| `POSTGRES` | PostgreSQL kurar (Virtualmin onu kendisi görür; veritabanı seçeneklerinde çıkar) | 1 |
| `COMPOSER` | Composer kurar (Composer eklentisinin gereksinimi) | 1 |
| `DOCKER` | Docker Engine + Portainer + `docker.<domain>` sitesi | 1 |
| `PLUGIN_DEPLOY` | Git Deploy eklentisini kurar | 1 |
| `PLUGIN_COMPOSER` | Composer eklentisini kurar | 1 |
| `PLUGIN_CLOUDFLARE` | Cloudflare DNS eklentisini kurar | 1 |
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
| `postgres` / `composer` | PostgreSQL ve Composer paketleri *(isteğe bağlı)* |
| `dns-template` | Yeni domainler için DNS varsayılanları |
| `panel-redirects` | `admin.<domain>` ve `webmail.<domain>` kısayollarını kapatır |
| `domain-defaults` | Spam/virüs taraması kapalı, SPF + DMARC açık, rol adresleri sınırlı |
| `dkim` | DKIM'i açar; bundan sonra oluşan her domain giden postayı imzalar |
| `plugins` | Eklentileri paketleyip kurar ve Virtualmin'e tanıtır |
| `main-domain` | Ana domaini Virtualmin'in kendi varsayılanlarıyla oluşturur |
| `host-dns` | Hostname için A kaydı ekler |
| `ssl` | Let's Encrypt sertifikası + otomatik yenileme |
| `panel-sites` | `webmin.` ve `usermin.` alt alanlarını yayınlar |
| `docker` | Docker + Portainer + `docker.` alt alanı *(isteğe bağlı)* |
| `webmail` | `webmail.` alt alanı + Roundcube *(isteğe bağlı)* |
| `lock-panel-ports` | Vekilin çalıştığı doğrulandıktan **sonra** panel portlarını kapatır |
| `report` | `vmin-kit-rapor.txt` üretir |

Bir adım hata verirse kurulum durmaz; o adım atlanır, kalanlar çalışır ve durum
raporda görünür.

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

1. **Raporu okuyun:** araç klasöründeki `vmin-kit-rapor.txt` — ne yapıldı, ne
   yapılmadı, sırada ne var. Başarısız olan adımlar, dışarıya açık dinleyen
   portlar ve sunucunun hangi vmin-kit sürümüyle kurulduğu da orada.
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
eklenir. Kurulum bunları ilk domaindan önce açar. DMARC `p=none` ile başlar —
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

Üçü de **domain başına** çalışır. Bir domainde kullanmak için *Edit Virtual
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

Dağıtım sonrası komutlar hedef klasörde, domainin kendi kullanıcısı olarak
çalışır. O klasörün PHP sürümü `php` adıyla hazırdır — `php artisan migrate` ve
`composer install` olduğu gibi çalışır, tam yol yazmanız gerekmez. Hata veren
ilk komutta dağıtım durur ve başarısız işaretlenir.

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

---

## 6. Yardımcı betikler

```bash
sudo ./install.sh                    # kurulum (tekrar çalıştırmak zararsız)
sudo ./update-plugins.sh             # eklentileri güncelle (git pull sonrası)
sudo ./update-plugins.sh --remove    # eklentileri kaldır
sudo ./renew-ssl.sh                  # hostname sertifikasını al/yenile
sudo ./configure-docker.sh           # Portainer kurulum ekranını yeni token'la aç
./build-plugins.sh [modül]           # eklentileri .wbm.gz olarak paketle (dist/)
```

**`renew-ssl.sh` ne zaman gerekir:** kurulum sırasında domain henüz
çözümlemiyorsa Virtualmin sertifika alamaz ve self-signed ile devam eder. DNS
oturduktan sonra bu betiği çalıştırın. Ana domain için ayrıca bir şey gerekmez —
`install.sh` tekrar çalıştırıldığında sertifikayı zaten ister.

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
renew-ssl.sh         # hostname sertifikası
configure-docker.sh  # Portainer kurulum ekranı
```
