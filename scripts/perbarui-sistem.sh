#!/usr/bin/env bash
# Perbarui sistem langsung dari GitHub (tombol "Perbarui sistem" di Monitor Server, atau manual):
#
#   sudo bash scripts/perbarui-sistem.sh            perbarui bila versi di GitHub berbeda
#   sudo bash scripts/perbarui-sistem.sh --paksa    pasang ulang walau versinya sama
#
# setup.sh memasang salinan skrip ini ke /usr/local/sbin/<nama>-perbarui (milik root) dengan nilai di bawah sudah
# terisi, plus aturan sudoers yang hanya mengizinkan file itu tanpa argumen. Aplikasi memanggilnya lewat `sudo -n`.
# Nilai tidak dibaca dari .env, dan semua skrip instalasi dijalankan dari hasil unduhan di folder privat root,
# sehingga user aplikasi tidak bisa membelokkan proses yang berjalan sebagai root.
#
# Alur: unduh (git clone --depth 1) → cek paket rilis → sama dengan yang terpasang: selesai → snapshot kode lama
# → buka kunci kode → salin file (storage/, .env, _backup/, public/uploads, public/img tidak disentuh)
# → setup.sh --yes dari hasil unduhan (dependency, backup + migrasi database, reload PM2, health check, kunci lagi).
# Status untuk aplikasi: /var/lib/<nama>-perbarui/status.json · log: /var/log/<nama>/perbarui-sistem.log
# Snapshot kode lama (2 terakhir): /var/lib/<nama>-perbarui/sebelum-<waktu>.tar.gz
set -uo pipefail

APP='@@APP@@'
NAMA='@@NAMA@@'
REPO='@@REPO@@'
CABANG='@@CABANG@@'

# Seluruh isi di dalam fungsi: bash membaca fungsi utuh sebelum dijalankan, jadi file ini aman ditimpa setup.sh
# (pasang ulang updater) saat sedang berjalan.
main() {
  [ "$(id -u)" -eq 0 ] || { echo "Butuh hak administrator: sudo bash $0"; return 1; }
  local self; self="$(readlink -f "${BASH_SOURCE[0]}")"
  # Dijalankan manual dari folder rilis (nilai belum ditanam setup.sh): ambil dari folder skrip ini.
  if [ "${APP#@@}" != "$APP" ]; then
    APP="$(cd "$(dirname "$self")/.." && pwd)"
    NAMA="$(sed -n "s/^[[:space:]]*name: *'\([a-z0-9-]*\)'.*/\1/p" "$APP/ecosystem.config.cjs" 2>/dev/null | head -n1)"
    REPO="$(sed -n 's#.*"url": *"\(https://github\.com/[^"]*\)".*#\1#p' "$APP/package.json" 2>/dev/null | head -n1)"
    CABANG=main
  fi
  [[ "$NAMA" =~ ^[a-z0-9-]{1,40}$ ]] || { echo "Nama aplikasi tidak valid: $NAMA"; return 1; }
  [[ "$REPO" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Alamat GitHub tidak valid: $REPO"; return 1; }
  [[ "$CABANG" =~ ^[A-Za-z0-9._/-]{1,60}$ ]] || { echo "Cabang tidak valid: $CABANG"; return 1; }
  [ -f "$APP/views.pak" ] || { echo "Bukan folder rilis (tidak ada views.pak): $APP"; return 1; }

  STATE="/var/lib/$NAMA-perbarui"
  LOGDIR="/var/log/$NAMA"
  LOG="$LOGDIR/perbarui-sistem.log"
  mkdir -p "$STATE" "$LOGDIR"; chmod 755 "$STATE"; chmod 750 "$LOGDIR"

  local paksa=0
  case "${1:-}" in --paksa) paksa=1 ;; --jalan) [ "${2:-}" = --paksa ] && paksa=1 ;; "") ;; *) echo "Opsi tidak dikenal: $1"; return 1 ;; esac

  if [ "${1:-}" != --jalan ]; then
    # Tahap 1 (dipanggil aplikasi lewat sudo): cek tidak sedang berjalan, lalu jalankan di unit systemd tersendiri
    # agar tidak ikut berhenti saat PM2 me-reload aplikasi, dan langsung kembali.
    exec 9>"$STATE/kunci"
    flock -n 9 || { echo "Perbarui sistem sedang berjalan."; return 3; }
    exec 9>&-
    MULAI="$(date -Iseconds)"; VERSI_LAMA="$(versi "$APP/build-info.json")"; VERSI_BARU=null
    status antre "Menunggu proses perbarui dimulai..."
    local arg=(--jalan); [ "$paksa" = 1 ] && arg+=(--paksa)
    if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      systemd-run --quiet --collect --unit="$NAMA-perbarui-$(date +%s)" /bin/bash "$self" "${arg[@]}" \
        || { status gagal "systemd-run gagal menjalankan proses perbarui"; return 1; }
    else
      setsid -f /bin/bash "$self" "${arg[@]}" </dev/null >/dev/null 2>&1
    fi
    echo "Perbarui sistem dimulai. Status: $STATE/status.json · log: $LOG"
    return 0
  fi

  # Tahap 2: proses perbarui sebenarnya.
  exec 9>"$STATE/kunci"
  flock -n 9 || return 3
  [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 2097152 ] && mv -f "$LOG" "$LOG.1"
  exec >>"$LOG" 2>&1
  umask 077
  export HOME=/root   # unit systemd tidak mengisi HOME (dipakai git)
  MULAI="$(date -Iseconds)"; SELESAI=0; SRC_ROOT=""
  VERSI_LAMA="$(versi "$APP/build-info.json")"; VERSI_BARU=null
  trap akhir EXIT
  echo "===== $(date '+%F %T') Perbarui sistem $NAMA ($CABANG)$([ "$paksa" = 1 ] && echo ', paksa') ====="

  status unduh "Mengunduh versi terbaru..."
  SRC_ROOT="$(mktemp -d "$STATE/unduh.XXXXXX")"
  local src="$SRC_ROOT/src"
  if command -v git >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$CABANG" "$REPO" "$src" \
      || { gagal "Gagal mengunduh versi terbaru (cek koneksi internet server)"; return 1; }
  else
    # Tanpa git: arsip cabang dari codeload GitHub (isi sama dengan git clone).
    local path="${REPO#https://github.com/}"; path="${path%.git}"
    mkdir "$src" && curl -fsSL --retry 2 --max-time 600 "https://codeload.github.com/$path/tar.gz/refs/heads/$CABANG" \
      | tar -xz -C "$src" --strip-components=1 \
      || { gagal "Gagal mengunduh versi terbaru (cek koneksi internet server)"; return 1; }
  fi
  local f
  for f in views.pak build-info.json server.js start.js setup.sh scripts/lib.sh scripts/kunci-kode.sh ecosystem.config.cjs package.json; do
    [ -f "$src/$f" ] || { gagal "Unduhan bukan paket rilis lengkap ($f tidak ada)"; return 1; }
  done
  local nama_baru; nama_baru="$(sed -n "s/^[[:space:]]*name: *'\([a-z0-9-]*\)'.*/\1/p" "$src/ecosystem.config.cjs" | head -n1)"
  [ "$nama_baru" = "$NAMA" ] || { gagal "Paket pembaruan untuk aplikasi '$nama_baru', bukan '$NAMA'"; return 1; }
  VERSI_BARU="$(versi "$src/build-info.json")"
  if [ "$paksa" != 1 ] && cmp -s "$src/build-info.json" "$APP/build-info.json"; then
    SELESAI=1; status terbaru "Sudah versi terbaru, tidak ada yang diubah."
    return 0
  fi

  status pasang "Memasang file versi baru..."
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  tar -czf "$STATE/sebelum-$stamp.tar.gz" -C "$APP" --exclude=./node_modules --exclude=./storage --exclude=./_backup \
    --exclude=./public/uploads --exclude=./public/img --exclude=./.env . \
    || { gagal "Snapshot kode lama gagal (disk penuh?), tidak ada yang diubah"; rm -f "$STATE/sebelum-$stamp.tar.gz"; return 1; }
  ls -1t "$STATE"/sebelum-*.tar.gz 2>/dev/null | tail -n +3 | xargs -r rm -f
  # Kode yang tidak terkunci sebelumnya (instalasi --tanpa-kunci) tetap tidak dikunci.
  local kunci_opsi=()
  lsattr -d "$APP/server.js" 2>/dev/null | awk '{ exit ($1 ~ /i/) ? 0 : 1 }' || kunci_opsi=(--tanpa-kunci)
  HP_KODE_APP="$APP" bash "$src/scripts/kunci-kode.sh" buka || { gagal "Gagal membuka kunci kode"; return 1; }
  if ! tar -C "$src" --exclude=./.git --exclude=./.gitignore --exclude=./git_upload --exclude=./storage --exclude=./.env \
         --exclude=./_backup --exclude=./public/uploads --exclude=./public/img -cf - . \
       | tar -C "$APP" -xf - --no-same-owner --no-overwrite-dir; then
    [ "${#kunci_opsi[@]}" -eq 0 ] && HP_KODE_APP="$APP" bash "$src/scripts/kunci-kode.sh" kunci >/dev/null
    gagal "Gagal menyalin file. Kembalikan versi lama: tar -xzf $STATE/sebelum-$stamp.tar.gz -C $APP"
    return 1
  fi
  [ -f "$APP/views.pak" ] && rm -rf "$APP/views"
  # File baru (ditulis root) dimiliki pemilik folder aplikasi, sama seperti instalasi awal.
  find "$APP" -mindepth 1 -maxdepth 1 ! -name storage ! -name _backup ! -name .env -exec chown -R "$(stat -c %U:%G "$APP")" {} +

  status setup "Menjalankan setup: dependency, backup & migrasi database, restart aplikasi..."
  bash "$src/setup.sh" --yes --app-dir "$APP" "${kunci_opsi[@]}"
  local rc=$?
  VERSI_BARU="$(versi "$APP/build-info.json")"
  SELESAI=1
  case "$rc" in
    0) status selesai "Sistem berhasil diperbarui." ;;
    2) status selesai "Sistem diperbarui, ada hal yang perlu diperhatikan (lihat log setup)." ;;
    *) status gagal "Setup gagal (kode $rc). Aplikasi mungkin perlu dicek. Versi lama: $STATE/sebelum-$stamp.tar.gz"; return 1 ;;
  esac
  return 0
}

gagal() { SELESAI=1; echo "GAGAL: $*"; status gagal "$*"; }
akhir() {
  local rc=$?
  [ "${SELESAI:-1}" = 0 ] && status gagal "Proses berhenti tidak terduga (kode $rc), lihat log"
  [ -n "${SRC_ROOT:-}" ] && rm -rf "$SRC_ROOT"
  echo "===== $(date '+%F %T') selesai (kode $rc) ====="
}

# {"version":"…","updated_at":"…"} dari build-info.json, null bila tidak ada.
versi() {
  local v t
  v="$(sed -n 's/.*"version": *"\([0-9A-Za-z.+-]*\)".*/\1/p' "$1" 2>/dev/null | head -n1)"
  t="$(sed -n 's/.*"updated_at": *"\([0-9A-Za-z.:+-]*\)".*/\1/p' "$1" 2>/dev/null | head -n1)"
  [ -n "$v$t" ] && printf '{"version":"%s","updated_at":"%s"}' "$v" "$t" || printf 'null'
}

json_str() {
  local s; s="$(printf '%s' "$1" | tr -d '\000-\010\013-\037')"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"
  printf '"%s"' "$s"
}

# Tulis status.json secara atomik (file sementara di folder root lalu rename): dibaca aplikasi (user biasa).
status() {
  local tahap="$1" pesan="$2" baris="" line tmp
  if [ -f "${LOG:-}" ]; then
    # 30 baris terakhir tanpa blok "Perintah:" ringkasan setup (yang berguna untuk Owner: tabel status tiap langkah).
    while IFS= read -r line; do baris+="${baris:+,}$(json_str "$line")"; done < <(tail -n 80 "$LOG" 2>/dev/null | sed '/^  Perintah:/,/^ *$/d' | tail -n 30)
  fi
  tmp="$(mktemp "$STATE/.status.XXXXXX")"
  printf '{"tahap":"%s","pesan":%s,"mulai":"%s","waktu":"%s","versi_lama":%s,"versi_baru":%s,"repo":%s,"log":[%s]}\n' \
    "$tahap" "$(json_str "$pesan")" "$MULAI" "$(date -Iseconds)" "$VERSI_LAMA" "$VERSI_BARU" "$(json_str "$REPO")" "$baris" >"$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$STATE/status.json"
  echo "[$(date '+%T')] $tahap: $pesan"
}

main "$@"; exit $?
