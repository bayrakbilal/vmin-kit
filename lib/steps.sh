#!/usr/bin/env bash
# Adim fonksiyonlari. install.sh bunlari ACIK SIRAYLA cagirir.
# Gerekli degiskenler install.sh tarafindan set edilir / config.env'den gelir:
#   MAIN_DOMAIN, HOSTNAME_FQDN, NS1, NS2, DNS_MODE, POSTGRES,
#   docker, portainer, PORTAINER_*
# Hepsi idempotent: ikinci kez calistirmak zarar vermez.

VMINKIT_REPORT="$ROOT_DIR/vmin-kit-rapor.txt"

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
  log "Virtualmin resmi installer indiriliyor..."
  curl -fsSL https://software.virtualmin.com/gpl/scripts/virtualmin-install.sh -o /root/virtualmin-install.sh
  chmod +x /root/virtualmin-install.sh
  # Dikkat: software.virtualmin.com'un servis ettigi installer, kaynak
  # depodaki surumden eskidir; --extra / --include / --type gibi bayraklar
  # orada YOK. Yalnizca her surumde bulunan bayraklar kullanilir.
  local args=(--force --hostname "$HOSTNAME_FQDN")
  log "Calistiriliyor (uzun surer): virtualmin-install.sh ${args[*]}"
  sh /root/virtualmin-install.sh "${args[@]}"
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
    | grep -qi 'cert issued' && return 0
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

# Virtualmin her yeni domaine admin.<domain> A kaydi ve o adi panele
# (https://<domain>:10000) goturen bir 301 yonlendirmesi ekliyor. Bunu
# istemiyoruz: panele hostname uzerinden giriliyor.
#
# Ayar SABLON duzeyinde tutuluyor (web_admin). Varsayilan sablonun ayri bir
# dosyasi yok: list_templates() 0 numarali sablonu dogrudan modul
# yapilandirmasindan uretiyor, save_template() de oraya geri yaziyor. Bu yuzden
# dogru yer /etc/webmin/virtual-server/config - dns-template adiminin yazdigi
# dosyanin ayni.
#
# Tek anahtar iki seyi birden kapatiyor: DNS kaydini
# (add_webmail_dns_records_to_file) ve Apache yonlendirmesi ile ServerAlias'i
# (add_webmail_redirect_directives). ServerAlias gitince ad sertifikaya da
# girmiyor - get_hostnames_for_ssl yalnizca web sunucusunun gercekten cevap
# verdigi adlari topluyor.
#
# DOMAIN OLUSTURMADAN ONCE calismali: sonradan kapatmak var olan domainlerin
# kaydini ve yonlendirmesini temizlemiyor.
#
# webmail.<domain> ayni mekanizmada (web_webmail) ama BILEREK acik birakildi:
# bir domainde mail acilirsa kisayol hazir olsun.
step_admin_redirect(){
  local cfg="/etc/webmin/virtual-server/config"
  if [ ! -f "$cfg" ]; then err "Virtualmin config yok; admin yonlendirmesi atlaniyor."; return 1; fi
  [ -f "${cfg}.vmin-kit.bak" ] || cp -a "$cfg" "${cfg}.vmin-kit.bak"
  if [ "$(awk -F= '/^web_admin=/{print $2; exit}' "$cfg")" = "0" ]; then
    ok "admin.<domain> yonlendirmesi zaten kapali."
    return
  fi
  set_kv "$cfg" web_admin "0"
  ok "admin.<domain> yonlendirmesi kapatildi (bundan sonra olusan domainler icin)."
}

# Ana domaini SADE olusturur: web + SSL + DNS.
# Mail ve veritabani BILEREK kapali - ikisi de domain basina onay kutusu,
# istendigi an panelden acilir (Edit Virtual Server -> Enabled features).
step_main_domain(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; ana domain atlaniyor."; return 1; }
  if virtualmin list-domains --name-only 2>/dev/null | grep -qx "$MAIN_DOMAIN"; then
    ok "Ana domain zaten var: $MAIN_DOMAIN (atlaniyor)."; return
  fi
  # Sifre rastgele uretilir ve HICBIR YERE yazilmaz. Kullanilmasi gerekirse
  # (Webmin girisi, FTP) panelden degistirilir; saklanmayan sir sizmaz.
  local pw; pw="$(gen_pass)"
  log "Ana domain olusturuluyor: $MAIN_DOMAIN  (web + SSL + DNS; mail ve veritabani kapali)"
  virtualmin create-domain \
    --domain "$MAIN_DOMAIN" \
    --pass   "$pw" \
    --desc   "$MAIN_DOMAIN" \
    --unix --dir --web --ssl --dns --webmin
  unset pw
  ok "Ana domain olusturuldu."
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
     | sed 's/\.$//' | grep -qixF "$HOSTNAME_FQDN"; then
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
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx portainer || return 0
  local site="${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}"

  echo
  if portainer_configured; then
    ok "Portainer : https://${site}/   (yonetici hesabi zaten olusturulmus)"
    return 0
  fi

  log "Portainer icin taze setup_token aliniyor (yeniden baslatiliyor)..."
  local tok; tok="$(portainer_restart_for_token || true)"
  echo
  if [ -n "$tok" ]; then
    ok "Portainer kurulumunu SIMDI tamamlayin - token birkac dakika gecerli:"
    echo "    Adres       : https://${site}/"
    echo "    setup_token : $tok"
    echo
    log "Sureyi kacirirsaniz: sudo ./configure-docker.sh"
  else
    warn "setup_token okunamadi. Deneyin: sudo ./configure-docker.sh"
  fi
}

# docker.<domain> alt sunucusu + Portainer'a proxy.
# Alt sunucu (--parent) kendi Unix kullanicisini olusturmaz; --break-ssl-cert
# ile ana domainin sertifikasina baglanmak yerine kendi sertifikasini alir
# (ana domainin sertifikasi bu ismi kapsamiyor).
step_docker_site(){
  command -v virtualmin >/dev/null 2>&1 || { err "Virtualmin yok; docker sitesi atlaniyor."; return 1; }
  local site="${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}"
  local port="${PORTAINER_PORT:-9000}"
  local url="http://127.0.0.1:${port}/"

  if virtualmin list-domains --name-only 2>/dev/null | grep -qxF "$site"; then
    ok "Alt sunucu zaten var: $site"
  else
    log "Alt sunucu olusturuluyor: $site (ana domain: $MAIN_DOMAIN)"
    if ! virtualmin create-domain \
           --domain "$site" \
           --parent "$MAIN_DOMAIN" \
           --desc   "Portainer (vmin-kit)" \
           --dir --web --ssl --break-ssl-cert; then
      err "$site olusturulamadi; proxy adimi atlaniyor."
      return 1
    fi
    ok "Alt sunucu olusturuldu: $site"
  fi

  # Proxy zaten tanimli mi? (vhost dosyasinda hedef URL'yi ariyoruz)
  local vhost="/etc/apache2/sites-available/${site}.conf"
  if [ -f "$vhost" ] && grep -q "127.0.0.1:${port}" "$vhost"; then
    ok "Proxy zaten tanimli: / -> $url"
  else
    log "Proxy ekleniyor: / -> $url  (websocket destegiyle)"
    if virtualmin create-proxy --domain "$site" --path / --url "$url" --websockets; then
      ok "Proxy eklendi."
    else
      warn "Proxy eklenemedi. Elle:"
      warn "  virtualmin create-proxy --domain $site --path / --url $url --websockets"
    fi
  fi
}

step_docker(){
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then ok "Docker zaten kurulu (atlaniyor)."; return; fi
  local pkg
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then log "Cakisan paket kaldiriliyor: $pkg"; apt-get remove -y "$pkg" || true; fi
  done
  apt-get update; apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local arch code; arch="$(dpkg --print-architecture)"; code="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${code} stable" > /etc/apt/sources.list.d/docker.list
  fi
  apt-get update; apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  if docker run --rm hello-world >/dev/null 2>&1; then ok "Docker kuruldu ($(docker --version))."; else err "Docker hello-world testi basarisiz."; return 1; fi
}

step_portainer(){
  command -v docker >/dev/null 2>&1 || { err "Docker yok; portainer atlaniyor."; return 1; }
  local image="${PORTAINER_IMAGE:-portainer/portainer-ce:latest}" port="${PORTAINER_PORT:-9000}" pub
  if [ "${PORTAINER_BIND_LOCAL:-yes}" = "yes" ]; then pub="127.0.0.1:${port}:9000"; else pub="${port}:9000"; fi
  if docker ps -a --format '{{.Names}}' | grep -qx portainer; then
    if docker ps --format '{{.Names}}' | grep -qx portainer; then ok "Portainer zaten calisiyor (atlaniyor)."; return; fi
    docker start portainer >/dev/null; ok "Portainer baslatildi."; return
  fi
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  docker run -d --name portainer --restart=always -p "$pub" \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data "$image" >/dev/null
  ok "Portainer calisiyor -> $pub"
}

# Kurulum sonrasi hafiza: ne yapildi, sifre nerede, ikinci sunucu icin config.env.
step_report(){
  local ip pg dk pt
  ip="$(detect_ip)"
  if is_truthy "${POSTGRES:-1}"; then pg=kuruldu; else pg=atlandi; fi
  if command -v docker >/dev/null 2>&1; then dk=var; else dk=yok; fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx portainer; then pt=calisiyor; else pt=yok; fi

  {
    echo "vmin-kit kurulum raporu - $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "======================================================="
    echo "Ana domain   : $MAIN_DOMAIN"
    echo "Hostname     : $HOSTNAME_FQDN"
    echo "Sunucu IP    : ${ip:-bilinmiyor}"
    echo "DNS modu     : ${DNS_MODE:-bilinmiyor}"
    echo "Sunucu NS    : ${NS1:-} / ${NS2:-}   (zone sablonunda kullanilan cift)"
    echo "Otoriter NS  : ${AUTH_NS:-bilinmiyor}   (domainin gercekte delege edildigi yer)"
    echo "PostgreSQL   : $pg"
    echo "Docker       : $dk"
    echo "Portainer    : $pt"
    echo
    echo "Panel        : https://${HOSTNAME_FQDN}:10000"
    if is_truthy "${DOCKER:-0}"; then
      echo "Portainer    : https://${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}/"
      echo "               Ilk giriste setup_token istenir. Token kisa omurludur;"
      echo "               suresi dolduysa: sudo ./configure-docker.sh"
    fi
    echo
    echo "Domain sahibi ($MAIN_DOMAIN) sifresi rastgele uretildi ve saklanmadi."
    echo "Webmin girisi ya da FTP gerekirse panelden yeni bir sifre belirleyin:"
    echo "  Virtualmin -> Edit Virtual Server -> Password"
    echo
    echo "Ana domain SADE olusturuldu: web + SSL + DNS."
    echo "Mail ve veritabani KAPALI - gerektiginde panelden acilir:"
    echo "  Virtualmin -> Edit Virtual Server -> Enabled features"
    echo
    if [ "${DNS_MODE:-}" = bind ]; then
      echo "Yapilacak (BIND modu): registrar tarafinda ${NS1:-ns1} / ${NS2:-ns2} icin"
      echo "glue kaydi -> ${ip:-<sunucu-ip>}"
    else
      echo "DNS harici saglayicida: ${AUTH_NS:-bilinmiyor}"
      echo "Yerel BIND zone'u yine de uretilir ve Virtualmin tarafindan guncellenir;"
      echo "yayinlanan kopya harici saglayicidadir. Yeni domain/alt domain eklerken"
      echo "A kaydini orada olusturmayi unutmayin."
    fi
  } > "$VMINKIT_REPORT"
  chmod 600 "$VMINKIT_REPORT"
  ok "Rapor: $VMINKIT_REPORT"

  # Ikinci sunucu icin ayrica bir cevap dosyasi URETMIYORUZ: ayarlar zaten
  # depodaki config.env icinde duruyor. Yeni sunucuda depoyu cekip ana
  # domaini yazmak yeterli.
}
