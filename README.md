# VirtualminPatch

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
cd VirtualminPatch
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
| `ssl` | Ana domain için Let's Encrypt sertifikası + otomatik yenileme. |
| `docker` | Docker Engine (resmi Debian deposu). *(isteğe bağlı)* |
| `portainer` | Portainer CE, varsayılan olarak sadece localhost'a bağlı. *(isteğe bağlı)* |
| `report` | `/root/vmpatch-rapor.txt` + ikinci sunucu için `config.env` üretir. |

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
```

## Kurulum sonrası

- Panel: `https://s.<domain>:10000`
- Ana domain sahibinin şifresi: `/root/.vmpatch-domain-pass`
- Rapor: `/root/vmpatch-rapor.txt`

## Yol haritası

Kurulum tarafı tamamlandıktan sonra asıl iş **Virtualmin plugin'i**: panelde
domain başına çalışan işler (git deploy, composer, Cloudflare DNS senkronu).
