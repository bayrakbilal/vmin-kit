#!/usr/bin/env bash
# doctor.sh - vmin-kit'in Virtualmin'e olan BAGIMLILIKLARINI dogrular.
#
#   sudo ./doctor.sh
#
# NEDEN VAR?
# Bu araç Virtualmin'in yayimlanmis bir API'sini degil, IC fonksiyonlarini,
# CLI komutlarini ve config anahtarlarini kullaniyor. Bunlarin hicbiri
# "kararli arayuz" sozu vermiyor; bir Virtualmin yukseltmesi birini yeniden
# adlandirirsa eklenti sayfasi 500 verir ya da - daha kotusu - install adimi
# hicbir sey yapmadan sessizce basarili olur.
#
# Bu yuzden kontrol KURULUM ANINDA degil, ISTENDIGINDE calisiyor: risk
# yukseltmeden SONRA doguyor, kurulumda her sey zaten calisiyordu.
#
# LISTELER ELLE TUTULMUYOR. Elle yazilmis bir liste alti ay icinde curur:
# yeni bir fonksiyon kullaniriz, doctor bilmez ve bos yere "her sey yolunda"
# der. Onun yerine bagimliliklar her calistirmada KAYNAK KODDAN cikariliyor.
#
# Cikis kodu: 0 = her sey yerinde, 1 = eksik var.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
require_root

WEBMIN_ROOT="$(webmin_root)"
VS_DIR="$WEBMIN_ROOT/virtual-server"
[ -d "$VS_DIR" ] || { err "Virtualmin bulunamadi: $VS_DIR"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MISSING=0

# ---------------------------------------------------------------------------
# 1) PERL SEMBOLLERI
#
# Eklentiler Virtualmin'e 'virtual_server::' ve 'bind8::' onekleriyle
# eristigi icin cikarmasi kolay. install.sh'in gomulu perl bloklari ise
# oneksiz cagiriyor ('&check_dkim()'); bash'te '&isim(' diye bir sozdizim
# olmadigindan o kaliba uyan her satir gomulu perl demek.
# ---------------------------------------------------------------------------
log "Bagimliliklar kaynaktan cikariliyor..."

# KOD OLMAYAN SATIRLAR ELENIYOR. Iki kaynak da yasandi:
#
#   - YORUMLAR: kaldirilmis bir cagriyi yorumda anlatmak ('once su fonksiyon
#     cagriliyordu') doctor'a hala kullaniyormusuz gibi gorunuyordu.
#
#   - KENDI MESAJLARIMIZ: log/ok/warn/err/say satirlarindaki metin komut
#     saniliyordu. Ornek: 'log "... virtualmin install.sh ..."' satiri
#     "virtualmin install" diye bir CLI komutu uydurdu ve doctor onu eksik
#     bildirdi. Bu fonksiyonlar hicbir zaman komut calistirmaz, dolayisiyla
#     o satirlarda aranacak bir bagimlilik da yoktur.
code_lines(){
  grep -rhv -e '^[[:space:]]*#' -e '^[[:space:]]*\(log\|ok\|warn\|err\|say\)[[:space:]]' \
    "$@" 2>/dev/null || true
}

# sigil + paket + isim
code_lines "$ROOT_DIR/plugin" \
  | grep -oE '[&$@%](virtual_server|bind8)::[a-zA-Z_0-9]+' \
  | sed -E 's/^(.)([a-z8_]+)::(.*)$/\1\t\2\t\3/' \
  | sort -u > "$TMP/symbols"

# install tarafi: oneksiz gomulu perl cagrilari. Bunlarin bir kismi Webmin
# cekirdeginden (lock_file gibi), bir kismi Virtualmin'den; ikisi de ayni
# yerde aranabildigi icin ayirmiyoruz.
code_lines "$ROOT_DIR/lib" "$ROOT_DIR/install.sh" \
  | grep -oE '&[a-z_][a-z_0-9]*\(' \
  | sed 's/($//; s/(//; s/^&//' \
  | sort -u | sed 's/^/\&\tmain\t/' >> "$TMP/symbols"

sort -u -o "$TMP/symbols" "$TMP/symbols"
SYM_COUNT="$(wc -l < "$TMP/symbols")"

# ---------------------------------------------------------------------------
# 2) CLI KOMUTLARI
#
# Virtualmin'in 'virtualmin <komut>' dagiticisi komutu modul dizinindeki
# '<komut>.pl' dosyasina esliyor, yani dosyanin varligi dogru kontrol.
# ---------------------------------------------------------------------------
code_lines "$ROOT_DIR/lib" "$ROOT_DIR"/*.sh \
  | grep -oE '\bvirtualmin [a-z][a-z-]+' \
  | sed 's/^virtualmin //' | sort -u > "$TMP/commands"
CMD_COUNT="$(wc -l < "$TMP/commands")"

# ---------------------------------------------------------------------------
# 3) CONFIG ANAHTARLARI
#
# Dort yazma kalibimiz var; dordunu de tariyoruz. Burada elle tutulan sey
# anahtar listesi DEGIL, kaliplar - yeni bir yazma kalibi eklenirse buraya bir
# satir eklemek gerekir.
#
# ANAHTARI HANGI DOSYAYA YAZDIGIMIZA BAKMIYORUZ. Bir kismi Virtualmin'in
# config'ine, bir kismi miniserv.conf'a gidiyor ('redirect_port', 'referers')
# ve bunu bash kaynagindan guvenilir sekilde ayirmak kirilgan oluyor - denendi,
# miniserv anahtarlarini Virtualmin kaynaginda arayip bos yere alarm verdi.
# Onun yerine dokundugumuz TUM bilesenlerde ariyoruz; sorumuz zaten "bu ad
# hala taniniyor mu". Silinmis bir anahtari yazmak hata vermez, sessizce
# hicbir ise yaramaz - asil yakalamak istedigimiz sey bu.
#
# Uc karakterden kisa adlar eleniyor: sed ifadelerinden gelen 's' gibi sahte
# eslesmeler oluyor ve bizim anahtarlarimizin hicbiri o kadar kisa degil.
# ---------------------------------------------------------------------------
# Her kalip AYRI islenip anahtar adina indirgeniyor. Tek bir buyuk sed
# ifadesiyle denendi ve kirilgan cikti (ERE'de '{' ozel karakter).
{
  # set_kv "$cfg" <anahtar> ...   /   set_kv "$conf" <anahtar> ...
  grep -rhoE 'set_kv "\$[a-z]+" [a-z_][a-z_0-9]*' "$ROOT_DIR/lib" \
    | awk '{ print $NF }' || true
  # for row in "<anahtar>|deger|aciklama"
  grep -rhoE '"[a-z_][a-z_0-9]*\|' "$ROOT_DIR/lib" | tr -d '"|' || true
  # sed 's/^<anahtar>=//' ve awk '/^<anahtar>=/' - ikisi de '^<ad>=' iceriyor
  grep -rhoE '\^[a-z_][a-z_0-9]*=' "$ROOT_DIR/lib" | tr -d '^=' || true
  # gomulu perl: $config{<anahtar>} ya da $config{'<anahtar>'}
  grep -rhoE '\$config\{[^}]*\}' "$ROOT_DIR/lib" \
    | sed "s/.*[{]//; s/[}]//; s/'//g" || true
} | grep -E '^[a-z_][a-z_0-9]{2,}$' | sort -u > "$TMP/keys"
KEY_COUNT="$(wc -l < "$TMP/keys")"

# BENZERSIZ ad sayisi: uc eklenti ayni kancayi ayri ayri tanimliyor (toplam
# tanim ~53), ama dogrulanan sey adin kendisi.
HOOK_COUNT="$(grep -hoE '^sub feature_[a-z_0-9]+' "$ROOT_DIR"/plugin/*/virtual_feature.pl \
  | sort -u | wc -l)"
log "Bulundu: $SYM_COUNT perl sembolu, $CMD_COUNT CLI komutu, $KEY_COUNT config anahtari, $HOOK_COUNT kanca adi"
echo

# ---------------------------------------------------------------------------
# 4) PERL SEMBOLLERINI DOGRULA
#
# virtual-server-lib.pl dogrudan yukleniyor, yani fonksiyonlar 'main::'
# icinde olusuyor. Eklentiler bunlari foreign_require ile 'virtual_server::'
# altinda goruyor ama ISIM KUMESI ayni - "bu fonksiyon hala var mi" sorusunun
# cevabi degismiyor.
#
# Fonksiyon olmayanlar (%text, @plugins gibi) icin sembol tablosuna bakiyoruz:
# bir dizi mesru olarak bos olabilecegi icin 'defined' dogru olcut degil.
# ---------------------------------------------------------------------------
log "Perl sembolleri dogrulaniyor..."
# Program AYRI DOSYAYA yaziliyor: 'perl - <liste <<PERL' calismaz, cunku
# 'perl -' programi da stdin'den okur ve iki akis carpisir - liste hic
# okunmazdi.
cat > "$TMP/check.pl" <<'PERL'
my ($root) = @ARGV;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'}    ||= "/var/webmin";
push(@INC, $root);
$main::no_acl_check++;
chdir("$root/virtual-server");
$0 = "$root/virtual-server/doctor.pl";
require "./virtual-server-lib.pl";
eval { &foreign_require("bind8"); };

while(my $l = <STDIN>) {
	chomp($l);
	my ($sigil, $pkg, $name) = split(/\t/, $l);
	next if (!$name);
	# Eklentideki 'virtual_server::' ile buradaki 'main::' ayni kume.
	my $p = $pkg eq 'bind8' ? 'bind8' : 'main';
	my $ok;
	if ($sigil eq '&') {
		no strict 'refs';
		$ok = defined(&{"${p}::${name}"}) ? 1 : 0;
		}
	else {
		no strict 'refs';
		$ok = exists ${"${p}::"}{$name} ? 1 : 0;
		}
	print(($ok ? "OK" : "MISSING"), "\t", $sigil, $pkg, "::", $name, "\n");
	}
PERL
perl "$TMP/check.pl" "$WEBMIN_ROOT" < "$TMP/symbols" > "$TMP/symres"

while IFS=$'\t' read -r state sym; do
  if [ "$state" = "MISSING" ]; then err "eksik: $sym"; MISSING=$((MISSING + 1)); fi
done < "$TMP/symres"
GOOD="$(grep -c '^OK' "$TMP/symres" || true)"
ok "$GOOD sembol yerinde"
echo

# ---------------------------------------------------------------------------
# 5) CLI KOMUTLARINI DOGRULA
# ---------------------------------------------------------------------------
log "CLI komutlari dogrulaniyor..."
CMD_OK=0
while read -r cmd; do
  [ -n "$cmd" ] || continue
  if [ -r "$VS_DIR/$cmd.pl" ]; then
    CMD_OK=$((CMD_OK + 1))
  else
    err "eksik komut: virtualmin $cmd  ($VS_DIR/$cmd.pl yok)"
    MISSING=$((MISSING + 1))
  fi
done < "$TMP/commands"
ok "$CMD_OK CLI komutu yerinde"
echo

# ---------------------------------------------------------------------------
# 6) CONFIG ANAHTARLARINI DOGRULA
# ---------------------------------------------------------------------------
log "Config anahtarlari dogrulaniyor..."
KEY_OK=0
# Dokundugumuz bilesenler: Virtualmin, miniserv'in kendisi, Webmin modulu ve
# BIND. Anahtarin hangisine ait oldugunu bilmemize gerek yok.
KEY_SEARCH=( "$VS_DIR"/*.pl "$WEBMIN_ROOT"/*.pl )
[ -d "$WEBMIN_ROOT/webmin" ] && KEY_SEARCH+=( "$WEBMIN_ROOT"/webmin/*.pl )
[ -d "$WEBMIN_ROOT/bind8" ]  && KEY_SEARCH+=( "$WEBMIN_ROOT"/bind8/*.pl )
while read -r key; do
  [ -n "$key" ] || continue
  if grep -qE "\b$key\b" "${KEY_SEARCH[@]}" 2>/dev/null; then
    KEY_OK=$((KEY_OK + 1))
  else
    warn "anahtar Virtualmin kaynaginda gecmiyor: $key"
    MISSING=$((MISSING + 1))
  fi
done < "$TMP/keys"
ok "$KEY_OK config anahtari yerinde"
echo

# ---------------------------------------------------------------------------
# 7) EKLENTI KANCALARI - sozlesmenin BIZI CAGIRAN tarafi
#
# Yukaridaki bolumler bizim Virtualmin'den ne istedigimize bakiyor. Bu bolum
# tersini kontrol ediyor: Virtualmin bizim yazdigimiz feature_* kancalarini
# hala cagiriyor mu?
#
# Bir kanca yeniden adlandirilir ya da kaldirilirsa HICBIR HATA OLMAZ -
# fonksiyonumuz dosyada oylece durur, hic cagrilmaz. Ozellik sessizce
# kurulmaz, yedek sessizce alinmaz. Fark edilmesi en zor bozulma bicimi.
#
# Olcut: kanca adinin Virtualmin'in kaynaginda TIRNAK ICINDE gecmesi. Cagri
# sozdizimini ('plugin_call($f, "feature_x"') eslestirmek denendi ve
# YETMEDI: cagrilarin bir kismi cok satirli, ad ayri satira dusuyor ve
# satir bazli arama kaciriyor - feature_restore boyle kacmisti.
# ---------------------------------------------------------------------------
log "Eklenti kancalari dogrulaniyor..."
grep -hoE '^sub feature_[a-z_0-9]+' "$ROOT_DIR"/plugin/*/virtual_feature.pl \
  | sed 's/^sub //' | sort -u > "$TMP/hooks_ours"
grep -hoE "['\"]feature_[a-z_0-9]+['\"]" "$VS_DIR"/*.pl "$VS_DIR"/*.cgi 2>/dev/null \
  | tr -d "\"'" | sort -u > "$TMP/hooks_called"

HOOK_OK=0
while read -r h; do
  [ -n "$h" ] || continue
  if grep -qxF "$h" "$TMP/hooks_called"; then
    HOOK_OK=$((HOOK_OK + 1))
  else
    err "Virtualmin bu kancayi hic cagirmiyor: $h"
    MISSING=$((MISSING + 1))
  fi
done < "$TMP/hooks_ours"
ok "$HOOK_OK eklenti kancasi Virtualmin tarafindan cagriliyor"
echo

# ---------------------------------------------------------------------------
# 8) MINISERV'IN 'unauthcgi' LISTESI
#
# vmkit-deploy, webhook adresini miniserv'in giris istemeden CALISTIRILACAK
# CGI'ler listesine ekliyor. O anahtarin varsayilani miniserv.conf'ta DURMUYOR,
# miniserv'in kodundaki %vital tablosunda duruyor ve yalnizca dosyada anahtar
# hic yokken uygulaniyor:
#
#   foreach my $v (keys %vital) { if (!$config{$v}) { $config{$v} = $vital{$v} } }
#
# Dolayisiyla anahtari yazan taraf varsayilanin tamamini yeniden uretmek
# zorunda; uretmezse varsayilan sessizce kayboluyor - 'unauthcgi' icin bu
# Webmin'in parola kurtarma sayfalari demek.
#
# Eklenti listeyi her calistiginda kaynaktan okuyup birlestiriyor, ama aradaki
# bir Webmin yukseltmesi varsayilana yeni bir kalem eklerse dosyadaki kopya
# eksik kalir. Kontrol edilen sozlesme bu: kaynaktaki her kalem dosyadaki
# listede de var mi?
#
# Varsayilanlarin surumler arasinda degistigi olculdu: 'unauth' listesi
# 1.990'dan 2.111'e kadar ayni kalmis, 2.202'de '^/service-worker.js$'
# eklenmis. Yani bu senaryo kuramsal degil.
# ---------------------------------------------------------------------------
log "miniserv unauthcgi listesi dogrulaniyor..."
MSCONF="${WEBMIN_CONFIG:-/etc/webmin}/miniserv.conf"
UNAUTH_CUR="$(sed -n 's/^unauthcgi=//p' "$MSCONF" 2>/dev/null | head -1)"
if [ -z "$UNAUTH_CUR" ]; then
  # Anahtar dosyada yok: miniserv kendi varsayilanini kullaniyor, dogrulanacak
  # bir sapma da yok.
  ok "unauthcgi anahtari dosyada yok (miniserv varsayilani gecerli)"
else
  # Kaynaktaki dize cift tirnak icinde yazilmis; '\$' ve '\\' kacislari Perl
  # tarafindan cozuluyor, burada da biz cozuyoruz. Regexte '\$' ile '$' ayni
  # sey degil, eslestirme bu yuzden kacislar cozulmeden yapilamaz.
  UNAUTH_RAW="$(grep -hoE '"unauthcgi", "[^"]*"' \
                  "$WEBMIN_ROOT/miniserv-lib.pl" "$WEBMIN_ROOT/miniserv.pl" \
                  2>/dev/null | head -1)"
  if [ -z "$UNAUTH_RAW" ]; then
    warn "miniserv kaynaginda unauthcgi varsayilani bulunamadi; karsilastirilamadi"
    MISSING=$((MISSING + 1))
  else
    UNAUTH_DEF="${UNAUTH_RAW#\"unauthcgi\", \"}"
    UNAUTH_DEF="${UNAUTH_DEF%\"}"
    UNAUTH_DEF="$(printf '%s' "$UNAUTH_DEF" | sed 's/\\\$/$/g; s/\\\\/\\/g')"
    UNAUTH_OK=0
    declare -A UNAUTH_SEEN=()
    # Dosya adi genislemesi KAPALI: kalemler '[A-Za-z0-9\-/_]' gibi ifadeler
    # iceriyor ve kelime bolunmesinden sonra kabuk bunlari dosya kalibi
    # sayabilir.
    set -f
    for d in $UNAUTH_DEF; do
      # Varsayilan listede '^/robots.txt$' iki kez geciyor (Webmin 1.990'dan
      # beri). Tekrari bir kez sayiyoruz.
      [ -n "${UNAUTH_SEEN[$d]:-}" ] && continue
      UNAUTH_SEEN["$d"]=1
      # Glob yerine birebir karsilastirma: 'case' kalibinda ayni ifadeler
      # karakter sinifi olarak yorumlanirdi.
      hit=0
      for c in $UNAUTH_CUR; do [ "$c" = "$d" ] && hit=1; done
      if [ "$hit" = 1 ]; then
        UNAUTH_OK=$((UNAUTH_OK + 1))
      else
        err "unauth listesinde eksik varsayilan: $d"
        MISSING=$((MISSING + 1))
      fi
    done
    set +f
    ok "$UNAUTH_OK unauthcgi varsayilani yerinde"
  fi
fi
echo

# ---------------------------------------------------------------------------
if [ "$MISSING" -eq 0 ]; then
  ok "Her sey yerinde. Virtualmin surumu: $(cat "$VS_DIR/module.info" 2>/dev/null | sed -n 's/^version=//p')"
  exit 0
fi
err "$MISSING bagimlilik dogrulanamadi."
err "Virtualmin yukseltmesinden sonra ilgili kodun elden gecirilmesi gerekiyor."
exit 1
