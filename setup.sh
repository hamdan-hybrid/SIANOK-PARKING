#!/usr/bin/env bash
# SIANOK PARKING — AUTOMATIC SETUP (Ubuntu Server 22.04 / 24.04)
#
#   sudo bash setup.sh                 wizard (pertanyaan dengan nilai bawaan)
#   sudo bash setup.sh --yes           tanpa pertanyaan, semua nilai bawaan / dari .env
#
# Opsi: --app-dir DIR  --port N  --https-port N|off  --db-name NAMA  --domain URL  --user USER
#       --db-admin-defaults FILE  (file [client] user/password admin MariaDB bila root tidak bisa lewat socket)
#       --reset-db-password       (izinkan ganti password user database yang sudah ada tetapi tidak tercatat di .env)
#       --izinkan-restart-server  (aturan sudoers agar tombol Restart/Shutdown di Monitor Server aktif)
#       --tanpa-kunci             (file kode tidak dikunci & akses kode tidak dicatat, lihat scripts/kunci-kode.sh)
#       --tanpa-perbarui-web      (tombol "Perbarui sistem" di Monitor Server tidak dipasang)
#
# Update ke versi baru: tombol "Perbarui sistem" di Monitor Server, sudo bash scripts/perbarui-sistem.sh (dari GitHub),
# atau sudo bash scripts/update.sh <paket-rilis.tar.gz>
#
# Aman dijalankan ulang: yang sudah benar dilewati; data, database, dan konfigurasi lama tidak dihapus;
# file yang diubah dibackup dulu. Exit 0 = berhasil, 1 = gagal, 2 = berhasil dengan hal yang perlu diperhatikan.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Installer butuh hak administrator. Menjalankan ulang lewat sudo..."
  exec sudo -E bash "$0" "$@"
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/scripts/lib.sh"

# ---------- Argumen ----------
APP_DIR="$SELF_DIR"; OPT_PORT=""; OPT_HTTPS=""; OPT_DB=""; OPT_DOMAIN=""; OPT_USER=""; ADMIN_DEFAULTS=""
YES=0; RESET_DB_PW=0; POWER_RULE=""; KUNCI=1; KUNCI_DIBUKA=0; PERBARUI=1
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --app-dir) APP_DIR="$2"; shift ;;
    --port) OPT_PORT="$2"; shift ;;
    --https-port) OPT_HTTPS="$2"; shift ;;
    --db-name) OPT_DB="$2"; shift ;;
    --domain) OPT_DOMAIN="$2"; shift ;;
    --user) OPT_USER="$2"; shift ;;
    --db-admin-defaults) ADMIN_DEFAULTS="$2"; shift ;;
    --reset-db-password) RESET_DB_PW=1 ;;
    --izinkan-restart-server) POWER_RULE=yes ;;
    --tanpa-kunci) KUNCI=0 ;;
    --tanpa-perbarui-web) PERBARUI=0 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Opsi tidak dikenal: $1 (lihat --help)"; exit 1 ;;
  esac
  shift
done
APP_DIR="$(cd "$APP_DIR" 2>/dev/null && pwd)" || { echo "Folder aplikasi tidak ditemukan"; exit 1; }
ENV_FILE="$APP_DIR/.env"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$HP_LOG_DIR"; chmod 750 "$HP_LOG_DIR"
HP_LOG_FILE="$HP_LOG_DIR/setup-$STAMP.log"; : >"$HP_LOG_FILE"; chmod 600 "$HP_LOG_FILE"
export HP_LOG_FILE

INTERACTIVE=0; [ "$YES" -eq 0 ] && [ -r /dev/tty ] && INTERACTIVE=1
# Tanya dengan nilai bawaan (mode --yes / tanpa terminal: langsung nilai bawaan).
ask() {
  local prompt="$1" def="$2" answer
  if [ "$INTERACTIVE" -eq 1 ]; then
    read -r -p "      $prompt [$def]: " answer </dev/tty || answer=""
    printf '%s' "${answer:-$def}"
  else printf '%s' "$def"; fi
}
confirm() { # confirm "pertanyaan" y|n
  local a; a="$(ask "$1 (y/n)" "$2")"; [[ "$a" =~ ^[YyJj] ]]
}
abort() { err "$*"; summary; exit 1; }

printf '\n%s══════════════════════════════════════════════════%s\n' "$C_B" "$C_0"
printf '%s  SIANOK PARKING — AUTOMATIC SETUP%s\n' "$C_B" "$C_0"
printf '%s══════════════════════════════════════════════════%s\n' "$C_B" "$C_0"
printf '  %sLog: %s%s\n' "$C_DIM" "$HP_LOG_FILE" "$C_0"

summary() {
  local i failed=0 attention=0
  # Instalasi berhenti setelah kunci kode dibuka sementara: kunci lagi.
  if [ "$KUNCI_DIBUKA" = 1 ]; then HP_KODE_APP="$APP_DIR" bash "$SELF_DIR/scripts/kunci-kode.sh" kunci >>"$HP_LOG_FILE" 2>&1; KUNCI_DIBUKA=0; fi
  printf '\n%s══════════════════ RINGKASAN ══════════════════%s\n' "$C_B" "$C_0"
  for i in "${!HP_STEPS[@]}"; do
    case "${HP_STATUS[$i]}" in FAILED) failed=1 ;; "NEEDS ATTENTION") attention=1 ;; esac
    printf '  %-26s %s\n' "${HP_STEPS[$i]}" "${HP_STATUS[$i]}"
  done
  printf '\n'
  printf '  %-22s %s\n' "Ubuntu" "${PRETTY_NAME:-?}" "Node.js" "${NODE_VERSION:--}" "npm" "${NPM_VERSION:--}" "PM2" "${PM2_VERSION:--}" \
    "MariaDB" "${DB_SERVER_VERSION:--}" "FFmpeg" "${FFMPEG_VERSION:--}" "FFprobe" "${FFPROBE_VERSION:--}" \
    "Folder aplikasi" "$APP_DIR" "User layanan" "${APP_USER:--}" "Port aplikasi" "${APP_PORT:--}${HTTPS_PORT:+ (HTTPS ${HTTPS_PORT})}" \
    "Database" "${DB_NAME:--}" "User database" "${DB_USER:--}" "Koneksi database" "${DB_CONN_STATUS:-belum diuji}" \
    "Proses PM2" "${PM2_STATUS:--}" "Health check" "${HEALTH_STATUS:-belum dijalankan}" \
    "Konfigurasi" "$ENV_FILE (600)" "Log aplikasi" "${APP_LOG_DIR:--}" "Log installer" "$HP_LOG_FILE"
  if [ -n "${APP_USER:-}" ]; then
    printf '\n  Perintah:\n'
    printf '    Status   : sudo -u %s pm2 status %s\n' "$APP_USER" "$HP_PM2_NAME"
    printf '    Restart  : sudo -u %s pm2 reload %s\n' "$APP_USER" "$HP_PM2_NAME"
    printf '    Log      : sudo -u %s pm2 logs %s\n' "$APP_USER" "$HP_PM2_NAME"
    printf '    Cek      : sudo bash %s/scripts/health-check.sh\n' "$APP_DIR"
    printf '    Backup   : sudo bash %s/scripts/backup-database.sh\n' "$APP_DIR"
    printf '    Kunci    : sudo bash %s/scripts/kunci-kode.sh status | log\n' "$APP_DIR"
    printf '    Perbarui : sudo bash %s/scripts/perbarui-sistem.sh   (dari GitHub; atau tombol di Monitor Server)\n' "$APP_DIR"
    printf '    Update   : sudo bash %s/scripts/update.sh <paket-rilis.tar.gz>\n' "$APP_DIR"
  fi
  if [ "$failed" -eq 1 ] || [ "$attention" -eq 1 ]; then
    printf '\n  %sPerlu tindakan:%s\n' "$C_WARN" "$C_0"
    for i in "${!HP_STEPS[@]}"; do
      case "${HP_STATUS[$i]}" in FAILED|"NEEDS ATTENTION") printf '    - %s: %s\n' "${HP_STEPS[$i]}" "${HP_NOTES[$i]}" ;; esac
    done
  fi
  if [ "$failed" -eq 1 ]; then printf '\n  %sINSTALASI GAGAL%s. Perbaiki hal di atas lalu jalankan ulang: sudo bash %s/setup.sh\n\n' "$C_FAIL$C_B" "$C_0" "$APP_DIR"
  elif [ "${HEALTH_STATUS:-}" = LULUS ]; then
    printf '\n  %sINSTALASI BERHASIL%s%s\n' "$C_OK$C_B" "$C_0" "$([ "$attention" -eq 1 ] && echo ' (ada yang perlu diperhatikan)')"
    printf '  Akses: %s\n' "${ACCESS_URLS:-}"
    [ "${FRESH_DB:-0}" = 1 ] && printf '  Login awal: admin / admin123 → segera ganti password di menu Pengguna.\n'
    printf '\n'
  fi
}

# ===================================================================================
step_begin "Administrator"
step_end SUCCESS "root${SUDO_USER:+ (sudo oleh $SUDO_USER)}"

# ---------- 1. Pemeriksaan awal ----------
step_begin "Pemeriksaan server"
. /etc/os-release 2>/dev/null || true
bash "$SELF_DIR/scripts/check-dependencies.sh" "$APP_DIR"; rc=$?
[ "$rc" -ne 0 ] && { step_end FAILED "server / folder tidak didukung (lihat baris GAGAL di atas)"; summary; exit 1; }
step_end SUCCESS "${PRETTY_NAME:-Ubuntu} $(uname -m)"
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) confirm "Versi Ubuntu ini belum diuji. Lanjutkan?" n || abort "Dibatalkan." ;; esac

# ---------- 2. Input ----------
step_begin "Konfigurasi"
OLD_PORT="$(env_get "$ENV_FILE" PORT)"; OLD_HTTPS="$(env_get "$ENV_FILE" HTTPS_PORT)"
OLD_DB="$(env_get "$ENV_FILE" DB_NAME)"; OLD_SITE="$(env_get "$ENV_FILE" SITE_URL)"
owner="$(stat -c %U "$APP_DIR")"
if [ -n "$OPT_USER" ]; then def_user="$OPT_USER"
elif [ "$owner" != root ]; then def_user="$owner"
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then def_user="$SUDO_USER"
else def_user="hybrid"; fi
APP_USER="$(ask "User layanan (non-root) yang menjalankan aplikasi" "$def_user")"
APP_PORT="$(ask "Port aplikasi (HTTP)" "${OPT_PORT:-${OLD_PORT:-3003}}")"
HTTPS_PORT="$(ask "Port HTTPS bawaan aplikasi (off = tanpa HTTPS sendiri)" "${OPT_HTTPS:-${OLD_HTTPS:-3446}}")"
DB_NAME="$(ask "Nama database" "${OPT_DB:-${OLD_DB:-db-sianok-parking}}")"
SITE_URL="$(ask "Alamat publik (kosongkan bila hanya jaringan lokal), mis. https://parkir.domain.com" "${OPT_DOMAIN:-${OLD_SITE:-}}")"
[ "$APP_USER" = root ] && abort "Aplikasi tidak boleh dijalankan sebagai root."
[[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || abort "Nama user tidak valid: $APP_USER"
[[ "$APP_PORT" =~ ^[0-9]{2,5}$ ]] && [ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ] || abort "Port tidak valid: $APP_PORT"
[[ "${HTTPS_PORT,,}" = off ]] && HTTPS_PORT=off
[ "$HTTPS_PORT" = off ] || { [[ "$HTTPS_PORT" =~ ^[0-9]{2,5}$ ]] && [ "$HTTPS_PORT" -le 65535 ] && [ "$HTTPS_PORT" != "$APP_PORT" ]; } || abort "Port HTTPS tidak valid: $HTTPS_PORT"
[[ "$DB_NAME" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || abort "Nama database hanya huruf, angka, _ dan - (maks 64)"
# Database sistem MariaDB tidak boleh dipakai: user aplikasi akan mendapat hak penuh atasnya (GRANT ALL di bawah).
case "${DB_NAME,,}" in mysql|information_schema|performance_schema|sys) abort "Nama database '$DB_NAME' adalah database sistem MariaDB" ;; esac
[ -z "$SITE_URL" ] || [[ "$SITE_URL" =~ ^https?://[^[:space:]\"\'\`]+$ ]] || abort "Alamat publik harus diawali http:// atau https://"
SITE_URL="${SITE_URL%/}"
if [ -n "$OLD_PORT" ] && [ "$APP_PORT" != "$OLD_PORT" ] && ! confirm "Port di .env ($OLD_PORT) akan diganti $APP_PORT. Lanjutkan?" n; then APP_PORT="$OLD_PORT"; fi
step_end SUCCESS "user $APP_USER, port $APP_PORT, HTTPS $HTTPS_PORT, database $DB_NAME"

# ---------- 3. Library sistem (APT) ----------
step_begin "System Libraries"
# Daftar dari kebutuhan nyata kode: ffmpeg (gate.js, foto kamera), mariadb-client (backup Monitor Server),
# openssl (sertifikat HTTPS sendiri), iproute2/procps (cek port & proses), curl/xz-utils/ca-certificates (unduh Node.js),
# libatomic1 (dibutuhkan biner resmi Node.js 26; tidak ada di image Ubuntu Server minimal).
# Tidak perlu build-essential/python: modul native (@napi-rs/canvas, esbuild) berupa biner jadi.
PKGS=(ca-certificates curl xz-utils openssl iproute2 procps libatomic1 ffmpeg)
# chattr (e2fsprogs) & auditd: kunci kode + catatan akses kode (langkah terakhir).
[ "$KUNCI" -eq 1 ] && PKGS+=(e2fsprogs auditd)
DB_SERVER_PRESENT=0
if dpkg-query -W -f='${Status}' mariadb-server 2>/dev/null | grep 'install ok installed' >/dev/null \
   || dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep 'install ok installed' >/dev/null \
   || [ -x /usr/sbin/mariadbd ] || [ -x /usr/sbin/mysqld ]; then DB_SERVER_PRESENT=1
else PKGS+=(mariadb-server); fi
# Penanda: MariaDB dipasang oleh installer ini → pengamanan dasar dijalankan (sekali), walau run pertama terputus.
mkdir -p "$HP_STATE_DIR"; chmod 700 "$HP_STATE_DIR"
[ "$DB_SERVER_PRESENT" -eq 0 ] && touch "$HP_STATE_DIR/mariadb-dipasang-installer"
if ! command -v mariadb >/dev/null && ! command -v mysql >/dev/null; then PKGS+=(mariadb-client); fi
if ! command -v mariadb-dump >/dev/null && ! command -v mysqldump >/dev/null; then PKGS+=(mariadb-client); fi
MISSING=()
for p in $(printf '%s\n' "${PKGS[@]}" | sort -u); do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep 'install ok installed' >/dev/null || MISSING+=("$p")
done
if [ "${#MISSING[@]}" -eq 0 ]; then step_end SKIPPED "semua paket sudah ada"
else
  info "Memasang: ${MISSING[*]}"
  export DEBIAN_FRONTEND=noninteractive
  if run_logged apt-get update && run_logged apt-get install -y --no-install-recommends "${MISSING[@]}"; then
    step_end SUCCESS "dipasang: ${MISSING[*]}"
  else
    step_end FAILED "apt-get install gagal (lihat log; cek internet / repository)"; summary; exit 1
  fi
fi

# ---------- 4. User layanan ----------
step_begin "User layanan"
if id "$APP_USER" >/dev/null 2>&1; then
  step_end SKIPPED "$APP_USER sudah ada"
else
  run_logged useradd --system --create-home --home-dir "/var/lib/$APP_USER" --shell /usr/sbin/nologin "$APP_USER" \
    && step_end SUCCESS "user sistem $APP_USER dibuat (home /var/lib/$APP_USER, tanpa login shell)" \
    || { step_end FAILED "useradd gagal"; summary; exit 1; }
fi
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
[ -d "$APP_HOME" ] || { mkdir -p "$APP_HOME"; chown "$APP_USER:" "$APP_HOME"; }

# ---------- 5. Node.js & npm ----------
step_begin "Node.js"
ARCH="$(uname -m)"; case "$ARCH" in x86_64) NARCH=x64 ;; aarch64) NARCH=arm64 ;; esac
OWN_DIR="$HP_NODE_ROOT/node-v$HP_REQUIRED_NODE-linux-$NARCH"
SYS_NODE="$(command -v node || true)"
SYS_NODE_V="$([ -n "$SYS_NODE" ] && "$SYS_NODE" -v 2>/dev/null || true)"
if [ -n "$SYS_NODE_V" ] && version_ge "$SYS_NODE_V" "$HP_REQUIRED_NODE"; then
  HP_NODE_BIN="$(readlink -f "$SYS_NODE")"
  step_end SKIPPED "$SYS_NODE_V sudah memenuhi (>= $HP_REQUIRED_NODE)"
else
  if [ ! -x "$OWN_DIR/bin/node" ]; then
    info "Mengunduh Node.js v$HP_REQUIRED_NODE ($NARCH) dari nodejs.org dan memverifikasi SHA-256..."
    TMPN="$(mktemp -d)"
    tarball="node-v$HP_REQUIRED_NODE-linux-$NARCH.tar.xz"
    if run_logged curl -fsSL --retry 3 -o "$TMPN/$tarball" "https://nodejs.org/dist/v$HP_REQUIRED_NODE/$tarball" \
       && run_logged curl -fsSL --retry 3 -o "$TMPN/SHASUMS256.txt" "https://nodejs.org/dist/v$HP_REQUIRED_NODE/SHASUMS256.txt" \
       && (cd "$TMPN" && grep " $tarball\$" SHASUMS256.txt | sha256sum -c - >>"$HP_LOG_FILE" 2>&1); then
      mkdir -p "$HP_NODE_ROOT" && run_logged tar -xJf "$TMPN/$tarball" -C "$HP_NODE_ROOT" && chown -R root:root "$OWN_DIR"
    fi
    rm -rf "$TMPN"
  fi
  if [ -x "$OWN_DIR/bin/node" ] && "$OWN_DIR/bin/node" -v >>"$HP_LOG_FILE" 2>&1; then
    HP_NODE_BIN="$OWN_DIR/bin/node"
    # Symlink global hanya bila server belum punya node, atau node global adalah milik installer ini (versi lama).
    if [ -z "$SYS_NODE" ] || [[ "$(readlink -f "$SYS_NODE")" == "$HP_NODE_ROOT"/* ]]; then
      for b in node npm npx; do ln -sfn "$OWN_DIR/bin/$b" "/usr/local/bin/$b"; done
      step_end SUCCESS "Node.js v$HP_REQUIRED_NODE dipasang ($OWN_DIR, /usr/local/bin/node)"
    else
      step_end "NEEDS ATTENTION" "node global $SYS_NODE_V ($SYS_NODE) dibiarkan untuk aplikasi lain; Sianok Parking memakai $HP_NODE_BIN"
    fi
  else
    step_end FAILED "Node.js v$HP_REQUIRED_NODE gagal diunduh / diverifikasi / dijalankan (lihat log)"; summary; exit 1
  fi
fi
HP_NODE_BIN_DIR="$(dirname "$HP_NODE_BIN")"; export HP_NODE_BIN HP_NODE_BIN_DIR
export PATH="$HP_NODE_BIN_DIR:$PATH"
NODE_VERSION="$(as_user "$APP_USER" node -v 2>/dev/null)"; NPM_VERSION="$(as_user "$APP_USER" npm -v 2>/dev/null)"
step_begin "npm"
[ -n "$NODE_VERSION" ] && [ -n "$NPM_VERSION" ] && step_end SUCCESS "node $NODE_VERSION, npm $NPM_VERSION (dijalankan sebagai $APP_USER)" \
  || { step_end FAILED "node / npm tidak bisa dijalankan user $APP_USER"; summary; exit 1; }

# ---------- 6. PM2 ----------
step_begin "PM2"
PM2_BIN="$(command -v pm2 || true)"
if [ -n "$PM2_BIN" ] && as_user "$APP_USER" pm2 -v >/dev/null 2>&1; then
  PM2_VERSION="$(as_user "$APP_USER" pm2 -v 2>/dev/null | tail -n1)"
  step_end SKIPPED "PM2 $PM2_VERSION sudah ada ($PM2_BIN)"
elif run_logged "$HP_NODE_BIN_DIR/npm" install -g pm2@latest --no-audit --no-fund; then
  PM2_BIN="$HP_NODE_BIN_DIR/pm2"
  PM2_VERSION="$(as_user "$APP_USER" pm2 -v 2>/dev/null | tail -n1)"
  step_end SUCCESS "PM2 $PM2_VERSION dipasang"
else
  step_end FAILED "npm install -g pm2 gagal (lihat log)"; summary; exit 1
fi
# Perintah `pm2` harus bisa dipakai dari terminal biasa (PATH sistem). Bila PM2 hanya ada di folder Node.js khusus,
# /usr/local/bin/pm2 dibuat sebagai pembungkus yang menjalankan PM2 dengan Node.js itu (node lama di server tidak dipakai).
SYS_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if ! PATH="$SYS_PATH" command -v pm2 >/dev/null && [ -f "$HP_NODE_BIN_DIR/../lib/node_modules/pm2/bin/pm2" ]; then
  printf '#!/bin/sh\n# Dibuat setup.sh Sianok Parking: PM2 dengan Node.js %s.\nexec "%s" "%s" "$@"\n' "$HP_REQUIRED_NODE" \
    "$HP_NODE_BIN" "$(readlink -f "$HP_NODE_BIN_DIR/../lib/node_modules/pm2/bin/pm2")" >/usr/local/bin/pm2
  chmod 755 /usr/local/bin/pm2
  info "Perintah pm2 tersedia di /usr/local/bin/pm2"
fi

# ---------- 7. MariaDB ----------
step_begin "MariaDB"
DB_UNIT=""
for unit in mariadb mysql; do systemctl cat "$unit.service" >/dev/null 2>&1 && { DB_UNIT="$unit"; break; }; done
[ -n "$DB_UNIT" ] || { step_end FAILED "layanan MariaDB tidak ditemukan setelah instalasi"; summary; exit 1; }
run_logged systemctl enable "$DB_UNIT"
systemctl is-active --quiet "$DB_UNIT" || run_logged systemctl start "$DB_UNIT"
for i in $(seq 1 30); do systemctl is-active --quiet "$DB_UNIT" && break; sleep 1; done
systemctl is-active --quiet "$DB_UNIT" || { step_end FAILED "layanan $DB_UNIT tidak bisa start (journalctl -u $DB_UNIT)"; summary; exit 1; }
MYSQL="$(mariadb_bin)"
# Akses admin: root lewat unix socket (bawaan Ubuntu), atau file kredensial admin dari --db-admin-defaults / wizard.
ADMIN=("$MYSQL" --protocol=socket -uroot)
if ! "${ADMIN[@]}" -N -e 'SELECT 1' >/dev/null 2>&1; then
  if [ -z "$ADMIN_DEFAULTS" ] && [ "$INTERACTIVE" -eq 1 ]; then
    warn "root MariaDB tidak bisa masuk lewat socket. Masukkan akun admin MariaDB (tidak disimpan)."
    read -r -p "      User admin MariaDB [root]: " au </dev/tty; au="${au:-root}"
    read -r -s -p "      Password $au: " ap </dev/tty; echo
    ADMIN_DEFAULTS="$(db_defaults_file localhost 3306 "$au" "$ap")"; unset ap
  fi
  [ -n "$ADMIN_DEFAULTS" ] && ADMIN=("$MYSQL" --defaults-extra-file="$ADMIN_DEFAULTS")
  "${ADMIN[@]}" -N -e 'SELECT 1' >/dev/null 2>&1 || { step_end FAILED "tidak ada akses admin MariaDB (pakai --db-admin-defaults FILE)"; summary; exit 1; }
fi
sql_admin() { "${ADMIN[@]}" -N -B "$@"; }
DB_SERVER_VERSION="$(sql_admin -e 'SELECT VERSION()' 2>/dev/null)"
if [ -f "$HP_STATE_DIR/mariadb-dipasang-installer" ] && [ ! -f "$HP_STATE_DIR/mariadb-diamankan" ]; then
  # Dipasang oleh installer ini: pengamanan dasar (user anonim & database test dihapus). Server lama tidak disentuh.
  for u in $(sql_admin -e "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.user WHERE User=''" 2>/dev/null); do sql_admin -e "DROP USER $u" >>"$HP_LOG_FILE" 2>&1; done
  sql_admin -e "DROP DATABASE IF EXISTS test" >>"$HP_LOG_FILE" 2>&1
  touch "$HP_STATE_DIR/mariadb-diamankan"
  note="dipasang installer & diamankan"
elif [ -f "$HP_STATE_DIR/mariadb-diamankan" ]; then note="dipasang installer, sudah diamankan"
else note="sudah ada, konfigurasi tidak diubah"; fi
bind_all="$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):3306$' || true)"
if [ -n "$bind_all" ]; then step_end "NEEDS ATTENTION" "$DB_SERVER_VERSION ($note), tetapi mendengarkan di semua alamat :3306 — pastikan firewall menutup port ini dari internet"
else step_end SUCCESS "$DB_SERVER_VERSION ($note), aktif & otomatis start, hanya lokal"; fi

# ---------- 8. Port (sebelum ada perubahan database) ----------
step_begin "Port"
own_pids=""
if as_user "$APP_USER" pm2 pid "$HP_PM2_NAME" 2>/dev/null | grep '[1-9]' >/dev/null; then
  # Proses Sianok Parking yang sedang jalan + daemon PM2 user ini (mode cluster: daemon yang memegang socket port).
  own_pids="$(as_user "$APP_USER" pm2 pid "$HP_PM2_NAME" 2>/dev/null | tr -d ' '; cat "$APP_HOME/.pm2/pm2.pid" 2>/dev/null)"
fi
port_free_for_us() { # port → 0 bila kosong atau dipakai proses Sianok Parking ini
  local pids p; pids="$(port_pids "$1")"; [ -z "$pids" ] && ! port_in_use "$1" && return 0
  for p in $pids; do [ -n "$own_pids" ] && printf '%s\n' "$own_pids" | grep -x "$p" >/dev/null && return 0; done
  return 1
}
port_note=""
while ! port_free_for_us "$APP_PORT"; do
  warn "Port $APP_PORT sedang dipakai: $(port_user "$APP_PORT") (proses itu tidak dihentikan)"
  [ "$INTERACTIVE" -eq 1 ] || { step_end FAILED "port $APP_PORT dipakai aplikasi lain; pilih port lain dengan --port"; summary; exit 1; }
  APP_PORT="$(ask "Pilih port lain" "$((APP_PORT + 1))")"; port_note=" (diganti)"
done
if [ "$HTTPS_PORT" != off ]; then
  while ! port_free_for_us "$HTTPS_PORT"; do
    warn "Port HTTPS $HTTPS_PORT sedang dipakai: $(port_user "$HTTPS_PORT")"
    [ "$INTERACTIVE" -eq 1 ] || { step_end FAILED "port HTTPS $HTTPS_PORT dipakai; pakai --https-port N atau off"; summary; exit 1; }
    HTTPS_PORT="$(ask "Port HTTPS lain (atau off)" off)"; [ "$HTTPS_PORT" = off ] && break
  done
fi
step_end SUCCESS "HTTP $APP_PORT$port_note, HTTPS $HTTPS_PORT"

# ---------- 9. Database & user ----------
step_begin "Database User"
OLD_USER="$(env_get "$ENV_FILE" DB_USER)"; OLD_PW="$(env_get "$ENV_FILE" DB_PASSWORD)"
OLD_HOST="$(env_get "$ENV_FILE" DB_HOST)"; OLD_DBPORT="$(env_get "$ENV_FILE" DB_PORT)"
DB_HOST="${OLD_HOST:-127.0.0.1}"; DB_PORT="${OLD_DBPORT:-3306}"
DB_USER="${OLD_USER:-sianok_parking}"
ENV_BACKUP=""
env_backup_once() { # backup .env lama (sekali per run) sebelum perubahan pertama; .env baru dibuat bila belum ada
  [ -n "$ENV_BACKUP" ] && return 0
  if [ -f "$ENV_FILE" ]; then
    mkdir -p "$APP_DIR/_backup"; chmod 700 "$APP_DIR/_backup"
    ENV_BACKUP="_backup/.env.bak-$STAMP"; cp -p "$ENV_FILE" "$APP_DIR/$ENV_BACKUP"; chmod 600 "$APP_DIR/$ENV_BACKUP"
  else
    printf '# Dibuat oleh setup.sh Sianok Parking (%s).\n' "$STAMP" >"$ENV_FILE"; chmod 600 "$ENV_FILE"; ENV_BACKUP="(baru)"
  fi
}
db_esc_name() { printf '%s' "$1" | sed 's/[\\_%]/\\&/g'; }   # nama database untuk GRANT (_ dan % adalah wildcard)
app_can_connect() { # user password → 0 bila bisa login & memakai database
  local f; f="$(db_defaults_file "$DB_HOST" "$DB_PORT" "$1" "$2")"
  "$MYSQL" --defaults-extra-file="$f" -N -e "SELECT 1" "$DB_NAME" >/dev/null 2>&1
}
sql_admin -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" \
  || { step_end FAILED "CREATE DATABASE $DB_NAME gagal"; summary; exit 1; }
EXISTING_TABLES="$(sql_admin -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME'")"
[[ "$DB_USER" =~ ^[A-Za-z0-9_.-]{1,80}$ ]] || { step_end FAILED "DB_USER di .env tidak valid: $DB_USER"; summary; exit 1; }
if [ -n "$OLD_USER" ] && app_can_connect "$OLD_USER" "$OLD_PW"; then
  if [ "$OLD_USER" = root ]; then
    DB_NOTE="kredensial .env valid tetapi memakai root"
    if confirm "Aplikasi memakai user root MariaDB. Buat user khusus 'sianok_parking' dan pakai di .env?" n; then DB_USER=sianok_parking; OLD_USER=""; fi
  else DB_NOTE="kredensial .env valid, dipakai ulang"; fi
fi
if [ -n "$OLD_USER" ] && [ "$DB_USER" = "$OLD_USER" ] && app_can_connect "$OLD_USER" "$OLD_PW"; then
  DB_PASSWORD="$OLD_PW"
  [ "$OLD_USER" = root ] && step_end "NEEDS ATTENTION" "$DB_NOTE (disarankan user khusus dengan hak hanya pada $DB_NAME)" || step_end SKIPPED "$DB_NOTE ($DB_USER)"
else
  exists="$(sql_admin -e "SELECT COUNT(*) FROM mysql.user WHERE User='$DB_USER'")"
  if [ "$exists" != 0 ] && [ "$RESET_DB_PW" -ne 1 ] && ! confirm "User database '$DB_USER' sudah ada tetapi passwordnya tidak ada di .env. Ganti passwordnya?" n; then
    step_end FAILED "user '$DB_USER' sudah ada, password tidak diketahui (jalankan dengan --reset-db-password bila user ini memang milik Sianok Parking)"; summary; exit 1
  fi
  DB_PASSWORD="$(random_hex 24)"
  # User hanya untuk koneksi lokal; hak penuh hanya pada database Sianok Parking (tabel, trigger, migrasi, backup).
  if printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED BY '%s';
CREATE USER IF NOT EXISTS '%s'@'127.0.0.1' IDENTIFIED BY '%s';
ALTER USER '%s'@'localhost' IDENTIFIED BY '%s';
ALTER USER '%s'@'127.0.0.1' IDENTIFIED BY '%s';
GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'localhost';
GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'127.0.0.1';
FLUSH PRIVILEGES;\n" "$DB_USER" "$DB_PASSWORD" "$DB_USER" "$DB_PASSWORD" "$DB_USER" "$DB_PASSWORD" "$DB_USER" "$DB_PASSWORD" \
      "$(db_esc_name "$DB_NAME")" "$DB_USER" "$(db_esc_name "$DB_NAME")" "$DB_USER" | sql_admin 2>>"$HP_LOG_FILE" \
     && app_can_connect "$DB_USER" "$DB_PASSWORD"; then
    # Langsung dicatat di .env agar password tidak hilang walau tahap berikutnya gagal.
    env_backup_once
    for kv in "DB_HOST=$DB_HOST" "DB_PORT=$DB_PORT" "DB_NAME=$DB_NAME" "DB_USER=$DB_USER" "DB_PASSWORD=$DB_PASSWORD"; do env_set "$ENV_FILE" "${kv%%=*}" "${kv#*=}"; done
    chmod 600 "$ENV_FILE"
    [ "$exists" != 0 ] && step_end SUCCESS "password user '$DB_USER' diganti (acak 48 karakter), hak pada $DB_NAME" \
      || step_end SUCCESS "user '$DB_USER'@localhost dibuat, password acak 48 karakter, hak hanya pada $DB_NAME"
  else
    step_end FAILED "membuat / menguji user database gagal (lihat log)"; summary; exit 1
  fi
fi
DB_CONN_STATUS="OK ($DB_USER@$DB_HOST:$DB_PORT/$DB_NAME)"

# ---------- 10. File .env ----------
step_begin "Environment (.env)"
set_if() { # key value → tulis bila beda (backup .env dulu sebelum perubahan pertama)
  local cur; cur="$(env_get "$ENV_FILE" "$1")"
  if [ ! -f "$ENV_FILE" ] || ! grep -qE "^[[:space:]]*$1=" "$ENV_FILE" || [ "$cur" != "$2" ]; then env_backup_once; env_set "$ENV_FILE" "$1" "$2"; CHANGED+=("$1"); fi
}
CHANGED=()
set_if DB_HOST "$DB_HOST"; set_if DB_PORT "$DB_PORT"; set_if DB_NAME "$DB_NAME"; set_if DB_USER "$DB_USER"; set_if DB_PASSWORD "$DB_PASSWORD"
[ -n "$(env_get "$ENV_FILE" USER_ID_SECRET)" ] || { env_backup_once; env_set "$ENV_FILE" USER_ID_SECRET "$(random_hex 32)"; CHANGED+=(USER_ID_SECRET); }
set_if PORT "$APP_PORT"
{ [ "$HTTPS_PORT" != 3446 ] || grep -E '^[[:space:]]*HTTPS_PORT=' >/dev/null "$ENV_FILE"; } && set_if HTTPS_PORT "$HTTPS_PORT"
{ [ -n "$SITE_URL" ] || grep -E '^[[:space:]]*SITE_URL=' >/dev/null "$ENV_FILE"; } && set_if SITE_URL "$SITE_URL"
chown "$APP_USER:" "$ENV_FILE"; chmod 600 "$ENV_FILE"
case "$ENV_BACKUP" in "") env_note="tidak diubah" ;; "(baru)") env_note="dibuat baru" ;; *) env_note="dibackup ke $ENV_BACKUP" ;; esac
if [ -z "$ENV_BACKUP" ]; then step_end SKIPPED ".env sudah sesuai (tidak diubah)"
else step_end SUCCESS "$env_note; diisi/diperbarui: ${CHANGED[*]:-DB_*} (nilai rahasia tidak ditampilkan)"; fi

# ---------- 11. Folder & permission ----------
# Kode terkunci dari instalasi sebelumnya: dibuka sementara (chown/mkdir di bawah), dikunci lagi di langkah terakhir.
if lsattr -d "$APP_DIR/server.js" 2>/dev/null | cut -d' ' -f1 | grep i >/dev/null; then
  run_logged env HP_KODE_APP="$APP_DIR" bash "$SELF_DIR/scripts/kunci-kode.sh" buka && KUNCI_DIBUKA=1
fi
step_begin "Folder data"
dir_owner="$(stat -c %U "$APP_DIR")"
if [ "$dir_owner" != "$APP_USER" ]; then
  if [ "$dir_owner" = root ] || confirm "Folder aplikasi milik '$dir_owner'. Ubah pemilik ke '$APP_USER'?" n; then
    run_logged chown -R "$APP_USER:" "$APP_DIR"; owner_note="pemilik folder → $APP_USER"
  else step_end FAILED "folder aplikasi milik $dir_owner, bukan $APP_USER"; summary; exit 1; fi
fi
for d in storage storage/parkir storage/pengeluaran public/uploads public/img _backup; do
  [ -d "$APP_DIR/$d" ] || { mkdir -p "$APP_DIR/$d"; chown "$APP_USER:" "$APP_DIR/$d"; }
done
chown -R "$APP_USER:" "$APP_DIR/_backup" "$APP_DIR/.env"
# chmod mengikuti symlink: lewati bila folder data berupa symlink (mis. storage dipindah ke disk lain) agar root tidak
# mengubah izin folder lain yang ditunjuk symlink buatan user aplikasi.
[ -L "$APP_DIR/storage" ] || chmod 750 "$APP_DIR/storage"; [ -L "$APP_DIR/_backup" ] || chmod 700 "$APP_DIR/_backup"
files="$(find "$APP_DIR/storage" -type f 2>/dev/null | wc -l)"
step_end SUCCESS "${owner_note:+$owner_note; }storage ($files file foto/data, tidak dipindah), public/uploads, public/img, _backup; sisa disk $(df -Ph "$APP_DIR" | awk 'NR==2 {print $4}')"

# ---------- 12. FFmpeg & FFprobe ----------
step_begin "FFmpeg / FFprobe"
FFMPEG_VERSION="$(as_user "$APP_USER" ffmpeg -version 2>/dev/null | head -n1 | awk '{print $3}')"
FFPROBE_VERSION="$(as_user "$APP_USER" ffprobe -version 2>/dev/null | head -n1 | awk '{print $3}')"
TMPF="$(mktemp -d /tmp/hp-ffmpeg.XXXXXX)"; chmod 777 "$TMPF"
if [ -n "$FFMPEG_VERSION" ] && [ -n "$FFPROBE_VERSION" ] \
   && as_user "$APP_USER" ffmpeg -hide_banner -demuxers 2>/dev/null | grep -w rtsp >/dev/null \
   && as_user "$APP_USER" ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=1 -frames:v 1 -q:v 4 -y "$TMPF/t.jpg" \
   && [ "$(as_user "$APP_USER" ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$TMPF/t.jpg")" = mjpeg ]; then
  step_end SUCCESS "ffmpeg $FFMPEG_VERSION, ffprobe $FFPROBE_VERSION; RTSP + snapshot JPEG diuji sebagai $APP_USER"
else
  step_end FAILED "ffmpeg/ffprobe tidak berfungsi (foto kamera gate butuh ffmpeg)"; rm -rf "$TMPF"; summary; exit 1
fi
rm -rf "$TMPF"

# ---------- 13. Dependency aplikasi ----------
step_begin "Application Dependencies"
native_ok() {
  (cd "$APP_DIR" && as_user "$APP_USER" node --input-type=module -e "
    const c = await import('@napi-rs/canvas'); c.createCanvas(8, 8).toBuffer('image/png');
    const e = await import('esbuild'); await e.transform('let a = 1', { minify: true });
    for (const m of ['mysql2/promise', 'pdfkit', 'exceljs', 'qrcode', 'bcryptjs', 'jsqr']) await import(m);
  " >>"$HP_LOG_FILE" 2>&1)
}
if [ -d "$APP_DIR/node_modules" ] && native_ok; then
  step_end SKIPPED "node_modules lengkap, modul native (canvas, esbuild) dapat dimuat"
else
  info "Memasang dependency dengan npm ci (sesuai package-lock.json)..."
  if [ -f "$APP_DIR/package-lock.json" ]; then cmd=(npm ci --omit=dev --no-audit --no-fund); else cmd=(npm install --omit=dev --no-audit --no-fund); fi
  if (cd "$APP_DIR" && as_user "$APP_USER" "${cmd[@]}" >>"$HP_LOG_FILE" 2>&1) && native_ok; then
    step_end SUCCESS "${cmd[*]} selesai, modul native dapat dimuat"
  else
    step_end FAILED "${cmd[*]} gagal / modul native tidak dapat dimuat (lihat log: $HP_LOG_FILE)"; summary; exit 1
  fi
fi

# ---------- 14. Migrasi database ----------
step_begin "Database Migration"
FRESH_DB=0; [ "$EXISTING_TABLES" = 0 ] && FRESH_DB=1
backup_note=""
if [ "$FRESH_DB" -eq 0 ]; then
  info "Database berisi $EXISTING_TABLES tabel: backup dulu sebelum migrasi..."
  # Sebagai user aplikasi: folder _backup miliknya (root tidak menulis ke folder yang bisa diisi symlink oleh user itu)
  # dan kredensial database di .env juga miliknya.
  if out="$(as_user "$APP_USER" bash "$APP_DIR/scripts/backup-database.sh" "$APP_DIR" 2>&1)"; then backup_note="; backup: $(printf '%s' "$out" | tail -n1)"; log "$out"
  else step_end FAILED "backup sebelum migrasi gagal, migrasi tidak dijalankan: $out"; summary; exit 1; fi
fi
# Binary log aktif tanpa log_bin_trust_function_creators: membuat trigger butuh SUPER → impor lewat admin,
# user aplikasi tetap tanpa hak global. Selain itu impor memakai kode aplikasi (start.js --pasang-database).
binlog="$(sql_admin -e "SELECT @@log_bin AND NOT @@log_bin_trust_function_creators")"
if [ "$binlog" = 1 ]; then
  if awk 'BEGIN{skip=0} /^CREATE DATABASE/{skip=1} skip{ if ($0 ~ /;[[:space:]]*$/) skip=0; next } /^USE /{next} {print}' "$SELF_DIR/database.sql" \
       | sql_admin "$DB_NAME" >>"$HP_LOG_FILE" 2>&1; then
    code="$(random_hex 2 | tr a-f A-F)-$(random_hex 2 | tr a-f A-F)"
    sql_admin "$DB_NAME" -e "UPDATE tbl_perusahaan SET serial_number = '$code' WHERE serial_number IN ('HSS-001', '')" >>"$HP_LOG_FILE" 2>&1
    mig="database.sql diimpor lewat admin (binary log aktif)"
  else step_end FAILED "impor database.sql gagal (lihat log)$backup_note"; summary; exit 1; fi
else
  if out="$(cd "$APP_DIR" && as_user "$APP_USER" node start.js --pasang-database 2>&1)"; then
    mig="database.sql diterapkan ($(printf '%s' "$out" | tail -n1 | sed -E 's/.*"perintah":([0-9]+).*/\1 perintah/'))"
  else step_end FAILED "$(printf '%s' "$out" | tail -n1)$backup_note"; summary; exit 1; fi
fi
tables="$(sql_admin -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME'")"
step_end SUCCESS "$mig; $tables tabel$([ "$FRESH_DB" -eq 1 ] && echo ' (database baru)' || echo ', data lama dipertahankan')$backup_note. Kolom tambahan dibuat aplikasi saat start"

# ---------- 15. PM2: proses & startup ----------
step_begin "PM2 Process"
APP_LOG_DIR="$APP_HOME/.pm2/logs"
# Proses sianok-parking milik root (bila ada) tidak disentuh, hanya dilaporkan.
root_dup=""
if [ "$APP_USER" != root ] && [ -f /root/.pm2/pm2.pid ] && kill -0 "$(cat /root/.pm2/pm2.pid)" 2>/dev/null \
   && env "PATH=$PATH" HOME=/root pm2 pid "$HP_PM2_NAME" 2>/dev/null | grep '[1-9]' >/dev/null; then root_dup=1; fi
existing_cwd="$(as_user "$APP_USER" pm2 jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s.slice(s.indexOf("["))).find(x=>x.name===process.argv[1]);console.log(p?p.pm2_env.pm_cwd:"")}catch{console.log("")}})' "$HP_PM2_NAME")"
existing_cwd="${existing_cwd%/}"
if [ -n "$existing_cwd" ] && [ "$existing_cwd" != "$APP_DIR" ]; then
  warn "Proses PM2 '$HP_PM2_NAME' sudah ada untuk folder lain: $existing_cwd"
  if confirm "Ganti proses itu dengan folder ini ($APP_DIR)? Hanya proses '$HP_PM2_NAME' yang dihentikan" n; then
    run_logged as_user "$APP_USER" pm2 delete "$HP_PM2_NAME"; existing_cwd=""
  else step_end FAILED "proses '$HP_PM2_NAME' dipakai folder $existing_cwd (tidak diubah)"; summary; exit 1; fi
fi
if (cd "$APP_DIR" && run_logged as_user "$APP_USER" pm2 startOrReload ecosystem.config.cjs --update-env) && run_logged as_user "$APP_USER" pm2 save; then
  pm2_note="$([ -n "$existing_cwd" ] && echo "proses lama di-reload" || echo "proses baru dijalankan"), interpreter $HP_NODE_BIN"
else step_end FAILED "pm2 start gagal (lihat log)"; summary; exit 1; fi
# Rotasi log PM2 (modul resmi pm2-logrotate): 20 MB per file, 14 file disimpan, dikompres.
if [ ! -d "$APP_HOME/.pm2/modules/pm2-logrotate" ]; then
  if run_logged as_user "$APP_USER" pm2 install pm2-logrotate; then
    for kv in max_size=20M retain=14 compress=true; do run_logged as_user "$APP_USER" pm2 set "pm2-logrotate:${kv%%=*}" "${kv#*=}"; done
    pm2_note="$pm2_note; rotasi log aktif"
  else LOGROTATE_FAIL=1; fi
else pm2_note="$pm2_note; rotasi log sudah aktif"; fi
if [ -n "$root_dup" ]; then step_end "NEEDS ATTENTION" "$pm2_note; ADA proses '$HP_PM2_NAME' milik root juga (tidak disentuh) — hentikan agar tidak dobel"
elif [ "${LOGROTATE_FAIL:-0}" = 1 ]; then step_end "NEEDS ATTENTION" "$pm2_note; pm2-logrotate gagal dipasang (log tidak dirotasi)"
else step_end SUCCESS "$pm2_note"; fi

step_begin "PM2 Startup"
if run_logged env "PATH=$PATH" pm2 startup systemd -u "$APP_USER" --hp "$APP_HOME" && systemctl is-enabled --quiet "pm2-$APP_USER"; then
  step_end SUCCESS "systemd pm2-$APP_USER aktif saat boot (daftar proses tersimpan dengan pm2 save)"
else step_end FAILED "pm2 startup gagal (lihat log)"; fi

# ---------- 16. Opsional: tombol Restart/Shutdown Monitor Server ----------
step_begin "Izin restart server"
RULE_FILE="/etc/sudoers.d/$HP_PM2_NAME-power"
if [ -f "$RULE_FILE" ] && grep -q "^$APP_USER " "$RULE_FILE"; then step_end SKIPPED "aturan sudoers sudah ada"
else
  [ -z "$POWER_RULE" ] && [ "$INTERACTIVE" -eq 1 ] && confirm "Izinkan tombol Restart/Shutdown server di menu Monitor Server (hanya Owner)?" n && POWER_RULE=yes
  if [ "$POWER_RULE" = yes ]; then
    tmp="$(mktemp)"; printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff\n' "$APP_USER" >"$tmp"
    if visudo -cf "$tmp" >>"$HP_LOG_FILE" 2>&1; then install -m 440 "$tmp" "$RULE_FILE"; step_end SUCCESS "$RULE_FILE"; else step_end FAILED "aturan sudoers tidak valid"; fi
    rm -f "$tmp"
  else step_end SKIPPED "tidak diaktifkan (bisa dengan --izinkan-restart-server)"; fi
fi

# ---------- 17. Health check ----------
step_begin "Health Check"
if HP_HEALTH_WAIT=15 bash "$SELF_DIR/scripts/health-check.sh" "$APP_DIR"; then
  HEALTH_STATUS=LULUS; step_end SUCCESS "semua pemeriksaan wajib lulus"
else HEALTH_STATUS=GAGAL; step_end FAILED "ada pemeriksaan yang gagal (lihat di atas)"; fi
PM2_STATUS="$(as_user "$APP_USER" pm2 jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const p=JSON.parse(s.slice(s.indexOf("["))).find(x=>x.name===process.argv[1]);console.log(p?`${p.pm2_env.status} (pid ${p.pid}, restart ${p.pm2_env.restart_time})`:"tidak ada")})' "$HP_PM2_NAME")"

ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n3)"
ACCESS_URLS="$(for ip in $ips; do printf 'http://%s:%s  ' "$ip" "$APP_PORT"; done)"
[ "$HTTPS_PORT" != off ] && ACCESS_URLS="$ACCESS_URLS| HTTPS: https://<ip>:$HTTPS_PORT (sertifikat sendiri)"
[ -n "$SITE_URL" ] && ACCESS_URLS="$ACCESS_URLS| publik: $SITE_URL (arahkan reverse proxy / tunnel ke http://127.0.0.1:$APP_PORT)"

# ---------- 18. Kunci kode & catatan akses ----------
step_begin "Kunci kode"
if [ "$KUNCI" -eq 0 ]; then
  [ "$KUNCI_DIBUKA" = 1 ] && step_end "NEEDS ATTENTION" "kunci dibuka & tidak dikunci lagi (--tanpa-kunci)" || step_end SKIPPED "tidak dikunci (--tanpa-kunci)"
  KUNCI_DIBUKA=0
elif [ ! -f "$APP_DIR/views.pak" ]; then step_end SKIPPED "bukan folder rilis (tidak ada views.pak)"
else
  out="$(HP_KODE_APP="$APP_DIR" bash "$SELF_DIR/scripts/kunci-kode.sh" kunci 2>&1)"; rc=$?; log "$out"; KUNCI_DIBUKA=0
  case "$rc" in
    0) step_end SUCCESS "$(printf '%s' "$out" | tr '\n' ' ')" ;;
    *) step_end "NEEDS ATTENTION" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
fi

# ---------- 19. Tombol "Perbarui sistem" di Monitor Server ----------
# Updater milik root di /usr/local/sbin dengan folder aplikasi & alamat GitHub ditanam di dalamnya, dan aturan sudoers
# yang hanya mengizinkan file itu tanpa argumen. Lihat scripts/perbarui-sistem.sh.
step_begin "Perbarui dari web"
PERBARUI_BIN="/usr/local/sbin/$HP_PM2_NAME-perbarui"
PERBARUI_RULE="/etc/sudoers.d/$HP_PM2_NAME-perbarui"
PERBARUI_REPO="$(sed -n 's#.*"url": *"\(https://github\.com/[^"]*\)".*#\1#p' "$SELF_DIR/package.json" 2>/dev/null | head -n1)"
if [ "$PERBARUI" -eq 0 ]; then
  rm -f "$PERBARUI_RULE" "$PERBARUI_BIN"; step_end SKIPPED "tidak dipasang (--tanpa-perbarui-web)"
elif [ ! -f "$APP_DIR/views.pak" ]; then step_end SKIPPED "bukan folder rilis (tidak ada views.pak)"
elif ! [[ "$PERBARUI_REPO" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  step_end "NEEDS ATTENTION" "alamat GitHub (repository.url) tidak ada di package.json"
elif ! [[ "$APP_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  step_end "NEEDS ATTENTION" "path folder aplikasi berisi karakter khusus, updater tidak dipasang: $APP_DIR"
else
  # File sementara di folder yang sama lalu rename: proses perbarui yang sedang memakai file lama tidak terganggu.
  tmp="$(mktemp "/usr/local/sbin/.$HP_PM2_NAME-perbarui.XXXXXX")"
  sed -e "s#^APP='@@APP@@'#APP='$APP_DIR'#" -e "s#^NAMA='@@NAMA@@'#NAMA='$HP_PM2_NAME'#" \
      -e "s#^REPO='@@REPO@@'#REPO='$PERBARUI_REPO'#" -e "s#^CABANG='@@CABANG@@'#CABANG='main'#" \
      "$SELF_DIR/scripts/perbarui-sistem.sh" >"$tmp"
  chown root:root "$tmp"; chmod 755 "$tmp"
  if cmp -s "$tmp" "$PERBARUI_BIN"; then rm -f "$tmp"; perbarui_note="updater sudah terpasang"
  else mv -f "$tmp" "$PERBARUI_BIN"; perbarui_note="updater $PERBARUI_BIN dipasang"; fi
  tmp="$(mktemp)"; printf '%s ALL=(root) NOPASSWD: %s ""\n' "$APP_USER" "$PERBARUI_BIN" >"$tmp"
  if visudo -cf "$tmp" >>"$HP_LOG_FILE" 2>&1; then
    cmp -s "$tmp" "$PERBARUI_RULE" || install -m 440 "$tmp" "$PERBARUI_RULE"
    step_end SUCCESS "$perbarui_note; tombol Perbarui sistem aktif (sumber $PERBARUI_REPO)"
  else step_end FAILED "aturan sudoers tidak valid"; fi
  rm -f "$tmp"
fi

summary
for s in "${HP_STATUS[@]}"; do [ "$s" = FAILED ] && exit 1; done
for s in "${HP_STATUS[@]}"; do [ "$s" = "NEEDS ATTENTION" ] && exit 2; done
exit 0
