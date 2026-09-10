#!/usr/bin/env bash
# Adim fonksiyonlari. install.sh bunlari ACIK SIRAYLA cagirir.
# Gerekli degiskenler install.sh tarafindan set edilir / config.env'den gelir:
#   MAIN_DOMAIN, HOSTNAME_FQDN, NS1, NS2, DNS_MODE, POSTGRES,
#   docker, portainer, PORTAINER_*
# Hepsi idempotent: ikinci kez calistirmak zarar vermez.

# Not: ayri bir rapor dosyasi (vmin-kit-rapor.txt) YOK. Ozet artik dogrudan
# ekrana ve kurulum kaydina yaziliyor - bkz. step_report.

# Basarisiz adimlarin listesi. Adimlar 'set +e' altinda calisiyor: biri hata
# verirse kurulum devam ediyor ve ekranda tek bir kirmizi satir kaliyor. Uzun
# bir kurulumda o satir kaybolur, o yuzden sonuclari topluyoruz - hem kapanista
# hem raporda yaziliyor.
VMINKIT_FAILED=()

# run_step <adim-fonksiyonu>
# Adimi calistirir, basarisiz olursa adi listeye yazar. Donus degerini aynen
# geciriyor ki cagiran taraf isterse ayrica bakabilsin.
#
# Donus kodu 'if "$fn"; then' ile YAKALANMAZ: basarisiz ve else'siz bir if
# bilesik komutu 0 dondurdugu icin $? o noktada adimin degil if'in sonucudur.
# '|| rc=$?' dogrudan komutun kodunu aliyor.
#
# Ekranda yalnizca bizim satirlarimiz oldugu icin, bir adim basarisiz olunca
# SEBEBI de gostermek gerekiyor - yoksa "basarisiz" yazip susan bir ekran
# kullaniciyi log dosyasini acmaya mahkum eder.
#
# Adimin ciktisini ayri bir dosyaya toplamiyoruz: log dosyasinin adim
# oncesindeki BOYUTUNU olcup sonrasini okuyoruz. Boylece o adima ait kisim
# tam olarak elimizde oluyor, gecici dosya da gerekmiyor.
run_step(){
  local fn="$1" rc=0 start=0
  if [ -n "${VMINKIT_LOGFILE:-}" ] && [ -f "$VMINKIT_LOGFILE" ]; then
    start="$(wc -c < "$VMINKIT_LOGFILE")"
  fi
  "$fn" || rc=$?
  if [ "$rc" -ne 0 ]; then
    VMINKIT_FAILED+=("${fn#step_}")
    if [ -n "${VMINKIT_LOGFILE:-}" ] && [ -f "$VMINKIT_LOGFILE" ]; then
      local tailtxt
      tailtxt="$(tail -c "+$((start + 1))" "$VMINKIT_LOGFILE" |
                 grep -v '^[[:space:]]*$' | tail -12)"
      if [ -n "$tailtxt" ]; then
        say "    ---- ${fn#step_}: son satirlar ----"
        printf '    %s\n' "$tailtxt" >&3
        say "    ---- tamami: $VMINKIT_LOGFILE ----"
      fi
    fi
  fi
  return "$rc"
}

# Araci ureten surum: 12 ay sonra "bu sunucu hangi vmin-kit ile kuruldu"
# sorusunun cevabi. Depo yoksa (arsivden acilmissa) bilinmiyor deriz.
vminkit_version(){
  local v
  v="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$v" ] || { printf 'bilinmiyor'; return; }
  # '-uno': IZLENMEYEN dosyalar sayilmaz. Yoksa kurulumun kendi biraktigi bir
  # dosya (eski vmin-kit-rapor.txt gibi) yuzunden, kodda hicbir degisiklik
  # olmadigi halde "degistirilmis" yaziyordu. Bu satirin tek isi "bu sunucu
  # hangi vmin-kit ile kuruldu" sorusuna cevap vermek; yanlis alarm degeri
  # dusuruyor.
  if [ -n "$(git -C "$ROOT_DIR" status --porcelain -uno 2>/dev/null)" ]; then
    v="$v (degistirilmis calisma kopyasi)"
  fi
  printf '%s' "$v"
}

step_hostname(){
  local cur; cur="$(hostname -f 2>/dev/null || hostname)"
  if [ "$cur" = "$HOSTNAME_FQDN" ]; then ok "Hostname zaten $HOSTNAME_FQDN."; return; fi
  log "Hostname -> $HOSTNAME_FQDN (eski: $cur)"
  hostnamectl set-hostname "$HOSTNAME_FQDN"
  local ip short; ip="$(detect_ip)"; short="${HOSTNAME_FQDN%%.*}"
  if ! grep -q "[[:space:]]$HOSTNAME_FQDN\([[:space:]]\|$\)" /etc/hosts; then
    printf '%s %s %s\n' "${ip:-127.0.1.1}" "$HOSTNAME_FQDN" "$short" >> /etc/hosts
  fi
  ok "Hostname ayarlandi."
}

step_virtualmin(){
  if command -v virtualmin >/dev/null 2>&1; then ok "Virtualmin zaten kurulu (atlaniyor)."; return; fi
  ensure_pkg curl curl || { err "curl kurulamadi."; return 1; }
  # ADRES ONEMLI: 'install.sh', 'virtualmin-install.sh' DEGIL.
  #
  # Eski ad hala servis ediliyor ama BIR SURUMDE DONMUS: VER=7.5.2, 1716
  # satir, desteklenen sistemler "Debian 10, 11 and 12". Guncel olan
  # 'install.sh': VER=8.1.2, 2281 satir, "Debian 12 and 13" (arm64 dahil).
  # Ikisi de indirilip karsilastirildi.
  #
  # Sonucu suydu: kurulum bir yil eski Virtualmin 7.5.2 yukluyordu ve sunucu
  # ancak sonradan apt ile 8.x'e cikiyordu. Debian 13'un onundeki engel de
  # bizim OS kontrolumuz degil, indirdigimiz bu eski dosyaydi.
  #
  # Kullandigimiz iki bayrak yeni surumde de aynen var ve ayni sekilde
  # ayristiriliyor (--hostname|-n deger alir, --force|-f|--yes|-y onay atlar).
  # Yenisinde ayrica --minimal/--bundle/--include/--extra var; eski notumuz
  # "bu bayraklar servis edilen surumde yok" diyordu, o not artik gecersiz.
  log "Virtualmin resmi installer indiriliyor..."
  curl -fsSL https://software.virtualmin.com/gpl/scripts/install.sh -o /root/virtualmin-install.sh
  chmod +x /root/virtualmin-install.sh
  local args=(--force --hostname "$HOSTNAME_FQDN")
  # TEK ISTISNA: bu komutun ciktisi EKRANDA da gorunuyor. Dakikalarca surdugu
  # icin sessiz bir ekran "takildi mi" hissi verir; ustelik en cok burada bir
  # seyin ters gittigini anlamak isteriz. Geri kalan tum adimlarin ciktisi
  # yalnizca log dosyasina gidiyor.
  log "Calistiriliyor (uzun surer, cikti ekranda): virtualmin install.sh ${args[*]}"
  run_visible sh /root/virtualmin-install.sh "${args[@]}"
  ok "Virtualmin kurulumu bitti."
}

# Domainin ACME (Lets Encrypt) sertifikasi var mi?
# Etikete guvenilmez: list-domains ciktisindaki satir adi Virtualmin surumune
# gore degisiyor ("Lets Encrypt cert issued" / "SSL provider cert issued").
# O yuzden once dosya sistemine, sonra dar bir ifadeye bakiyoruz.
domain_has_acme_cert(){
  local d="$1"
  [ -s "/etc/letsencrypt/live/$d/cert.pem" ] && return 0
  virtualmin list-domains --domain "$d" --multiline 2>/dev/null \
    | grep -i 'cert issued' >/dev/null && return 0
  return 1
}

# PostgreSQL Virtualmin kurulumuyla GELMEZ; paketi ayrica kuruyoruz.
step_postgres(){
  if command -v psql >/dev/null 2>&1; then
    ok "PostgreSQL zaten kurulu."
  else
    log "PostgreSQL kuruluyor..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
    # SONUCU DOGRULA: adimlar 'set +e' altinda calisiyor, basarisiz bir
    # apt-get sessizce geciliyordu ve asagidaki satir yine "kuruldu" diyordu.
    if ! command -v psql >/dev/null 2>&1; then
      err "PostgreSQL kurulamadi (psql bulunamadi)."
      return 1
    fi
    ok "PostgreSQL kuruldu. Virtualmin ilk oturum sihirbazinda secilebilir olacak."
  fi
  # Ozelligi ayrica acmaya gerek yok: Virtualmin kurulu PostgreSQL'i kendisi
  # goruyor ve ilk oturum sihirbazinda veritabani secenekleri arasinda sunuyor.
  # (set-global-feature denemesi ise yaramiyor; taze kurulumda clamd henuz
  # ayakta olmadigi icin Virtualmin'in genel yapilandirma kontrolune takiliyor.)
  systemctl enable --now postgresql 2>/dev/null || warn "postgresql servisi baslatilamadi."
}

# Composer Virtualmin kurulumuyla GELMEZ; vmkit-composer eklentisinin
# gereksinimidir ve o eklenti composer yoksa acilmaz.
step_composer(){
  if command -v composer >/dev/null 2>&1; then
    ok "Composer zaten kurulu."
    return
  fi
  log "Composer kuruluyor..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y composer
  # SONUCU DOGRULA: adimlar 'set +e' altinda calisiyor, basarisiz bir apt-get
  # sessizce geciliyordu ve asagidaki satir yine "kuruldu" diyordu. Ubuntu'da
  # 'composer' paketi 'universe' bileseninde; o bilesen kapaliysa kurulum
  # burada takilir ve sebebini yazmis oluruz.
  if ! command -v composer >/dev/null 2>&1; then
    err "Composer kurulamadi. Ubuntu'da 'universe' bileseni kapali olabilir:"
    err "  add-apt-repository universe && apt-get update && apt-get install composer"
    return 1
  fi
  ok "Composer kuruldu."
}

step_dns_template(){
  local cfg="/etc/webmin/virtual-server/config"
  if [ ! -f "$cfg" ]; then err "Virtualmin config yok; dns-template atlaniyor."; return 1; fi
  if [ -z "${NS1:-}" ] || [ -z "${NS2:-}" ]; then warn "NS1/NS2 bos; dns-template atlaniyor."; return 0; fi
  [ -f "${cfg}.vmin-kit.bak" ] || cp -a "$cfg" "${cfg}.vmin-kit.bak"
  # Not: dns_default_ip4/ip6 (8.8.8.8) BIND recursive forwarder degeridir
  # (A-kaydi IP'si degil); ona dokunulmaz.
  set_kv "$cfg" bind_master "$NS1"
  set_kv "$cfg" dns_ns      "$NS2"
  set_kv "$cfg" dns_prins   "1"
  set_kv "$cfg" bind_sub    "yes"
  systemctl restart webmin 2>/dev/null || warn "webmin restart edilemedi (elle: systemctl restart webmin)"
  ok "dns-template: bind_master=$NS1, dns_ns=$NS2, bind_sub=yes"
}

# Virtualmin her yeni domaine iki "kisayol" ekliyor:
#   admin.<domain>   -> Webmin  (https://<domain>:10000)
#   webmail.<domain> -> Usermin (https://<domain>:20000)
# Her biri bir A kaydi ve vhost'ta bir 301 yonlendirmesi demek. Ikisini de
# istemiyoruz: panele hostname uzerinden giriliyor.
#
# Ayar SABLON duzeyinde tutuluyor (web_admin / web_webmail). Varsayilan
# sablonun ayri bir dosyasi yok: list_templates() 0 numarali sablonu dogrudan
# modul yapilandirmasindan uretiyor, save_template() de oraya geri yaziyor. Bu
# yuzden dogru yer /etc/webmin/virtual-server/config - dns-template adiminin
# yazdigi dosyanin ayni.
#
# Her anahtar iki seyi birden kapatiyor: DNS kaydini
# (add_webmail_dns_records_to_file) ve Apache yonlendirmesi ile ServerAlias'i
# (add_webmail_redirect_directives). ServerAlias gitince ad sertifikaya da
# girmiyor - get_hostnames_for_ssl yalnizca web sunucusunun gercekten cevap
# verdigi adlari topluyor.
#
# DOMAIN OLUSTURMADAN ONCE calismali: sonradan kapatmak var olan domainlerin
# kaydini ve yonlendirmesini temizlemiyor.
step_panel_redirects(){
  local cfg="/etc/webmin/virtual-server/config"
  if [ ! -f "$cfg" ]; then err "Virtualmin config yok; panel yonlendirmeleri atlaniyor."; return 1; fi
  [ -f "${cfg}.vmin-kit.bak" ] || cp -a "$cfg" "${cfg}.vmin-kit.bak"

  local row key flag name cur
  for row in "web_admin|${NO_ADMIN_REDIRECT:-1}|admin"              "web_webmail|${NO_WEBMAIL_REDIRECT:-1}|webmail"; do
    IFS='|' read -r key flag name <<< "$row"
    if ! is_truthy "$flag"; then
      log "  ${name}.<domain> yonlendirmesine dokunulmuyor (ayar 0)."
      continue
    fi
    # Deger '=' icerebiliyor (newdom_aliases gibi), o yuzden awk -F= degil sed.
    cur="$(sed -n "s/^${key}=//p" "$cfg" | head -1)"
    if [ "$cur" = "0" ]; then
      ok "${name}.<domain> yonlendirmesi zaten kapali."
    else
      set_kv "$cfg" "$key" "0"
      ok "${name}.<domain> yonlendirmesi kapatildi (bundan sonra olusan domainler icin)."
    fi
  done
}

# Domain varsayilanlari: ilk domain olusmadan once Virtualmin'in modul
# yapilandirmasina yazilir, cunku --default-features bu degerleri okuyor.
# Bayrak yok - dogru kurulum davranisi bu; istisna gerekirse panelden acilir.
#
#   bind_spf=yes     Her yeni domaine SPF kaydi. Varsayilan kapali.
#   bind_spfall=1    SPF'in "all" kipi. Sablondaki 0/1/2, bind8'de 1/2/3 olup
#                    ?all / ~all / -all uretiyor (f-dns.pl: dns_spfall + 1).
#                    Bos birakilirsa ?all cikiyor - hicbir sey soylemeyen bir
#                    kayit. 1 -> ~all: standart ve guvenli. -all katidir,
#                    posta bir yerden yonlendirilirse reddedilmesine yol acar.
#
#   bind_dmarc=yes   Her yeni domaine DMARC kaydi. Politika ayrica yazilmiyor:
#                    bind_dmarcp bos oldugunda "none" kullaniliyor (vslib.pl:
#                    bind_dmarcp || "none"), yani kayit yayinlanir ama hicbir
#                    posta engellenmez. SPF/DKIM'in dogru calistigi gorulunce
#                    panelden quarantine'e sikilir. Yuzde de varsayilan 100.
#
# BURADA ARTIK spam=0 / virus=0 YOK (2026-09-10). Yaziyorduk ve sonucu suydu:
# kurulum sonrasi sihirbaz bunlari HIC SORMUYORDU. Sihirbaz "acik olanlari
# kapatayim mi" diye soruyor, biz onceden kapatinca soracak bir sey kalmiyor
# ve karar sessizce bizim olmus oluyordu. Temiz kurulumda dogrulandi.
#
# Artik global yapilandirmaya dokunmuyoruz; ana domain bu ozellikler olmadan
# olusuyor (bkz. step_main_domain, acik ozellik listesi). Boylece domain yine
# hafif kaliyor ama "bu sunucuda spam/virus taramasi olsun mu" sorusuna
# sihirbazda kullanici cevap veriyor - ve cevabi sonraki domainler icin de
# gecerli oluyor.
#
# Burada BILEREK olmayanlar: posta kutusu adlandirmasi (append_style) ve rol
# adreslerinin hedefi (newdom_aliases) Virtualmin'in getirdigi gibi birakiliyor.
# Domain sahibinin unix hesabi ayni zamanda posta kutusudur; bunu degistirmenin
# her yolu (unixname=3 gibi) o adi ev dizinine ve veritabani adina da tasiyor.
# Kendi posta kutularin (ornegin bilal@ornek.com) zaten e-posta adresiyle giris
# yapiyor; domain sahibi hesabi yalnizca postmaster/abuse okumak icin.
#
# Idempotent: deger zaten dogruysa dosyaya dokunulmaz.
step_domain_defaults(){
  local cfg="/etc/webmin/virtual-server/config"
  if [ ! -f "$cfg" ]; then err "Virtualmin config yok; domain varsayilanlari atlaniyor."; return 1; fi
  [ -f "${cfg}.vmin-kit.bak" ] || cp -a "$cfg" "${cfg}.vmin-kit.bak"

  local row key val name cur
  for row in "bind_spf|yes|SPF kaydi" \
             "bind_spfall|1|SPF sertligi (~all)" \
             "bind_dmarc|yes|DMARC kaydi"; do
    IFS='|' read -r key val name <<< "$row"
    cur="$(sed -n "s/^${key}=//p" "$cfg" | head -1)"
    if [ "$cur" = "$val" ]; then
      ok "$name: zaten yerinde ($key=$val)"
    else
      set_kv "$cfg" "$key" "$val"
      ok "$name: $key=$val yazildi"
    fi
  done

  # Rol adresleri: sablonda gelen listeden yalnizca gerekli olanlari birakiyoruz.
  #   postmaster  RFC 5321 geregi kabul edilmeli
  #   abuse       diger operatorlerin ve kara liste servislerinin bildirim adresi
  # hostmaster ve webmaster yalnizca gelenek - Virtualmin kaynaginda hicbir yerde
  # kullanilmiyorlar, SOA kaydi da hostmaster'a bakmiyor.
  #
  # Degeri SIFIRDAN YAZMIYORUZ, var olani suzuyoruz: hedef bicimini Virtualmin
  # nasil kuruyorsa oyle kalsin. Yalnizca bundan sonra olusan domainleri etkiler.
  local keep="${ROLE_ALIASES:-postmaster abuse}" cur_a new_a e nm
  cur_a="$(sed -n "s/^newdom_aliases=//p" "$cfg" | head -1)"
  if [ -z "$cur_a" ]; then
    log "  Rol adresi sablonu bos; dokunulmadi."
  else
    new_a=""
    # printf '%s' son satiri newline'siz birakiyor ve 'read' onu donguye
    # sokmuyor: listedeki SON giris sessizce dusuyordu (once webmaster, sonraki
    # turda abuse). '%s\n' sart.
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      nm="${e%%=*}"
      case " $keep " in *" $nm "*) new_a="${new_a}${new_a:+$'\t'}${e}" ;; esac
    done < <(printf '%s\n' "$cur_a" | tr '\t' '\n')
    if [ -z "$new_a" ]; then
      warn "  Rol adresi sablonunda '$keep' bulunamadi; dokunulmadi."
    elif [ "$cur_a" = "$new_a" ]; then
      ok "Rol adresleri: zaten yalnizca $keep"
    else
      set_kv "$cfg" newdom_aliases "$new_a"
      ok "Rol adresleri: yalnizca $keep birakildi"
    fi
  fi
}

# DKIM: giden postalari imzala.
#
# Sunucu geneli, tek seferlik bir kurulum - sablon ayari degil. Anahtari
# uretir, OpenDKIM'i yapilandirir, imzalanacak domain haritasini yazar ve
# DKIM acikken olusan her domaine <secici>._domainkey TXT kaydini ekler
# (feature-mail.pl bunu $config{dkim_enabled} bakarak yapiyor). Bu yuzden ilk
# domainden ONCE calisiyor.
#
# Panelde ayni is: Email Settings -> DomainKeys Identified Mail. Burada
# enable_dkim.cgi'nin yaptigi adimlarin aynisini yapiyoruz:
#   selector  varsayilan YYYYAA (get_default_dkim_selector)
#   sign=1    giden postayi imzala
#   verify=1  gelen postanin imzasini dogrula
#   alldns=0  yalnizca DNS ve posta acik olan domainler
#   2048 bit  panelin varsayilan anahtar boyu
#
# check_dkim() sistem uygun degilse (paket yok gibi) sebebini soyluyor; o
# durumda kurulumu durdurmuyoruz, atlayip devam ediyoruz.
step_dkim(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; DKIM atlaniyor."; return 1; }
  local out
  out="$(perl -e '
    my ($root) = @ARGV;
    $ENV{WEBMIN_CONFIG} ||= q(/etc/webmin); $ENV{WEBMIN_VAR} ||= q(/var/webmin);
    push(@INC, $root); $main::no_acl_check++;
    chdir("$root/virtual-server");
    $0 = "$root/virtual-server/vmkit-dkim.pl";
    require q(./virtual-server-lib.pl);
    my $err = &check_dkim();
    if ($err) { print qq(VMKIT-DKIM:SKIP $err\n); exit(0); }
    my $dkim = &get_dkim_config() || { };
    if ($dkim->{enabled}) { print qq(VMKIT-DKIM:ALREADY $dkim->{selector}\n); exit(0); }
    $dkim->{selector} ||= &get_default_dkim_selector();
    $dkim->{enabled} = 1;
    $dkim->{sign}    = 1;
    $dkim->{verify}  = 1;
    $dkim->{alldns}  = 0;
    $dkim->{extra} ||= [ ];
    &set_all_text_print();
    my $ok = &enable_dkim($dkim, 0, 2048);
    if (!$ok) { print qq(VMKIT-DKIM:FAILED\n); exit(1); }
    $config{dkim_enabled} = 1;
    &lock_file($module_config_file);
    &save_module_config();
    &unlock_file($module_config_file);
    &run_post_actions();
    print qq(VMKIT-DKIM:OK $dkim->{selector}\n);
  ' "$(webmin_root)" 2>&1)"

  printf '%s\n' "$out" | grep -v '^VMKIT-DKIM:' | sed 's/^/    /'
  # Isaret satirini SATIR bazinda ayikliyoruz; ${out##...} kullanilsaydi
  # isaretten sonraki tum ciktiyi alirdi.
  local mark val
  mark="$(printf '%s\n' "$out" | grep '^VMKIT-DKIM:' | head -1)"
  val="${mark#VMKIT-DKIM:* }"
  case "$mark" in
    "VMKIT-DKIM:ALREADY"*) ok "DKIM zaten acik (secici: $val)." ;;
    "VMKIT-DKIM:SKIP"*)    warn "DKIM acilamadi, atlaniyor: $val" ;;
    "VMKIT-DKIM:OK"*)      ok "DKIM acildi (secici: $val)." ;;
    *)                     err "DKIM acilamadi."; return 1 ;;
  esac
}

# Ana domaini VIRTUALMIN'IN KENDI VARSAYILANLARIYLA olusturur
# (--default-features): panelden "Create Virtual Server" dediginde ne
# aciliyorsa aynisi. Boylece ana domain ozel bir durum olmuyor, sonradan
# panelden actigin domainlerle ayni sekilde kuruluyor.
#
# Hangi ozelliklerin varsayilan oldugu Virtualmin'in kendi yapilandirmasindan
# geliyor (System Settings -> Features and Plugins). Bizim eklentilerimiz de o
# listede: plugins_inactive'e yazmadigimiz icin yeni domainlerde varsayilan
# acikler.
#
# Bunun bedeli: sonuc o sunucunun global yapilandirmasina bagli. Bu yuzden
# olusan ozellik listesini asagida LOGA yaziyoruz - ikinci sunucuda fark
# olursa kurulum kaydindan gorulsun.
#
# Posta acildiginda Virtualmin zone'a mail.<domain> A kaydi ve MX ekler; ayrica
# domain sahibi unix kullanicisi o anda bir posta kutusuna donusur: adresi
# <kullanici>@<domain> olur. Ayri bir hesap acilmiyor, var olan hesap adres
# kazaniyor. Sifresi rastgele uretilip atildigi icin kutuyu kullanmadan once
# panelden bir sifre belirlemek gerekir.
step_main_domain(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; ana domain atlaniyor."; return 1; }
  if virtualmin list-domains --name-only 2>/dev/null | grep -x "$MAIN_DOMAIN" >/dev/null; then
    ok "Ana domain zaten var: $MAIN_DOMAIN (atlaniyor)."; return
  fi
  # Sifre rastgele uretilir ve HICBIR YERE yazilmaz. Kullanilmasi gerekirse
  # (Webmin girisi, FTP) panelden degistirilir; saklanmayan sir sizmaz.
  local pw; pw="$(gen_pass)"

  # ACIK OZELLIK LISTESI, '--default-features' DEGIL (2026-09-10).
  #
  # Once varsayilanlarla olusturuyorduk. Iki sorunu vardi: (1) varsayilanlari
  # istedigimiz gibi yapmak icin Virtualmin'in global yapilandirmasini
  # degistirmemiz gerekiyordu ve bu kurulum sihirbazinin sorularini
  # susturuyordu; (2) ana domain "sunucunun o anki varsayilani ne ise o"
  # oluyordu, yani sonucu kestirilemezdi.
  #
  # Simdi liste burada ve okunur:
  #   unix dir       kullanici + ev dizini; ikisi de zorunlu
  #   web ssl        site ve sertifikasi - bu domainin varlik sebebi
  #   dns            yerel BIND zone'u; Cloudflare senkronu bunu model aliyor
  #   mail           rol adresleri (postmaster/abuse) buraya dusuyor
  #   logrotate      domainin gunlukleri sonsuza kadar buyumesin
  #   webmin         domain sahibinin panele girebilmesi
  #   mysql          GEREKLI: webmail alt sunucusu Roundcube icin veritabani
  #                  istiyor ve alt sunucular MySQL kullanicisini EBEVEYNDEN
  #                  aliyor (feature-mysql.pl: mysql_user parent'a devrediyor,
  #                  setup_mysql kullaniciyi yalnizca !parent iken olusturuyor).
  #                  Ana domainde mysql yoksa webmail'in veritabani sahipsiz
  #                  kalir.
  #   vmkit-*        kendi eklentilerimiz; zaten bu sunucunun amaci
  #
  # BILEREK YOK: spam, virus (sihirbaz sorsun), postgres (sihirbaz aciyor),
  # virtualmin-awstats (gerekirse domain basina acilir).
  #
  # Not: bir '--<ozellik>' bayragi, o ozellik modul yapilandirmasinda kapaliysa
  # reddediliyor (create-domain.pl: "cannot be used unless the feature is
  # enabled in the module configuration"). Bu yuzden postgres'i buraya
  # yazamayiz - sihirbazdan once kapali.
  # BAYRAKLAR SUZULEREK veriliyor. Sebebi: kapali bir ozellik icin bayrak
  # gecmek create-domain'i kullanim hatasiyla durduruyor ve o an ana domain
  # olusmadigi icin ARDINDAN GELEN HER ADIM (SSL, panel siteleri, webmail,
  # docker) da dusuyor. Sunucuda bir ozellik beklenmedik sekilde kapaliysa
  # kurulumu ucurmaktansa o ozelligi atlayip uyari yazmak yegdir.
  local cfg="/etc/webmin/virtual-server/config"
  local want="unix dir web ssl dns mail logrotate webmin mysql"
  local -a flags=()
  local f skipped=""
  for f in $want; do
    if grep -qE "^${f}=[^0]" "$cfg" 2>/dev/null; then
      flags+=("--$f")
    else
      skipped="$skipped $f"
    fi
  done
  # Eklentiler ayri kontrol: bunlar 'plugins=' satirinda olmali (step_plugins
  # yaziyor ve o adim bundan once calisiyor).
  local p
  for p in vmkit-cloudflare vmkit-composer vmkit-deploy; do
    if grep -qE "^plugins=.*\b${p}\b" "$cfg" 2>/dev/null; then
      flags+=("--$p")
    else
      skipped="$skipped $p"
    fi
  done
  [ -z "$skipped" ] || warn "Kapali oldugu icin atlanan ozellikler:$skipped"

  log "Ana domain olusturuluyor: $MAIN_DOMAIN"
  virtualmin create-domain \
    --domain "$MAIN_DOMAIN" \
    --pass   "$pw" \
    --desc   "$MAIN_DOMAIN" \
    "${flags[@]}"
  unset pw
  ok "Ana domain olusturuldu."
  # Ne acildigini kayda gecir: bayraklarin bir kismi modul yapilandirmasina
  # bagli oldugu icin sonucu gormek onemli.
  virtualmin list-domains --domain "$MAIN_DOMAIN" --multiline 2>/dev/null |
    awk '/^[[:space:]]*(Features|Plugins):/ { sub(/^[[:space:]]*/,""); print "    "$0 }'
}

# Hostname (or: s.ornek.com) ana domainin zone'unda A kaydi olarak yer almali.
# Virtualmin bunu kendiliginden eklemiyor. Harici DNS modunda yayinlanan kopya
# disarida oldugu icin etkisi yok, ama yerel zone bizim "model"imiz: dogru olmali
# ki ileride Cloudflare senkronu dogru kaydi gonderebilsin. BIND modunda ise
# delegasyon geldiginde panelin adresinin cozumlenmesi buna bagli.
step_host_dns(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; hostname DNS kaydi atlaniyor."; return 1; }
  case "$HOSTNAME_FQDN" in
    *".$MAIN_DOMAIN") ;;
    *) log "Hostname ana domainin alt alani degil; DNS kaydi atlaniyor."; return;;
  esac
  local ip; ip="$(detect_ip)"
  if virtualmin get-dns --domain "$MAIN_DOMAIN" --name-only 2>/dev/null \
     | sed 's/\.$//' | grep -ixF "$HOSTNAME_FQDN" >/dev/null; then
    ok "Zone'da $HOSTNAME_FQDN kaydi zaten var."
    return
  fi
  log "Zone'a hostname A kaydi ekleniyor: $HOSTNAME_FQDN -> $ip"
  if virtualmin modify-dns --domain "$MAIN_DOMAIN" --add-record "${HOSTNAME_FQDN}. A ${ip}"; then
    ok "Hostname A kaydi eklendi."
  else
    warn "Eklenemedi. Elle eklemek icin:"
    warn "  virtualmin modify-dns --domain $MAIN_DOMAIN --add-record \"${HOSTNAME_FQDN}. A ${ip}\""
  fi
}

step_ssl(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; SSL atlaniyor."; return 1; }
  # create-domain, otomatik ACME acikken sertifikayi zaten aliyor. Tekrar istemek
  # ayni isim seti icin ikinci bir sertifika uretir ve saglayici kotasini yer
  # (Lets Encrypt: ayni isimler icin haftada 5 sertifika).
  if domain_has_acme_cert "$MAIN_DOMAIN"; then
    ok "SSL sertifikasi zaten alinmis (atlaniyor)."
    return
  fi
  log "Sertifika isteniyor (ACME/Lets Encrypt): $MAIN_DOMAIN"
  if virtualmin generate-letsencrypt-cert --domain "$MAIN_DOMAIN" --default-hosts --renew; then
    ok "SSL alindi, otomatik yenileme acik."
  else
    warn "SSL alinamadi. A kaydini ve 80/443 erisimini kontrol edip tekrar deneyin:"
    warn "  virtualmin generate-letsencrypt-cert --domain $MAIN_DOMAIN --default-hosts --renew"
  fi
}

# Portainer loglarindan en son setup_token'i okur (yoksa bos doner).
# $1 verilirse yalnizca o andan sonraki loglara bakar - eski, tuketilmis bir
# token'i yeniymis gibi okumamak icin gerekli.
portainer_setup_token(){
  local since="${1:-}"
  if [ -n "$since" ]; then docker logs --since "$since" portainer 2>&1
  else                     docker logs portainer 2>&1; fi \
    | grep -oE 'setup_token=[0-9a-f]+' | tail -1 | cut -d= -f2
}

# Portainer'da yonetici hesabi olusturulmus mu?
# Portainer'in kendi kaynagina gore /api/users/admin/check:
#   204 -> yonetici hesabi VAR
#   404 -> hesap YOK, kurulum bekliyor
# Baska bir cevap (servis henuz ayakta degil, yol degismis) "kurulmamis"
# sayilir; en kotu ihtimalle gereksiz bir yeniden baslatma olur.
portainer_configured(){
  local port="${PORTAINER_PORT:-9000}" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
          "http://127.0.0.1:${port}/api/users/admin/check" 2>/dev/null || true)"
  [ "$code" = "204" ]
}

# Portainer'i yeniden baslatip TAZE setup_token dondurur.
portainer_restart_for_token(){
  local since tok="" i
  since="$(date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker restart portainer >/dev/null 2>&1 || return 1
  for i in $(seq 1 15); do
    sleep 2
    tok="$(portainer_setup_token "$since")"
    [ -n "$tok" ] && break
  done
  printf '%s' "$tok"
}

# Kurulumun EN SON adimi: token'i burada uretiyoruz ki kac adim eklenirse
# eklensin ekranda gorunen token taze olsun (omru birkac dakika).
step_portainer_token(){
  command -v docker >/dev/null 2>&1 || return 0
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x portainer >/dev/null || return 0
  local site="${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}"

  # Yonetici hesabi zaten varsa SESSIZ cikiyoruz. Bu adimin tek isi yapilacak
  # bir is kaldiginda haber vermek; "zaten kurulmus" bilgisi ozette
  # (Bilesenler) ve kurulum kaydinda zaten var, kapanista tekrar etmesi
  # gereksiz gurultu.
  portainer_configured && return 0

  say ""
  log "Portainer icin taze setup_token aliniyor (yeniden baslatiliyor)..."
  local tok; tok="$(portainer_restart_for_token || true)"
  say ""
  if [ -n "$tok" ]; then
    ok "Portainer kurulumunu SIMDI tamamlayin - token birkac dakika gecerli:"
    say "    Adres       : https://${site}/"
    say "    setup_token : $tok"
    say ""
    log "Sureyi kacirirsaniz: sudo ./configure-docker.sh"
  else
    warn "setup_token okunamadi. Deneyin: sudo ./configure-docker.sh"
  fi
}

# ensure_proxy_site <onek> <hedef-url> <aciklama> [proxy-host]
# <onek>.<ana-domain> alt sunucusunu olusturur ve / yolunu hedefe vekiller.
#
# Yonetim araclarini disariya port acmadan yayinlamanin kalibi budur: arayuz
# 127.0.0.1'de dinler, disariya Apache uzerinden ve o alt alanin KENDI
# sertifikasiyla cikar. docker./webmin./usermin. ucu de bu kalibi kullaniyor.
#
# Ozellikler bilerek en az: --dir (web sitesi icin sart), --web (vhost),
# --ssl (https), --dns (alt alanin A kaydi; bind_sub=yes oldugu icin ayri zone
# acilmaz, kayit ana domainin zone'una girer - olmadan alt alan hic
# cozumlenmez), --parent (alt sunucu; ayri Unix kullanicisi acilmaz).
# --break-ssl-cert ile ana domainin sertifikasina baglanmak yerine kendi
# sertifikasini alir.
#
ensure_proxy_site(){
  local prefix="$1" url="$2" desc="$3" phost="${4:-}"
  local site="${prefix}.${MAIN_DOMAIN}"
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; $site atlaniyor."; return 1; }

  if virtualmin list-domains --name-only 2>/dev/null | grep -xF "$site" >/dev/null; then
    ok "Alt sunucu zaten var: $site"
  else
    log "Alt sunucu olusturuluyor: $site (ana domain: $MAIN_DOMAIN)"
    if ! virtualmin create-domain \
           --domain "$site" \
           --parent "$MAIN_DOMAIN" \
           --desc   "$desc" \
           --dir --web --ssl --dns --break-ssl-cert; then
      err "$site olusturulamadi."
      return 1
    fi
    ok "Alt sunucu olusturuldu: $site"
  fi

  # Vekil zaten tanimli mi? (vhost dosyasinda hedefi ariyoruz)
  local vhost="/etc/apache2/sites-available/${site}.conf"
  if [ -f "$vhost" ] && grep -qF "$url" "$vhost"; then
    ok "Vekil zaten tanimli: / -> $url"
  else
    log "Vekil ayarlaniyor: / -> $url  (websocket destegiyle)"
    # Zaten bir vekil varsa (ornegin eski http hedefi) URL'yi guncelliyoruz,
    # yoksa yenisini kuruyoruz.
    if virtualmin modify-proxy --domain "$site" --path / --url "$url" >/dev/null 2>&1; then
      ok "Vekil hedefi guncellendi."
    elif virtualmin create-proxy --domain "$site" --path / --url "$url" --websockets; then
      ok "Vekil eklendi."
    else
      err "Vekil eklenemedi. Elle: virtualmin create-proxy --domain $site --path / --url $url --websockets"
      return 1
    fi
  fi

  # 4. parametre verilirse "Forward original HTTP hostname when proxying"
  # aciliyor (ProxyPreserveHost On; panelde Server Configuration -> Website
  # Options, CLI'da modify-web --proxy-host - ikisi de save_domain_proxy_host
  # cagiriyor). Webmin ve Usermin bu olmadan vekilin arkasinda duzgun
  # calismiyor: kendilerine gelen Host basligi 127.0.0.1:<port> oluyor ve
  # urettikleri adresler ile oturum kontrolleri buna gore sasiyor.
  # Portainer'in buna ihtiyaci yok, docker sitesi bu parametreyi almiyor.
  if [ -n "$phost" ]; then
    if [ -f "$vhost" ] && grep -qi 'ProxyPreserveHost[[:space:]]*On' "$vhost"; then
      ok "Host basligi zaten iletiliyor."
    else
      if virtualmin modify-web --domain "$site" --proxy-host >/dev/null 2>&1; then
        ok "Host basligi vekile iletiliyor (ProxyPreserveHost On)."
      else
        warn "ProxyPreserveHost acilamadi; $site uzerinden giris reddedilebilir."
      fi
    fi
  fi

  return 0
}

# proxy_site_works <onek> -> vekil gercekten cevap veriyor mu
# DNS'e BAGLI DEGIL: --resolve ile dogrudan yerel Apache'ye, dogru Host ve SNI
# ile gidiyoruz. Harici DNS modunda alt alan adi daha yayilmamis olabilir ama
# vekilin calistigini yine de dogrulayabilmemiz gerekiyor.
proxy_site_works(){
  local site="$1.${MAIN_DOMAIN}" code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
          --resolve "${site}:443:127.0.0.1" "https://${site}/" 2>/dev/null || true)"
  case "$code" in
    200|302|301|401) return 0 ;;
    *) log "  $site -> HTTP ${code:-yanit yok}"; return 1 ;;
  esac
}


# webmail.<ana-domain>: Roundcube.
#
# Bu bir vekil DEGIL, gercek bir PHP uygulamasi; Virtualmin'in kendi kurucusu
# (Install Scripts) ile kuruluyor. Roundcube veritabani istedigi icin alt
# sunucu --mysql ile olusuyor.
#
# Roundcube yalnizca bir IMAP istemcisi: postalar Dovecot'un Maildir'inde
# durur, kullanici/kutu/sifre yonetimi Virtualmin'de kalir. Giris adresi tam
# e-posta adresidir (ornek: blnk@blnk.tr).
step_webmail(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; webmail atlaniyor."; return 1; }
  local site="${WEBMAIL_PREFIX:-webmail}.${MAIN_DOMAIN}"

  if virtualmin list-domains --name-only 2>/dev/null | grep -xF "$site" >/dev/null; then
    ok "Alt sunucu zaten var: $site"
  else
    log "Alt sunucu olusturuluyor: $site (ana domain: $MAIN_DOMAIN)"
    if ! virtualmin create-domain \
           --domain "$site" \
           --parent "$MAIN_DOMAIN" \
           --desc   "Roundcube (vmin-kit)" \
           --dir --web --ssl --dns --mysql --break-ssl-cert; then
      err "$site olusturulamadi; Roundcube atlaniyor."
      return 1
    fi
    ok "Alt sunucu olusturuldu: $site"
  fi

  if virtualmin list-scripts --domain "$site" 2>/dev/null | grep -i roundcube >/dev/null; then
    ok "Roundcube zaten kurulu: https://${site}/"
  else
    log "Roundcube kuruluyor: https://${site}/  (indirme ve kurulum biraz surer)"
    if virtualmin install-script --domain "$site" --type roundcube \
           --version latest --path / --db "mysql roundcube" --newdb --prefix-db; then
      ok "Roundcube kuruldu: https://${site}/"
    else
      err "Roundcube kurulamadi. Elle: Virtualmin -> $site -> Install Scripts"
      return 1
    fi
  fi

  # Kimlik adresi. Virtualmin'in kurucusu mail_domain satirini
  # config.inc.php.sample icinde DEGISTIREREK yaziyor (scripts/roundcube.pl);
  # Roundcube 1.7'nin ornek dosyasinda o satir artik olmadigi icin deger bos
  # kaliyor ve DOMAIN SAHIBININ kimligi <kullanici>@localhost cikiyordu.
  #
  # Tek bir mail_domain yazmak cok domainli sunucuda yanlis olur. Bunun yerine
  # Roundcube'un virtuser_file eklentisini kullaniyoruz: giris adini Postfix'in
  # virtual haritasinda arayip gercek adresi buluyor. AYAR TEK BASINA YETMEZ,
  # eklenti $config['plugins'] listesinde de olmali.
  #
  # Kapsami: yalnizca domain sahibini duzeltir. Alias adresleri gelmez, cunku
  # harita iki seviyeli (alias -> adres -> unix kullanici) ve eklenti tek
  # seviye bakiyor; @ iceren giris adlari da haritada \@ olarak kacisli
  # yazildigi icin eslesmiyor. Alias'lar Roundcube'da elle kimlik olarak
  # eklenir.
  local dir cfg
  dir="$(virtualmin list-scripts --domain "$site" --multiline 2>/dev/null |
         awk -F': ' '/^[[:space:]]*Directory:/{print $2; exit}')"
  cfg="$dir/config/config.inc.php"
  if [ ! -f "$cfg" ]; then
    warn "Roundcube yapilandirmasi bulunamadi ($cfg); kimlik ayari atlandi."
    return 0
  fi
  if grep -q "virtuser_file" "$cfg"; then
    ok "Roundcube kimlik ayari zaten yapilmis."
  else
    {
      echo
      echo "// vmin-kit: giris adini Postfix virtual haritasindan gercek adrese cevir"
      echo "\$config['virtuser_file'] = '/etc/postfix/virtual';"
      echo "\$config['plugins'][] = 'virtuser_file';"
    } >> "$cfg"
    ok "Roundcube virtuser_file eklentisi etkinlestirildi."
  fi

  # --- des_key: oturum sifreleme anahtari ---
  #
  # Roundcube kullanicinin IMAP PAROLASINI oturum verisinde bu anahtarla
  # sifreliyor. Varsayilani sabit ve herkesin bildigi bir dize:
  #   $config['des_key'] = 'rcmail-!24ByteDESkey*Str';   (defaults.inc.php)
  # Bilinen bir anahtar, oturum verisine erisebilen birinin posta parolasini
  # cozebilmesi demek.
  #
  # Roundcube'un kendi web kurulum sihirbazi normalde rastgele bir anahtar
  # uretir; Virtualmin sihirbazi CALISTIRMIYOR, tarball'i acip ornek
  # yapilandirmayi satir satir duzenliyor - ve scripts/roundcube.pl'de
  # des_key HIC GECMIYOR (kaynaktan dogrulandi). Yani anahtar varsayilanda
  # kaliyor.
  #
  # Uzunluk: varsayilan cipher_method DES-EDE3-CBC ve belgesi "a required key
  # length is 24 characters" diyor. Yalnizca harf/rakam uretiyoruz; tirnak ya
  # da ters bolu gibi PHP dizesini bozacak karakter hic olusmasin.
  # Once des_key gecen satirlari sec, yorumlari at, sondaki atamanin degerini
  # oku - PHP de son atamayi kullanir. Tek bir sed ifadesiyle denendi ve cift
  # tirnak icindeki '\$' kacisi yuzunden hicbir zaman eslesmiyordu.
  local cur_key
  cur_key="$(grep 'des_key' "$cfg" | grep -v '^[[:space:]]*//' |
             sed -n "s/.*= *'\(.*\)';.*/\1/p" | tail -1)"
  if [ -n "$cur_key" ] && [ "$cur_key" != "rcmail-!24ByteDESkey*Str" ]; then
    # Birileri (ya da onceki calismamiz) zaten koymus; dokunmuyoruz. Her
    # calistirmada yeni anahtar yazmak butun oturumlari dusururdu.
    ok "Roundcube oturum anahtari zaten ozel."
  else
    local newkey
    # '|| true' SART: head 24 bayti alip cikiyor, tr yazmaya devam ettigi
    # icin SIGPIPE aliyor ve 'pipefail' bunu hata sayiyor - olculdu, cikis
    # kodu 141 (deger yine dogru uretiliyor). Bugun zararsiz cunku ardindan
    # baska satirlar var; bu satir bir fonksiyonun SON komutu olsaydi adim
    # sebepsiz "basarisiz" gorunurdu.
    newkey="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24 || true)"
    if [ "${#newkey}" -ne 24 ]; then
      warn "Rastgele anahtar uretilemedi; Roundcube des_key varsayilanda kaldi."
    else
      {
        echo
        echo "// vmin-kit: oturumdaki IMAP parolasini sifreleyen anahtar."
        echo "// Roundcube'un varsayilani sabit ve herkesce bilinir."
        echo "\$config['des_key'] = '$newkey';"
      } >> "$cfg"
      ok "Roundcube oturum anahtari rastgele bir degerle degistirildi."
    fi
  fi

  # --- kurulum sihirbazini kaldir ---
  #
  # Roundcube'un dizin duzeni (kaynagindan dogrulandi):
  #   <kok>/installer                 sihirbazin asil kodu
  #   <kok>/public_html/installer.php on denetleyici
  # enable_installer varsayilani false, yani sihirbaz calismayi reddediyor;
  # yine de Roundcube'un kendi tavsiyesi kurulumdan sonra silmek. Ayarin
  # yanlislikla acilmasi ya da bir surumde varsayilanin degismesi ihtimaline
  # karsi kod hic durmasin.
  #
  # DIKKAT: Virtualmin'in script yukseltmesi tarball'i yeniden actigi icin
  # sihirbaz geri gelebilir. Bu blok tekrarlanabilir, install.sh'i yeniden
  # calistirmak yeterli.
  #
  # $dir bos olamaz - buraya gelmeden once $cfg="$dir/config/config.inc.php"
  # dosyasinin varligi kontrol edildi. Yine de silme islemi oldugu icin acikca
  # bir kez daha bakiyoruz.
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    local removed=0
    if [ -e "$dir/installer" ]; then rm -rf "$dir/installer"; removed=1; fi
    if [ -e "$dir/public_html/installer.php" ]; then
      rm -f "$dir/public_html/installer.php"; removed=1
    fi
    if [ "$removed" = 1 ]; then
      ok "Roundcube kurulum sihirbazi kaldirildi."
    else
      ok "Roundcube kurulum sihirbazi zaten yok."
    fi
  fi
}

# docker.<domain> alt sunucusu + Portainer'a proxy.
#
# Ozellikler burada BILEREK tek tek sayiliyor: ana domainin aksine
# --default-features KULLANILMIYOR. Burasi yalnizca bir ters vekil; posta,
# DNS, veritabani ve eklentiler bu siteye gereksiz. Liste zaten en kucuk hali:
#   --dir    web sitesi icin sart (check_depends_web home dizini istiyor)
#   --web    vekil vhost'unun kendisi
#   --ssl    https://docker.<domain> icin
#   --dns    alt alanin A kaydi. bind_sub=yes oldugu icin ayri zone acilmaz,
#            kayit ana domainin zone'una yazilir (f-dns.pl: dns_submode).
#            Olmadan alt alan hic cozumlenmez - Cloudflare'de joker kayit
#            varsa gizlenir ama BIND modunda dogrudan kirilir.
#   --parent alt sunucu: ayri Unix kullanicisi acilmaz
# --break-ssl-cert ile ana domainin sertifikasina baglanmak yerine kendi
# sertifikasini alir (ana domainin sertifikasi bu ismi kapsamiyor).
step_docker_site(){
  ensure_proxy_site "${DOCKER_PREFIX:-docker}" \
                    "http://127.0.0.1:${PORTAINER_PORT:-9000}/" \
                    "Portainer (vmin-kit)"
}

# Webmin/Usermin, istegin Referer basligindaki adresi kendi gordugu
# Host + PORT ile karsilastiriyor (web-lib-funcs.pl, referer kontrolu).
# Vekilin arkasinda referer https://webmin.<domain> yani port 443, arayuzun
# kendi portu ise 10000 oldugu icin esitlik tutmuyor ve istek "Security
# Warning" sayfasiyla reddediliyor.
#
# Cozum panelin kendi onerdigi sey: adresi guvenilen siteler listesine eklemek.
# Panelde Webmin Configuration -> Trusted Referrers ile ayni yer.
# Bu dosya her istekte yeniden okundugu icin servisi yeniden baslatmak gerekmez.
add_trusted_referer(){
  local conf="$1" site="$2" cur
  [ -f "$conf" ] || return 0
  cur="$(awk -F= '/^referers=/{sub(/^referers=/,""); print; exit}' "$conf")"
  case " $cur " in
    *" $site "*) ok "  Guvenilen adres zaten kayitli: $site"; return 0 ;;
  esac
  [ -f "${conf}.vmin-kit.bak" ] || cp -a "$conf" "${conf}.vmin-kit.bak"
  set_kv "$conf" referers "$(echo "$cur $site" | xargs)"
  ok "  Guvenilen adres eklendi: $site"
}


# Vekilin arkasinda arayuzun DIS adresini bilmesi gerekiyor: kendi portu 10000
# ama disaridan gelen istek 443'ten geliyor. miniserv izin verilen websocket
# origin listesini bu bilgiden kuruyor (miniserv-lib.pl,
# get_websocket_allowed_origins - "canonical externally-visible URL" satiri).
# Bildirilmezse tarayici https://webmin.<domain> origin'i gonderiyor, miniserv
# https://webmin.<domain>:10000 bekliyor ve baglantiyi
# "403 Invalid Websockets origin" ile reddediyor. Authentic tema panosu,
# dosya yoneticisi ve terminali websocket kullandigi icin bu sart.
#
# Konak adi ayrica yazilmiyor: redirect_host bos oldugunda miniserv gelen Host
# basligini kullaniyor, ProxyPreserveHost sayesinde o zaten dogru.
set_panel_external_port(){
  local name="$1" conf="$2" svc="$3"
  [ -f "$conf" ] || return 0
  if [ "$(sed -n 's/^redirect_port=//p' "$conf" | head -1)" = "443" ]; then
    ok "  $name dis portu zaten bildirilmis (443)."
    return 0
  fi
  [ -f "${conf}.vmin-kit.bak" ] || cp -a "$conf" "${conf}.vmin-kit.bak"
  set_kv "$conf" redirect_port "443"
  systemctl restart "$svc" >/dev/null 2>&1 || warn "  $svc yeniden baslatilamadi."
  ok "  $name dis portu 443 olarak bildirildi (websocket origin icin)."
}

# Yonetim arayuzleri ana domain altinda birer alt alan olarak yayinlanir:
#   webmin.<ana-domain>  -> 127.0.0.1:10000
#   usermin.<ana-domain> -> 127.0.0.1:20000
# Amac disariya acik yonetim portu birakmamak. Kilitleme ayri bir adimda
# (step_lock_panel_ports), once vekilin calistigi dogrulaniyor.
step_panel_sites(){
  local wport uport
  wport="$(awk -F= '/^port=/{print $2; exit}' /etc/webmin/miniserv.conf 2>/dev/null)"
  wport="${wport:-10000}"
  ensure_proxy_site "${WEBMIN_PREFIX:-webmin}" "https://127.0.0.1:${wport}/" \
                    "Webmin (vmin-kit)" phost
  add_trusted_referer /etc/webmin/config "${WEBMIN_PREFIX:-webmin}.${MAIN_DOMAIN}"
  set_panel_external_port "Webmin" /etc/webmin/miniserv.conf webmin

  if [ -f /etc/usermin/miniserv.conf ]; then
    uport="$(awk -F= '/^port=/{print $2; exit}' /etc/usermin/miniserv.conf 2>/dev/null)"
    uport="${uport:-20000}"
    ensure_proxy_site "${USERMIN_PREFIX:-usermin}" "https://127.0.0.1:${uport}/" \
                      "Usermin (vmin-kit)" phost
    add_trusted_referer /etc/usermin/config "${USERMIN_PREFIX:-usermin}.${MAIN_DOMAIN}"
    set_panel_external_port "Usermin" /etc/usermin/miniserv.conf usermin
  else
    log "Usermin kurulu degil; usermin.<domain> atlaniyor."
  fi
}

# Yonetim portlarini yalnizca 127.0.0.1'e baglar.
#
# TEHLIKELI ADIM: baglandiktan sonra panele tek erisim vekil uzerinden olur.
# Bu yuzden ONCE vekilin gercekten cevap verdigini dogruluyoruz; dogrulama
# basarisizsa kilitleme YAPILMIYOR ve nasil elle yapilacagi yaziliyor.
#
# Arayuz kendi SSL'inde kaliyor ve vekil ona https ile gidiyor; boylece Webmin
# kendini guvenli sayiyor ve urettigi baglantilar https oluyor.
lock_panel_port(){
  local name="$1" conf="$2" svc="$3" prefix="$4"
  [ -f "$conf" ] || { log "  $name kurulu degil, atlaniyor."; return 0; }

  if [ "$(awk -F= '/^bind=/{print $2; exit}' "$conf")" = "127.0.0.1" ]; then
    ok "$name zaten yalnizca 127.0.0.1 dinliyor."
    return 0
  fi

  if ! proxy_site_works "$prefix"; then
    warn "$name kilitlenmedi: ${prefix}.${MAIN_DOMAIN} vekili dogrulanamadi."
    warn "  Vekil calistiktan sonra elle: $conf icine bind=127.0.0.1 ekleyip"
    warn "  systemctl restart $svc"
    return 1
  fi

  [ -f "${conf}.vmin-kit.bak" ] || cp -a "$conf" "${conf}.vmin-kit.bak"
  set_kv "$conf" bind "127.0.0.1"
  systemctl restart "$svc" >/dev/null 2>&1 || warn "  $svc yeniden baslatilamadi."
  ok "$name yalnizca 127.0.0.1 dinliyor -> https://${prefix}.${MAIN_DOMAIN}/"
}

step_lock_panel_ports(){
  lock_panel_port "Webmin"  /etc/webmin/miniserv.conf  webmin  "${WEBMIN_PREFIX:-webmin}"
  lock_panel_port "Usermin" /etc/usermin/miniserv.conf usermin "${USERMIN_PREFIX:-usermin}"
}

step_docker(){
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then ok "Docker zaten kurulu (atlaniyor)."; return; fi
  local pkg
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then log "Cakisan paket kaldiriliyor: $pkg"; apt-get remove -y "$pkg" || true; fi
  done
  apt-get update; apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  # Docker'in deposu DAGITIM BASINA ayri: .../linux/debian ve .../linux/ubuntu
  # farkli dizinler ve ubuntu'nunkinde bookworm/trixie, debian'inkinde
  # jammy/noble yok. Bu yuzden dagitim adi /etc/os-release'den okunuyor,
  # sabit yazilmiyor. VERSION_CODENAME de oradan geliyor.
  local os_id code arch
  os_id="$(. /etc/os-release && echo "${ID:-debian}")"
  code="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  arch="$(dpkg --print-architecture)"
  case "$os_id" in
    debian|ubuntu) ;;
    *) warn "Docker deposu icin bilinmeyen dagitim ($os_id); debian varsayiliyor."
       os_id=debian ;;
  esac
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${code} stable" > /etc/apt/sources.list.d/docker.list
  fi
  apt-get update; apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  if docker run --rm hello-world >/dev/null 2>&1; then ok "Docker kuruldu ($(docker --version))."; else err "Docker hello-world testi basarisiz."; return 1; fi
}

step_portainer(){
  command -v docker >/dev/null 2>&1 || { err "Docker yok; portainer atlaniyor."; return 1; }
  local image="${PORTAINER_IMAGE:-portainer/portainer-ce:lts}" port="${PORTAINER_PORT:-9000}" pub
  if [ "${PORTAINER_BIND_LOCAL:-yes}" = "yes" ]; then pub="127.0.0.1:${port}:9000"; else pub="${port}:9000"; fi
  if docker ps -a --format '{{.Names}}' | grep -x portainer >/dev/null; then
    if docker ps --format '{{.Names}}' | grep -x portainer >/dev/null; then ok "Portainer zaten calisiyor (atlaniyor)."; return; fi
    docker start portainer >/dev/null; ok "Portainer baslatildi."; return
  fi
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  # Imaji once ayrica cekiyoruz: etiket yoksa (ornegin 'lts' bir gun kalkarsa)
  # bunu ACIKCA gorup 'latest'e dusmek, 'docker run'in anlasilmaz bir hatayla
  # patlamasindan iyi.
  if ! docker pull "$image" >/dev/null 2>&1; then
    warn "Imaj cekilemedi: $image"
    if [ "$image" != "portainer/portainer-ce:latest" ] &&
       docker pull portainer/portainer-ce:latest >/dev/null 2>&1; then
      warn "portainer/portainer-ce:latest ile devam ediliyor."
      image="portainer/portainer-ce:latest"
    else
      err "Portainer imaji indirilemedi."; return 1
    fi
  fi
  docker run -d --name portainer --restart=always -p "$pub" \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data "$image" >/dev/null
  ok "Portainer calisiyor -> $pub"
}

# Eklentiler: paketleri uretip Webmin'in KENDI kurulum yoluyla kur.
#
# install-module.pl (Webmin ile gelir) su isleri yapiyor: arsivi acip modulu
# yerine koymak (eskisini silerek), module.info'daki bagimliligi dogrulamak,
# webmin.acl'e erisim vermek, copyconfig.pl ile /etc/webmin/<modul>/config'i
# kurup MEVCUT degerleri koruyarak birlestirmek, module.infos.cache'leri
# temizlemek ve postinstall.pl -> module_install() calistirmak. Cloudflare
# eklentisi systemd birimlerini iste orada kuruyor.
#
# Yapmadigi tek sey Virtualmin'in 'plugins=' listesine eklemek - o Virtualmin'e
# ozgu bir ayar (gercek Virtualmin eklentileri de kendini eklemiyor, panelden
# tikleniyor). Onu biz yapiyoruz.
#
# Bayraklar config.env'den: PLUGIN_DEPLOY, PLUGIN_COMPOSER, PLUGIN_CLOUDFLARE
# (varsayilan 1). 0 = KURMA demek; kurulu olani SOKMEZ - calisan bir eklentiyi
# bir bayrak degisti diye sessizce kaldirmak istemiyoruz. Kaldirmak icin:
#   sudo ./update-plugins.sh --remove
plugin_flag(){   # vmkit-deploy -> PLUGIN_DEPLOY
  printf 'PLUGIN_%s' "$(printf '%s' "${1#vmkit-}" | tr '[:lower:]-' '[:upper:]_')"
}

plugin_enabled(){
  local var; var="$(plugin_flag "$1")"
  is_truthy "${!var:-1}"
}

# Ozet ekraninda gosterilecek liste.
plugin_list_enabled(){
  local dir mod out=""
  for dir in "$ROOT_DIR"/plugin/*/; do
    [ -f "${dir}module.info" ] || continue
    mod="$(basename "$dir")"
    plugin_enabled "$mod" && out="$out ${mod#vmkit-}"
  done
  printf '%s' "${out:- (hicbiri)}"
}

step_plugins(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; eklentiler atlaniyor."; return 1; }
  local wroot im
  wroot="$(webmin_root)"
  im="$wroot/install-module.pl"
  [ -r "$im" ] || { err "Webmin'in install-module.pl'i yok: $im"; return 1; }

  local dir mod pkg any=0 skipped=""
  for dir in "$ROOT_DIR"/plugin/*/; do
    [ -f "${dir}module.info" ] || continue
    mod="$(basename "$dir")"
    if ! plugin_enabled "$mod"; then
      skipped="$skipped $mod"
      continue
    fi

    # Paketi kurulum aninda kaynaktan uret: paket asla bayatlamaz.
    # 'bash ile' cagriliyor: git calistirma bitini her ortamda tasimiyor
    # (Windows'ta core.filemode=false), dosya izni yuzunden kurulum patlamasin.
    if ! bash "$ROOT_DIR/build-plugins.sh" "$mod" >/dev/null; then
      err "  $mod paketlenemedi."; continue
    fi
    pkg="$ROOT_DIR/dist/$mod.wbm.gz"

    # Shebang'i /usr/local/bin/perl oldugu icin dogrudan degil, perl ile.
    if perl "$im" --acl root "$pkg" >/dev/null 2>&1; then
      log "  kuruldu: $mod"
    else
      err "  $mod kurulamadi (install-module.pl)."
      continue
    fi
    plugins_add "$mod" || true
    any=1
  done

  [ -n "$skipped" ] && log "  atlandi (bayrak 0):$skipped"

  if [ "$any" = 1 ]; then
    if clear_links_cache; then :; else
      warn "  Menu onbellegi temizlenemedi; degisiklik gorunmezse domaini kaydedin."
    fi
    systemctl restart webmin 2>/dev/null || warn "  webmin restart edilemedi."
    ok "Eklentiler kuruldu. Panelde: System Settings -> Features and Plugins."
  else
    ok "Kurulacak eklenti yok."
  fi
}

# Kurulum ozeti: BU SUNUCU NE, adresleri neler, disariya ne acik.
#
# DURUM EKRANI, KILAVUZ DEGIL. Eskiden burada "vekil bozulursa sunu yap",
# "kendi posta kutunuzu soyle acin", "DMARC'i su menuden sikin" gibi uzun
# anlatimlar vardi ve elli satirin yarisi ogut oluyordu. Hepsi README'de
# zaten var (tek tek kontrol edildi); burada yalnizca OLGU duruyor, bir de
# en fazla birkac satirlik hatirlatma.
#
# Ekrana ve kurulum kaydina yaziliyor, ayri bir .txt dosyasi yok.
step_report(){
  local ip dfeat dplug dinfo cmp

  ip="$(detect_ip)"

  # BILESENLER: yalnizca VAR OLANLAR yaziliyor. Eskiden her biri icin
  # "kuruldu / var / calisiyor" ya da "yok / atlandi" yazan bir satir vardi;
  # olmayan bir seyi saymak ozeti uzatmaktan baska ise yaramiyor. Durumu
  # kelimeyle anlatmak da gereksiz: listede varsa vardir.
  local -a comps=()
  command -v psql >/dev/null 2>&1 && comps+=("PostgreSQL")
  command -v docker >/dev/null 2>&1 && comps+=("Docker")
  docker ps --format '{{.Names}}' 2>/dev/null | grep -x portainer >/dev/null &&
    comps+=("Portainer")
  if command -v composer >/dev/null 2>&1; then
    # Composer'i dagitim paketinden kuruyoruz: kendini guncelleyemez. Yeni
    # cerceveler daha yeni bir composer isterse cevap burada gorunur.
    cmp="$(composer --version --no-interaction 2>/dev/null |
           head -1 | awk '{print $3}')"
    comps+=("Composer ${cmp:-}")
  fi

  # Domain bilgisi TEK cagrida aliniyor; iki alan bu ciktidan ayikleniyor
  # (eskiden ayni komut dort kez calisiyordu).
  dinfo="$(virtualmin list-domains --domain "$MAIN_DOMAIN" --multiline 2>/dev/null)"
  # Hangi ozelliklerin acildigini Virtualmin'in kendisinden okuyoruz: domain
  # --default-features ile olusturuldugu icin liste sunucunun kendi
  # yapilandirmasindan geliyor, varsayimda bulunmuyoruz.
  dfeat="$(printf '%s\n' "$dinfo" | awk -F": " '/^[[:space:]]*Features:/{print $2; exit}')"
  dplug="$(printf '%s\n' "$dinfo" | awk -F": " '/^[[:space:]]*Plugins:/{print $2; exit}')"

  say ""
  say "=========== vmin-kit kurulum ozeti ==========="
  say "Tarih        : $(date '+%Y-%m-%d %H:%M:%S %z')"
  say "Arac surumu  : $(vminkit_version)"
  say "Ana domain   : $MAIN_DOMAIN"
  say "Hostname     : $HOSTNAME_FQDN  (${ip:-IP bilinmiyor})"
  # Mod ETIKETIN ICINDE: "DNS (harici)" / "DNS (bind)". Degeri satirin
  # sagina yazmak yerine boyle daha kisa ve sutun hizasi bozulmuyor -
  # etiketler 12 karaktere yaslaniyor.
  local dnslabel
  if [ -n "${DNS_MODE:-}" ] && [ "$DNS_MODE" != bilinmiyor ]; then
    dnslabel="DNS ($DNS_MODE)"
  else
    dnslabel="DNS"
  fi
  say "$(printf '%-12s : %s' "$dnslabel" "${AUTH_NS:-bilinmiyor}")"
  say "               zone sablonundaki cift: ${NS1:-} / ${NS2:-}"
  if [ -n "$dfeat" ]; then say "Ozellikler   : $dfeat"; fi
  if [ -n "$dplug" ]; then say "Eklentiler   : $dplug"; fi
  # Elle birlestiriliyor: 'IFS=" | "' ile "${comps[*]}" ISE YARAMAZ, bash
  # IFS'in yalnizca ILK karakterini ayirici olarak kullanir (yani bosluk).
  if [ ${#comps[@]} -gt 0 ]; then
    local joined="" c
    for c in "${comps[@]}"; do
      if [ -z "$joined" ]; then joined="$c"; else joined="$joined | $c"; fi
    done
    say "Bilesenler   : $joined"
  fi

  if [ ${#VMINKIT_FAILED[@]} -gt 0 ]; then
    say ""
    say "BASARISIZ ADIMLAR: ${VMINKIT_FAILED[*]}"
    say "  Sebepleri yukarida ve kurulum kaydinda. Duzeltip tekrar calistirin."
  fi

  say ""
  say "Adresler"
  say "  Site       : https://${MAIN_DOMAIN}"
  if [ "$(awk -F= '/^bind=/{print $2; exit}' /etc/webmin/miniserv.conf 2>/dev/null)" = "127.0.0.1" ]; then
    say "  Panel      : https://${WEBMIN_PREFIX:-webmin}.${MAIN_DOMAIN}/  (10000 disariya kapali)"
  else
    say "  Panel      : https://${HOSTNAME_FQDN}:10000"
  fi
  if is_truthy "${ROUNDCUBE:-0}"; then
    say "  Webmail    : https://${WEBMAIL_PREFIX:-webmail}.${MAIN_DOMAIN}/"
  fi
  if is_truthy "${DOCKER:-0}"; then
    say "  Portainer  : https://${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}/"
  fi

  # Disariya acik dinleyen portlar. Guvenlik duvarini bu arac yonetmiyor;
  # en azindan sonucun ne oldugu gorunsun - 10000/20000 burada gorunuyorsa
  # kilitleme adimi calismamis demektir.
  #
  # SUREC ADIYLA: yalniz port numarasi "bu da neyin nesi" sorusunu cevapsiz
  # birakiyordu. '-p' surec adini veriyor (root oldugumuz icin gorunuyor).
  #
  # Boru hatti dogrudan yazmiyor, once degiskene aliniyor: 'say' disindaki
  # her cikti yalnizca log dosyasina gider, ekranda gorunmezdi.
  if command -v ss >/dev/null 2>&1; then
    local portlist
    portlist="$(ss -ltnpH 2>/dev/null | awk '
      {
        addr = $4
        # Yalnizca yerel dinleyenler bizi ilgilendirmiyor.
        #
        # TUM 127.0.0.0/8 eleniyor, yalnizca 127.0.0.1 degil: systemd-resolved
        # "127.0.0.53%lo" ve "127.0.0.54" uzerinde dinliyor. Dar suzgec bunu
        # "disariya acik" gosteriyor, ustelik ayni porttaki GERCEK dinleyiciyi
        # (named) de gizliyordu - temiz kurulumda "53 systemd-resolve" diye
        # cikti, oysa dogrusu "53 named". Gercek 'ss' ciktisiyla dogrulandi.
        #
        # fe80::/10 de eleniyor: baglanti-yerel adresler yalnizca ayni ag
        # segmentinden erisilebilir, "disariya acik" sayilmaz. named her
        # arayuz icin bir tane aciyor (ens192, docker0, veth...).
        #
        # Docker koprusu (172.17.x) BILEREK eleniyor DEGIL: oradan bir
        # konteyner erisebilir, yani gercek bir yol.
        if (addr ~ /^127\./ || addr ~ /^\[::1\]:/ || addr ~ /^\[[Ff][Ee]80:/) next
        n = split(addr, a, ":")
        port = a[n]
        # users:(("ad",pid=...  -> ad. Onek 9 karakter, kapanis tirnagi 1.
        name = "?"
        if (match($0, /users:\(\("[^"]+"/)) {
          name = substr($0, RSTART + 9, RLENGTH - 10)
        }
        # Ayni port hem IPv4 hem IPv6 icin gorunuyor; bir kez yazalim.
        if (!(port in seen) || seen[port] == "?") seen[port] = name
      }
      END { for (p in seen) printf "%s %s\n", p, seen[p] }
    ' | sort -n -u | awk '
      { rows[NR] = sprintf("%5s  %-18s", $1, $2) }
      END {
        # Iki sutun: liste uzun, tek sutunda raporu gereksiz uzatiyor.
        half = int((NR + 1) / 2)
        for (i = 1; i <= half; i++) {
          line = sprintf("  %s%s", rows[i], (i + half <= NR ? rows[i + half] : ""))
          sub(/[ \t]+$/, "", line)   # sagda bosluk birakma
          print line
        }
      }
    ')"
    say ""
    say "Dinleyen portlar (yerel olmayan adreslerde)"
    if [ -n "$portlist" ]; then
      say "$portlist"
    else
      # 'ss' var ve calisti; bos sonuc "okunamadi" degil "hicbiri" demek.
      say "  (yok - yalnizca 127.0.0.1 uzerinde dinleyenler var)"
    fi
    # GUVENLIK DUVARI DURUMU BURADA RAPORLANMIYOR - bilerek.
    #
    # Bir sure "nftables kural seti yuklu/bos" diye bir satir vardi ve iki
    # sekilde birden yanlisti:
    #
    #   1) KAPSAM DISI. Bu bir kurulum araci; "hangi portlar dinliyor" bir
    #      olgu, "guvenlik duvari ne durumda" ise ayri bir konu ve henuz
    #      incelemedigimiz bir sey hakkinda yorum yapmis oluyorduk.
    #
    #   2) OLCUM DE YANLISTI. 'nft list ruleset | grep -q ...' kaliyordu:
    #      grep ilk eslesmede cikinca nft SIGPIPE ile 141 donuyor ve
    #      'set -o pipefail' bunu tum boru hattinin hatasi sayiyor - kural
    #      seti DOLUYKEN "BOS" yaziyordu. (Kucuk ciktilarda uremiyor, boru
    #      arabellegine sigiyor; gercek nft ciktisi sigmiyor.)
    #
    # Gerektiginde guvenlik duvari yapilandirmasi ayri bir adim olarak
    # eklenir; o zamana kadar burada yalnizca dinleyen soketler yaziyor.
  fi

  # NOTLAR: yalnizca ILERIDE YAPILACAK, kendiliginden olmayacak seyler.
  # Nasil yapilacagi README'de; burada sadece hatirlatma.
  say ""
  say "Notlar"
  say "  - Domain sahibi sifresi saklanmadi; gerekirse panelden belirleyin."
  case " $dfeat " in
    *" mail "*)
      say "  - DMARC 'p=none' ile basliyor; birkac hafta sonra quarantine'e cekin."
      ;;
  esac
  # Harici DNS icin ayrica bir hatirlatma YOK: Cloudflare senkron eklentisi
  # tam da bu is icin var, yani "A kaydini saglayicida da ac" demek hem
  # gereksiz hem de kendi aracimizin yaptigi isi bilmiyormus gibi duruyor.
  if [ "${DNS_MODE:-}" = bind ]; then
    say "  - Registrar'da ${NS1:-ns1} / ${NS2:-ns2} icin glue kaydi: ${ip:-<sunucu-ip>}"
  fi
  say "  - Ayrinti ve sorun giderme: README.md"
  say ""

  # Ikinci sunucu icin ayrica bir cevap dosyasi URETMIYORUZ: ayarlar zaten
  # depodaki config.env icinde duruyor. Yeni sunucuda depoyu cekip ana
  # domaini yazmak yeterli.
}
