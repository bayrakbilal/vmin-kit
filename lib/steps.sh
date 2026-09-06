#!/usr/bin/env bash
# Adim fonksiyonlari. install.sh bunlari ACIK SIRAYLA cagirir.
# Gerekli degiskenler install.sh tarafindan set edilir / config.env'den gelir:
#   MAIN_DOMAIN, HOSTNAME_FQDN, NS1, NS2, DNS_MODE, ADMIN_EMAIL, POSTGRES,
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

# Bir Virtualmin ozelliginin acik olup olmadigini soyler: Yes / No / bos.
# list-features --multiline ciktisi: ozellik adi girintisiz, alanlari girintili.
vm_feature_enabled(){
  virtualmin list-features --multiline 2>/dev/null | awk -v w="$1" '
    /^[^[:space:]]/ { f=$1; next }
    f==w && /^[[:space:]]*Enabled:/ { print $2; exit }'
}

# PostgreSQL Virtualmin kurulumuyla GELMEZ; ayrica kurulup ozellik olarak acilir.
step_postgres(){
  if ! command -v psql >/dev/null 2>&1; then
    log "PostgreSQL kuruluyor..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
  else
    ok "PostgreSQL zaten kurulu."
  fi
  systemctl enable --now postgresql 2>/dev/null || warn "postgresql servisi baslatilamadi."

  if [ "$(vm_feature_enabled postgres)" = Yes ]; then
    ok "PostgreSQL ozelligi Virtualmin'de zaten acik."
    return
  fi

  # Ozellik ancak Webmin'in postgresql modulu "available" oldugunda acilabiliyor
  # (feature-postgres.pl -> check_module_postgres -> foreign_available).
  # Modulu Virtualmin'in kendi yapilandirma eklentisi kurar; --include bundle
  # olmadan calisir, yani yalnizca PostgreSQL yapilandirilir.
  if command -v virtualmin-config-system >/dev/null 2>&1; then
    log "Webmin PostgreSQL modulu yapilandiriliyor..."
    virtualmin-config-system --include PostgreSQL || warn "PostgreSQL yapilandirmasi hata verdi."
  else
    warn "virtualmin-config-system bulunamadi; modul yapilandirmasi atlandi."
  fi

  local out
  if out="$(virtualmin set-global-feature --enable-feature postgres 2>&1)"; then
    ok "PostgreSQL kuruldu ve Virtualmin ozelligi acildi."
    return
  fi
  # Komut hata dondurse bile ozellik acilmis olabilir (or. "zaten acik").
  # Karar verirken cikis kodunu degil, gercek durumu esas al.
  if [ "$(vm_feature_enabled postgres)" = Yes ]; then
    ok "PostgreSQL ozelligi acik."
    return
  fi
  warn "PostgreSQL kuruldu, ancak Virtualmin ozelligi acilamadi:"
  printf '%s\n' "$out" | sed 's/^/      /'
  warn "Panelden: System Settings -> Features and Plugins -> PostgreSQL"
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
  if virtualmin list-domains --domain "$MAIN_DOMAIN" --multiline 2>/dev/null \
     | grep -q 'SSL provider cert issued:'; then
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

  # Ikinci sunucu icin hazir cevaplar: bir daha hicbir sey hatirlamak gerekmesin.
  if [ ! -f "$ROOT_DIR/config.env" ]; then
    {
      echo "# vmin-kit - bu kurulumdan uretildi ($(date '+%Y-%m-%d'))."
      echo "# Ikinci sunucuda: kopyala, MAIN_DOMAIN'i degistir, ./install.sh"
      echo "MAIN_DOMAIN=$MAIN_DOMAIN"
      echo "HOST_PREFIX=${HOST_PREFIX:-s}"
      echo "ADMIN_EMAIL=${ADMIN_EMAIL:-}"
      echo "POSTGRES=${POSTGRES:-1}"
      echo "docker=${docker:-0}"
      echo "portainer=${portainer:-0}"
      echo "PORTAINER_IMAGE=${PORTAINER_IMAGE:-portainer/portainer-ce:latest}"
      echo "PORTAINER_PORT=${PORTAINER_PORT:-9000}"
      echo "PORTAINER_BIND_LOCAL=${PORTAINER_BIND_LOCAL:-yes}"
    } > "$ROOT_DIR/config.env"
    ok "config.env uretildi (ikinci sunucu icin hazir cevaplar)."
  fi
}
