#!/usr/bin/env bash
# Update aplikasi dari paket rilis resmi, aman untuk kode yang terkunci:
#
#   sudo bash scripts/update.sh /path/sianok-parking-<versi>-<tanggal>.tar.gz
#
# Urutan: buka kunci kode → ekstrak paket ke folder ini → hapus views/ lama (halaman sekarang di views.pak)
# → sudo bash setup.sh --yes (dependency, migrasi database dengan backup dulu, reload PM2, health check, kunci lagi).
# Tidak disentuh: storage/, public/uploads, public/img, _backup/, .env.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Skrip ini ikut ditimpa saat paket diekstrak: jalankan dari salinan sementara.
if [ -z "${HP_UPDATE_SALINAN:-}" ]; then
  salinan="$(mktemp /tmp/hp-update.XXXXXX)"; cp "$0" "$salinan"
  HP_UPDATE_SALINAN="$salinan" HP_UPDATE_APP="$APP" exec bash "$salinan" "$@"
fi
APP="$HP_UPDATE_APP"
. "$APP/scripts/lib.sh"
HP_TMP_FILES+=("$HP_UPDATE_SALINAN")   # dihapus hp_cleanup (trap EXIT dari lib.sh)

ARSIP="${1:-}"
[ -f "$ARSIP" ] || { echo "Pakai: sudo bash $APP/scripts/update.sh <paket-rilis.tar.gz>"; exit 1; }
# Daftar isi dibaca utuh dulu: grep -q / head di belakang pipe memutus tar (SIGPIPE) dan pipefail menganggapnya gagal.
isi="$(tar -tzf "$ARSIP" 2>/dev/null)"
top="${isi%%/*}"
[ "$top" = "$HP_PM2_NAME" ] && printf '%s\n' "$isi" | grep -x "$top/views.pak" >/dev/null \
  || { echo "Bukan paket rilis $HP_PM2_NAME (folder $top, views.pak harus ada)."; exit 1; }

echo "Buka kunci kode..."
bash "$APP/scripts/kunci-kode.sh" buka || exit 1
echo "Ekstrak $(basename "$ARSIP") ke $APP ..."
if ! tar -xzf "$ARSIP" -C "$APP" --strip-components=1 --no-same-owner \
     --exclude="$top/storage" --exclude="$top/.env" --exclude="$top/_backup" \
     --exclude="$top/public/uploads" --exclude="$top/public/img"; then
  echo "Ekstrak gagal. Kode dikunci lagi; versi lama tetap dipakai (PM2 belum di-reload)."
  bash "$APP/scripts/kunci-kode.sh" kunci >/dev/null
  exit 1
fi
[ -f "$APP/views.pak" ] && rm -rf "$APP/views"
# File hasil ekstrak (oleh root) dimiliki pemilik folder aplikasi, sama seperti instalasi awal.
find "$APP" -mindepth 1 -maxdepth 1 ! -name storage ! -name _backup ! -name .env -exec chown -R "$(stat -c %U:%G "$APP")" {} +
echo "Menjalankan setup.sh --yes ..."
bash "$APP/setup.sh" --yes
