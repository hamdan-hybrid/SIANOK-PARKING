#!/usr/bin/env bash
# Pemeriksaan awal server untuk Sianok Parking. Hanya membaca, tidak mengubah apa pun.
#
#   bash scripts/check-dependencies.sh [folder-aplikasi]
#
# Setiap baris: STATUS  komponen  keterangan. STATUS: OK / KURANG (dipasang setup.sh) / PERHATIAN / GAGAL.
# Exit 1 bila ada GAGAL (server tidak didukung), selain itu 0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
APP_DIR="$(cd "${1:-$HERE/..}" && pwd)"
GAGAL=0
row() {
  local status="$1" name="$2"; shift 2
  local color="$C_OK"
  case "$status" in KURANG) color="$C_SKIP" ;; PERHATIAN) color="$C_WARN" ;; GAGAL) color="$C_FAIL"; GAGAL=1 ;; esac
  printf '  %s%-10s%s %-20s %s\n' "$color" "$status" "$C_0" "$name" "$*"
  log "CHECK $status $name $*"
}

# Sistem operasi & perangkat keras.
. /etc/os-release 2>/dev/null || true
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04) row OK "Ubuntu" "${PRETTY_NAME:-}" ;;
  ubuntu:*) row PERHATIAN "Ubuntu" "${PRETTY_NAME:-} (diuji pada 22.04 / 24.04)" ;;
  *) row GAGAL "Sistem operasi" "${PRETTY_NAME:-tidak dikenal}: installer ini untuk Ubuntu Server 22.04 / 24.04" ;;
esac
case "$(uname -m)" in
  x86_64) row OK "Arsitektur" "x86_64" ;;
  aarch64) row PERHATIAN "Arsitektur" "aarch64: modul native diunduh ulang lewat npm ci (perlu internet)" ;;
  *) row GAGAL "Arsitektur" "$(uname -m) tidak didukung Node.js $HP_REQUIRED_NODE / @napi-rs/canvas" ;;
esac
mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
[ "$mem_mb" -ge 1500 ] && row OK "RAM" "${mem_mb} MB" || row PERHATIAN "RAM" "${mem_mb} MB (disarankan >= 2 GB: Node.js + MariaDB + FFmpeg)"
free_mb=$(df -Pm "$APP_DIR" | awk 'NR==2 {print $4}')
if [ "$free_mb" -lt 1024 ]; then row GAGAL "Disk" "sisa ${free_mb} MB di $(df -P "$APP_DIR" | awk 'NR==2 {print $6}') (minimal 1 GB)"
elif [ "$free_mb" -lt 5120 ]; then row PERHATIAN "Disk" "sisa ${free_mb} MB (foto kendaraan & backup butuh ruang; disarankan >= 5 GB)"
else row OK "Disk" "sisa $((free_mb / 1024)) GB"; fi

# Internet (hanya dibutuhkan bila ada yang harus dipasang).
if command -v curl >/dev/null && curl -fsI --max-time 8 https://nodejs.org/dist/ >/dev/null 2>&1; then row OK "Internet" "nodejs.org terjangkau"
else row PERHATIAN "Internet" "nodejs.org tidak terjangkau (atau curl belum ada); dibutuhkan bila Node.js/PM2 harus dipasang"; fi

# Aplikasi.
if [ -f "$APP_DIR/start.js" ] && [ -f "$APP_DIR/server.js" ] && [ -f "$APP_DIR/database.sql" ] && grep -q "name: '$HP_PM2_NAME'" "$APP_DIR/ecosystem.config.cjs" 2>/dev/null; then
  row OK "Folder aplikasi" "$APP_DIR ($HP_PM2_NAME)"
else row GAGAL "Folder aplikasi" "$APP_DIR bukan folder Sianok Parking (start.js / server.js / database.sql / ecosystem.config.cjs)"; fi
[ -f "$APP_DIR/.env" ] && row OK ".env" "ada (dipertahankan, hanya kunci yang kurang ditambahkan)" || row KURANG ".env" "belum ada, dibuat setup.sh"
[ -d "$APP_DIR/node_modules" ] && row OK "node_modules" "ada (diuji saat setup)" || row KURANG "node_modules" "belum ada, dipasang dengan npm ci"
for d in storage/parkir storage/pengeluaran public/uploads public/img; do
  [ -d "$APP_DIR/$d" ] && n="$(find "$APP_DIR/$d" -type f 2>/dev/null | wc -l)" && row OK "Data $d" "$n file (tidak dipindah / dihapus)"
done

# Runtime & layanan.
node_v="$(node -v 2>/dev/null || true)"
own_node="$(ls -d "$HP_NODE_ROOT"/node-v*/bin/node 2>/dev/null | tail -n1)"
if [ -n "$node_v" ] && version_ge "$node_v" "$HP_REQUIRED_NODE"; then row OK "Node.js" "$node_v ($(command -v node))"
elif [ -n "$own_node" ] && version_ge "$("$own_node" -v)" "$HP_REQUIRED_NODE"; then row OK "Node.js" "$("$own_node" -v) khusus Sianok Parking ($own_node)"
elif [ -n "$node_v" ]; then row KURANG "Node.js" "$node_v terlalu lama; Node.js v$HP_REQUIRED_NODE dipasang terpisah, node lama tidak diubah"
else row KURANG "Node.js" "belum ada, dipasang v$HP_REQUIRED_NODE"; fi
npm_v="$(npm -v 2>/dev/null || true)"; [ -n "$npm_v" ] && row OK "npm" "$npm_v" || row KURANG "npm" "ikut Node.js"
pm2_v="$(pm2 -v 2>/dev/null | tail -n1 || true)"; [ -n "$pm2_v" ] && row OK "PM2" "$pm2_v" || row KURANG "PM2" "belum ada, dipasang lewat npm"
if command -v mariadbd >/dev/null || command -v mysqld >/dev/null || [ -x /usr/sbin/mariadbd ] || [ -x /usr/sbin/mysqld ]; then
  db_v="$( (mariadb --version || mysql --version) 2>/dev/null | head -n1)"
  active="$(systemctl is-active mariadb 2>/dev/null || systemctl is-active mysql 2>/dev/null)"
  row OK "MariaDB" "${db_v:-terpasang} (layanan: $active)"
  if ss -Hltn 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):3306$' >/dev/null; then
    row PERHATIAN "MariaDB jaringan" "mendengarkan di semua alamat (3306). Pastikan firewall menutup port ini dari internet"
  fi
else row KURANG "MariaDB" "belum ada, dipasang dari repository Ubuntu"; fi
for bin in ffmpeg ffprobe; do
  v="$("$bin" -version 2>/dev/null | head -n1 | awk '{print $3}')"
  [ -n "$v" ] && row OK "$bin" "$v" || row KURANG "$bin" "belum ada, dipasang dari repository Ubuntu"
done
command -v mariadb-dump >/dev/null || command -v mysqldump >/dev/null && row OK "mariadb-dump" "ada (backup Monitor Server)" || row KURANG "mariadb-dump" "ikut mariadb-client"

# Port & proses.
port="$(env_get "$APP_DIR/.env" PORT)"; port="${port:-3003}"
if port_in_use "$port"; then row PERHATIAN "Port $port" "sedang dipakai: $(port_user "$port")"; else row OK "Port $port" "kosong"; fi
https="$(env_get "$APP_DIR/.env" HTTPS_PORT)"; https="${https:-3446}"
if [ "${https,,}" != off ]; then
  if port_in_use "$https"; then row PERHATIAN "Port HTTPS $https" "sedang dipakai: $(port_user "$https")"; else row OK "Port HTTPS $https" "kosong"; fi
fi
pm2_procs="$(pgrep -fa 'PM2 v[0-9.]*: God Daemon' 2>/dev/null | sed 's/^[0-9]* //' | tr '\n' ';')"
[ -n "$pm2_procs" ] && row OK "Daemon PM2" "berjalan: $pm2_procs" || row OK "Daemon PM2" "belum berjalan"
exit "$GAGAL"
