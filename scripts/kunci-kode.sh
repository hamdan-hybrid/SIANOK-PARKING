#!/usr/bin/env bash
# Kunci kode aplikasi di folder rilis (dipanggil setup.sh / update.sh, bisa juga manual):
#
#   sudo bash scripts/kunci-kode.sh status          kode terkunci? auditd aktif?
#   sudo bash scripts/kunci-kode.sh kunci           kunci file kode (chattr +i) + pasang aturan auditd
#   sudo bash scripts/kunci-kode.sh buka            buka kunci (sebelum update manual; setup.sh menguncinya lagi)
#   sudo bash scripts/kunci-kode.sh log [--semua]   siapa membaca / menyalin / mengubah kode (7 hari terakhir)
#
# Kunci (atribut immutable): file kode tidak bisa diedit, ditimpa, dihapus, atau di-rename oleh siapa pun, root juga,
# sebelum kuncinya dibuka. Folder data tetap bisa ditulis: storage/, public/uploads, public/img, _backup, .env, node_modules.
# auditd mencatat perubahan kode, pembukaan kunci, dan pembacaan/penyalinan kode inti (server.js, start.js,
# laporan-worker.js, views.pak). Tidak memengaruhi kecepatan aplikasi: kunci hanya dicek saat file akan diubah, dan
# yang dicatat hanya akses ke file kode (aplikasi membacanya saat start / ekspor laporan), bukan foto atau database.
# Hanya untuk folder rilis (ada views.pak); folder source tidak dikunci.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP="$HP_APP_ROOT"
KEY_UBAH="$HP_PM2_NAME-kode"
KEY_BACA="$HP_PM2_NAME-baca"
RULES="/etc/audit/rules.d/$HP_PM2_NAME.rules"
INTI=(server.js start.js laporan-worker.js views.pak)
FILE_KODE=("${INTI[@]}" build-info.json database.sql package.json package-lock.json ecosystem.config.cjs setup.sh
  INSTALL.md INSTALL.txt OPERATIONS.md README.md GATE-API.md .env.example)

[ "$(id -u)" -eq 0 ] || { echo "Butuh hak administrator: sudo bash $0 ${*:-status}"; exit 1; }
# Dijalankan manual (bukan dari setup.sh): error dicatat ke log sendiri.
[ "$HP_LOG_FILE" = /dev/null ] && { mkdir -p "$HP_LOG_DIR"; HP_LOG_FILE="$HP_LOG_DIR/kunci-kode.log"; }

# Semua file & folder kode (dipisah \0). public/uploads dan public/img (data) tidak termasuk.
daftar_kode() {
  local f
  for f in "${FILE_KODE[@]}"; do [ -f "$APP/$f" ] && printf '%s\0' "$APP/$f"; done
  find "$APP/public" "$APP/fonts" "$APP/scripts" \( -path "$APP/public/uploads" -o -path "$APP/public/img" \) -prune \
    -o \( -type f -o -type d \) -print0 2>/dev/null
}

hitung() { # → "terkunci total"
  daftar_kode | xargs -0 -r lsattr -d 2>/dev/null | awk '{ t++ } $1 ~ /i/ { n++ } END { printf "%d %d", n, t }'
}

ubah_kunci() { # +i / -i untuk semua kode; ada yang gagal → return 1
  daftar_kode | xargs -0 -r chattr "$1" 2>>"$HP_LOG_FILE"
}

pasang_audit() {
  command -v auditctl >/dev/null && systemctl is-active --quiet auditd || { echo "auditd belum aktif (sudo apt-get install auditd)"; return 1; }
  [[ "$APP" =~ [[:space:]] ]] && { echo "path folder berisi spasi, aturan auditd tidak dipasang"; return 1; }
  local tmp f; tmp="$(mktemp)"
  {
    echo "## $HP_PM2_NAME: catat perubahan & penyalinan kode aplikasi (dipasang scripts/kunci-kode.sh)"
    for f in "${INTI[@]}"; do [ -f "$APP/$f" ] && echo "-w $APP/$f -p r -k $KEY_BACA"; done
    for f in "${FILE_KODE[@]}"; do [ -f "$APP/$f" ] && echo "-w $APP/$f -p wa -k $KEY_UBAH"; done
    for f in public fonts scripts; do [ -d "$APP/$f" ] && echo "-w $APP/$f -p wa -k $KEY_UBAH"; done
    echo "-w /usr/bin/chattr -p x -k $KEY_UBAH"
  } >"$tmp"
  # Dimuat ulang hanya bila aturan berubah / belum termuat (memuat ulang = ganti semua aturan, mengotori log).
  if ! cmp -s "$tmp" "$RULES" 2>/dev/null || ! auditctl -l 2>/dev/null | grep -- "-k $KEY_UBAH" >/dev/null; then
    install -m 640 "$tmp" "$RULES"
    augenrules --load >>"$HP_LOG_FILE" 2>&1
  fi
  rm -f "$tmp"
  auditctl -l 2>/dev/null | grep -- "-k $KEY_UBAH" >/dev/null || { echo "aturan auditd tidak termuat (cek: auditctl -s, mode -e 2 butuh reboot)"; return 1; }
}

case "${1:-status}" in
  kunci)
    [ -f "$APP/views.pak" ] || { echo "Bukan folder rilis (tidak ada views.pak): kode tidak dikunci."; exit 3; }
    if ubah_kunci +i; then read -r n t <<<"$(hitung)"; echo "Kode terkunci: $n dari $t file/folder."
    else echo "Sebagian file tidak bisa dikunci (sistem file tidak mendukung chattr?). Lihat $HP_LOG_FILE"; exit 1; fi
    if msg="$(pasang_audit)"; then echo "Catatan akses (auditd) aktif: kunci $KEY_UBAH, $KEY_BACA."
    else echo "Catatan akses tidak aktif: $msg"; exit 2; fi
    ;;
  buka)
    if ubah_kunci -i; then echo "Kunci kode dibuka. Kunci lagi setelah selesai: sudo bash $APP/scripts/kunci-kode.sh kunci"
    else echo "Sebagian kunci gagal dibuka. Lihat $HP_LOG_FILE"; exit 1; fi
    ;;
  status)
    read -r n t <<<"$(hitung)"
    echo "Folder        : $APP"
    echo "Kode terkunci : $n dari $t file/folder"
    if systemctl is-active --quiet auditd 2>/dev/null && auditctl -l 2>/dev/null | grep -- "-k $KEY_UBAH" >/dev/null; then
      echo "Catatan akses : aktif (log: sudo bash $APP/scripts/kunci-kode.sh log)"
    else echo "Catatan akses : tidak aktif"; fi
    ;;
  log)
    command -v ausearch >/dev/null || { echo "auditd belum terpasang."; exit 1; }
    for key in "$KEY_UBAH" "$KEY_BACA"; do
      echo "== $([ "$key" = "$KEY_UBAH" ] && echo 'Perubahan kode & buka kunci' || echo 'Pembacaan / penyalinan kode inti')"
      # Disembunyikan kecuali --semua: aplikasi sendiri (node) membaca kode saat start / ekspor laporan, dan
      # lsattr/chattr dari skrip ini membuka file saat cek status / kunci (pemakaian chattr tetap tampil di atas).
      # --input-logs: tanpa terminal (cron, ssh tanpa tty) ausearch membaca stdin, bukan file log.
      ausearch --input-logs -k "$key" --start week-ago --format text 2>/dev/null \
        | { if [ "${2:-}" = --semua ]; then cat; else grep -vE '/bin/node$|opened-file .* using /usr/bin/(ls|ch)attr$'; fi; } | tail -n 50
    done
    ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
