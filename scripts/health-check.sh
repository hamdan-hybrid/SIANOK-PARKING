#!/usr/bin/env bash
# Pemeriksaan kesehatan Sianok Parking (tanpa transaksi palsu, tanpa membuka gate).
#
#   sudo bash scripts/health-check.sh [folder-aplikasi]
#
# Exit 0 = semua pemeriksaan wajib lulus, 1 = ada yang gagal (rinciannya dicetak).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

APP_DIR="$(cd "${1:-$HERE/..}" && pwd)"
ENV_FILE="$APP_DIR/.env"
APP_USER="$(stat -c %U "$APP_DIR")"
FAILS=0; WARNS=0
pass() { printf '  %sPASS%s  %s\n' "$C_OK" "$C_0" "$*"; log "HEALTH PASS $*"; }
fail() { printf '  %sFAIL%s  %s\n' "$C_FAIL" "$C_0" "$*"; log "HEALTH FAIL $*"; FAILS=$((FAILS + 1)); }
note() { printf '  %sWARN%s  %s\n' "$C_WARN" "$C_0" "$*"; log "HEALTH WARN $*"; WARNS=$((WARNS + 1)); }

# Node.js yang dipakai PM2 untuk Sianok Parking (HYBRID_PARKING_NODE), selain itu node di PATH.
pm2_cmd() {
  if [ "$(id -un)" = "$APP_USER" ]; then pm2 "$@"; else as_user "$APP_USER" pm2 "$@"; fi
}
for dir in "$HP_NODE_ROOT"/node-v*/bin; do [ -x "$dir/node" ] && HP_NODE_BIN_DIR="$dir"; done
export PATH="${HP_NODE_BIN_DIR:+$HP_NODE_BIN_DIR:}$PATH"

echo "${C_B}Health check Sianok Parking${C_0}  ${C_DIM}$APP_DIR (user $APP_USER)${C_0}"

# --- Sistem ---
JLIST="$(pm2_cmd jlist 2>/dev/null)"
PROC_JSON="$(printf '%s' "$JLIST" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    let list = []; try { list = JSON.parse(s.slice(s.indexOf("["))); } catch {}
    const p = list.find(x => x.name === process.argv[1]);
    console.log(p ? JSON.stringify({ status: p.pm2_env.status, restarts: p.pm2_env.restart_time, unstable: p.pm2_env.unstable_restarts, pid: p.pid, cwd: p.pm2_env.pm_cwd, node: p.pm2_env.exec_interpreter, uptime: p.pm2_env.pm_uptime, out: p.pm2_env.pm_out_log_path, err: p.pm2_env.pm_err_log_path }) : "");
  });' "$HP_PM2_NAME" 2>/dev/null)"
pjson() { printf '%s' "$PROC_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s)[process.argv[1]];console.log(v??"")})' "$1"; }

NODE_BIN="node"
if [ -n "$PROC_JSON" ]; then NODE_BIN="$(pjson node)"; [ "$NODE_BIN" = node ] && NODE_BIN="$(command -v node)"; fi
if NODE_V="$("$NODE_BIN" -v 2>/dev/null)" && version_ge "$NODE_V" "$HP_REQUIRED_NODE"; then pass "Node.js $NODE_V ($NODE_BIN)"; else fail "Node.js ${NODE_V:-tidak ada} (butuh >= $HP_REQUIRED_NODE)"; fi
NPM_BIN="$(dirname "$NODE_BIN")/npm"; [ -x "$NPM_BIN" ] || NPM_BIN="$(command -v npm)"
if NPM_V="$("$NPM_BIN" -v 2>/dev/null)"; then pass "npm $NPM_V"; else fail "npm tidak dapat dijalankan"; fi

if PM2_V="$(pm2_cmd -v 2>/dev/null | tail -n1)" && [ -n "$PM2_V" ]; then pass "PM2 $PM2_V"; else fail "PM2 tidak dapat dijalankan sebagai $APP_USER"; fi

DB_SERVICE=""
for unit in mariadb mysql; do systemctl is-active --quiet "$unit" 2>/dev/null && { DB_SERVICE="$unit"; break; }; done
if [ -n "$DB_SERVICE" ]; then pass "Layanan $DB_SERVICE aktif, otomatis start: $(systemctl is-enabled "$DB_SERVICE" 2>/dev/null)"; else fail "Layanan MariaDB tidak aktif"; fi

for bin in ffmpeg ffprobe; do
  if v="$(as_user "$APP_USER" "$bin" -version 2>/dev/null | head -n1 | awk '{print $3}')" && [ -n "$v" ]; then pass "$bin $v (bisa dijalankan user $APP_USER)"; else fail "$bin tidak dapat dijalankan user $APP_USER"; fi
done
# Kebutuhan aktual gate.js: input RTSP (kamera) / HTTP (snapshot JPEG) → 1 frame JPEG (encoder mjpeg).
if as_user "$APP_USER" ffmpeg -hide_banner -demuxers 2>/dev/null | grep -w rtsp >/dev/null \
   && as_user "$APP_USER" ffmpeg -hide_banner -protocols 2>/dev/null | grep -w http >/dev/null \
   && as_user "$APP_USER" ffmpeg -hide_banner -encoders 2>/dev/null | grep -w mjpeg >/dev/null; then
  TMPJ="$(mktemp -d /tmp/hp-ffmpeg.XXXXXX)"; chmod 777 "$TMPJ"
  if as_user "$APP_USER" ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=1 -frames:v 1 -q:v 4 -y "$TMPJ/tes.jpg" \
     && [ "$(as_user "$APP_USER" ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$TMPJ/tes.jpg")" = mjpeg ]; then
    pass "FFmpeg: RTSP & HTTP input, encode JPEG, dibaca ulang FFprobe"
  else fail "FFmpeg gagal membuat snapshot JPEG"; fi
  rm -rf "$TMPJ"
else fail "FFmpeg tanpa demuxer rtsp / protocol http / encoder mjpeg"; fi

if (cd "$APP_DIR" && as_user "$APP_USER" "$NODE_BIN" --input-type=module -e "
  const c = await import('@napi-rs/canvas'); c.createCanvas(8, 8).toBuffer('image/png');
  const e = await import('esbuild'); await e.transform('let a = 1', { minify: true });
  await import('mysql2/promise'); await import('pdfkit'); await import('exceljs'); await import('qrcode'); await import('bcryptjs');
" >/dev/null 2>&1); then pass "Modul native & library (canvas, esbuild, mysql2, pdfkit, exceljs) dapat dimuat"
else fail "Modul native / library aplikasi gagal dimuat (jalankan ulang setup.sh)"; fi

# --- Konfigurasi & database ---
if [ -f "$ENV_FILE" ]; then
  perm="$(stat -c '%a %U' "$ENV_FILE")"
  if [ "${perm%% *}" = 600 ] && [ "${perm#* }" = "$APP_USER" ]; then pass ".env ada (600, milik $APP_USER)"; else note ".env permission $perm (seharusnya 600 milik $APP_USER)"; fi
else fail ".env tidak ada"; fi
PORT="$(env_get "$ENV_FILE" PORT)"; PORT="${PORT:-3003}"
DB_NAME="$(env_get "$ENV_FILE" DB_NAME)"; DB_USER="$(env_get "$ENV_FILE" DB_USER)"
DEFAULTS="$(db_defaults_file "$(env_get "$ENV_FILE" DB_HOST)" "$(env_get "$ENV_FILE" DB_PORT)" "$DB_USER" "$(env_get "$ENV_FILE" DB_PASSWORD)")"
if tables="$("$(mariadb_bin)" --defaults-extra-file="$DEFAULTS" -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()" "$DB_NAME" 2>/dev/null)"; then
  missing="$("$(mariadb_bin)" --defaults-extra-file="$DEFAULTS" -N -e "SELECT GROUP_CONCAT(t) FROM (SELECT 'tbl_perusahaan' t UNION SELECT 'tbl_pengguna' UNION SELECT 'tbl_transaksi_parkir' UNION SELECT 'tbl_transaksi_pendapatan' UNION SELECT 'tbl_pendapatan_harian' UNION SELECT 'tbl_closing') w WHERE t NOT IN (SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE())" "$DB_NAME" 2>/dev/null)"
  if [ "$missing" = NULL ] || [ -z "$missing" ]; then pass "Database $DB_NAME: koneksi $DB_USER OK, $tables tabel"; else fail "Database $DB_NAME: tabel belum ada: $missing"; fi
else fail "Koneksi database $DB_NAME sebagai $DB_USER gagal"; fi
tidak_bisa=""
for dir in storage storage/parkir public/uploads public/img; do
  [ -d "$APP_DIR/$dir" ] && as_user "$APP_USER" test -w "$APP_DIR/$dir" || tidak_bisa="$tidak_bisa $dir"
done
[ -z "$tidak_bisa" ] && pass "Folder data (storage, public/uploads, public/img) bisa ditulis $APP_USER" || fail "Folder tidak ada / tidak bisa ditulis $APP_USER:$tidak_bisa"

# --- Aplikasi ---
if [ -z "$PROC_JSON" ]; then fail "Proses PM2 $HP_PM2_NAME tidak ditemukan untuk user $APP_USER"
else
  status="$(pjson status)"; cwd="$(pjson cwd)"; pid="$(pjson pid)"
  [ "$status" = online ] && pass "PM2 $HP_PM2_NAME online (pid $pid)" || fail "PM2 $HP_PM2_NAME status $status"
  [ "${cwd%/}" = "$APP_DIR" ] && pass "Proses PM2 menjalankan folder ini" || fail "Proses PM2 menjalankan folder lain: $cwd"
  # Restart loop: jumlah restart tidak boleh bertambah selama jeda pengamatan.
  r1="$(pjson restarts)"; sleep "${HP_HEALTH_WAIT:-12}"
  PROC_JSON="$(pm2_cmd jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const l=JSON.parse(s.slice(s.indexOf("[")));const p=l.find(x=>x.name===process.argv[1]);console.log(p?JSON.stringify({restarts:p.pm2_env.restart_time,status:p.pm2_env.status}):"{}")})' "$HP_PM2_NAME")"
  r2="$(pjson restarts)"
  [ "$r1" = "$r2" ] && [ "$(pjson status)" = online ] && pass "Tidak ada restart loop (restart $r2 kali sejak start, tetap selama ${HP_HEALTH_WAIT:-12} dtk)" || fail "Proses restart berulang ($r1 → $r2)"
  # Mode cluster: socket dipegang daemon PM2 (God Daemon) milik user aplikasi, worker menerima koneksi darinya.
  daemon="$(cat "$(getent passwd "$APP_USER" | cut -d: -f6)/.pm2/pm2.pid" 2>/dev/null)"
  if [ -n "$pid" ] && port_pids "$PORT" | grep -xE "$pid${daemon:+|$daemon}" >/dev/null; then pass "Port $PORT didengarkan proses Sianok Parking (PM2 $APP_USER)"
  elif port_in_use "$PORT"; then fail "Port $PORT dipakai proses lain: $(port_user "$PORT")"
  else fail "Port $PORT belum didengarkan"; fi
fi
health="$(curl -fsS --max-time 10 "http://127.0.0.1:$PORT/api/health" 2>/dev/null)"
[ "$health" = '{"ok":true}' ] && pass "GET /api/health → $health (aplikasi + database)" || fail "GET /api/health → ${health:-tidak menjawab}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/login")"
[ "$code" = 200 ] && pass "Halaman login → HTTP 200" || fail "Halaman login → HTTP $code"
if [ -n "$PROC_JSON" ]; then
  errlog="$(pm2_cmd jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const p=JSON.parse(s.slice(s.indexOf("["))).find(x=>x.name===process.argv[1]);console.log(p?.pm2_env.pm_err_log_path||"")})' "$HP_PM2_NAME")"
  if [ -f "$errlog" ] && [ -s "$errlog" ] && tail -n 40 "$errlog" | grep -iE 'uncaught|fatal|EADDRINUSE|ER_ACCESS_DENIED|Cannot find module' >/dev/null; then
    note "Log error berisi pesan kritis (lihat: tail -n 50 $errlog)"
  else pass "Log error tanpa pesan kritis"; fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "${C_OK}${C_B}SEHAT${C_0}: semua pemeriksaan wajib lulus$([ "$WARNS" -gt 0 ] && echo " ($WARNS peringatan)")."; exit 0; fi
echo "${C_FAIL}${C_B}TIDAK SEHAT${C_0}: $FAILS pemeriksaan gagal."; exit 1
