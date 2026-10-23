# Fungsi bersama setup.sh dan scripts/*.sh (di-source, bukan dijalankan langsung).
# Tidak ada rahasia yang ditulis ke layar atau log: password database hanya ada di .env (mode 600)
# dan di file sementara mode 600 yang dihapus saat skrip selesai.

HP_REQUIRED_NODE="26.12.1"          # engines.node di package.json
HP_NODE_ROOT="/usr/local/lib/nodejs" # Node.js khusus Sianok Parking (tarball resmi nodejs.org)
# Nama aplikasi = nama proses PM2 di ecosystem.config.cjs (mis. sianok-parking); dipakai juga untuk folder log,
# folder status installer, dan aturan sudoers, sehingga skrip yang sama berlaku untuk white label.
HP_APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HP_PM2_NAME="$(sed -n "s/^[[:space:]]*name: *'\([a-z0-9-]*\)'.*/\1/p" "$HP_APP_ROOT/ecosystem.config.cjs" 2>/dev/null | head -n1)"
HP_PM2_NAME="${HP_PM2_NAME:-sianok-parking}"
HP_LOG_DIR="/var/log/$HP_PM2_NAME"
HP_STATE_DIR="/var/lib/$HP_PM2_NAME-setup"

if [ -t 1 ]; then
  C_OK=$'\e[32m'; C_FAIL=$'\e[31m'; C_WARN=$'\e[33m'; C_SKIP=$'\e[36m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=''; C_FAIL=''; C_WARN=''; C_SKIP=''; C_DIM=''; C_B=''; C_0=''
fi

HP_LOG_FILE="${HP_LOG_FILE:-/dev/null}"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$HP_LOG_FILE"; }
info() { printf '      %s\n' "$*"; log "INFO $*"; }
warn() { printf '      %s%s%s\n' "$C_WARN" "$*" "$C_0"; log "WARN $*"; }
err() { printf '      %s%s%s\n' "$C_FAIL" "$*" "$C_0" >&2; log "ERROR $*"; }

# Jalankan perintah, keluaran ke log saja. Return code perintah dipertahankan.
run_logged() { log "RUN $*"; "$@" >>"$HP_LOG_FILE" 2>&1; }

# Status per tahap: SUCCESS / FAILED / SKIPPED / NEEDS ATTENTION.
HP_STEPS=(); HP_STATUS=(); HP_NOTES=()
step_begin() { HP_CUR_STEP="$1"; printf '\n%s▸ %s%s\n' "$C_B" "$1" "$C_0"; log "=== $1"; }
step_end() {
  local status="$1"; shift
  local note="$*" color
  case "$status" in SUCCESS) color="$C_OK" ;; FAILED) color="$C_FAIL" ;; SKIPPED) color="$C_SKIP" ;; *) color="$C_WARN" ;; esac
  HP_STEPS+=("$HP_CUR_STEP"); HP_STATUS+=("$status"); HP_NOTES+=("$note")
  printf '  %s%-16s%s %s\n' "$color" "$status" "$C_0" "$note"
  log "STATUS $HP_CUR_STEP: $status $note"
}

# Versi a >= b (format x.y.z, awalan v diabaikan).
version_ge() {
  local a="${1#v}" b="${2#v}"
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n1)" = "$b" ]
}

# Nilai dari file .env (format KEY=nilai, nilai boleh diapit " ' atau `). Kosong bila tidak ada.
env_get() {
  local file="$1" key="$2" line value
  [ -f "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n1)" || return 0
  value="${line#*=}"
  value="${value%$'\r'}"
  case "$value" in
    \"*\") value="${value:1:${#value}-2}" ;;
    \'*\') value="${value:1:${#value}-2}" ;;
    \`*\`) value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

# Tulis/ganti satu kunci di .env tanpa menyentuh baris lain. Nilai diapit tanda kutip yang tidak ada di dalamnya.
env_set() {
  local file="$1" key="$2" value="$3" quote tmp
  for quote in '"' "'" '`'; do case "$value" in *"$quote"*) ;; *) break ;; esac; done
  tmp="$(mktemp "${file}.XXXXXX")"
  if [ -f "$file" ] && grep -qE "^[[:space:]]*${key}=" "$file"; then
    awk -v k="$key" -v line="${key}=${quote}${value}${quote}" '
      $0 ~ "^[[:space:]]*" k "=" { if (!done) print line; done = 1; next } { print }' "$file" >"$tmp"
  else
    { [ -f "$file" ] && cat "$file"; printf '%s=%s%s%s\n' "$key" "$quote" "$value" "$quote"; } >"$tmp"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# Rahasia acak (hex) dari generator kriptografis kernel.
random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Jalankan perintah sebagai user layanan dengan Node.js Sianok Parking di depan PATH.
as_user() {
  local user="$1"; shift
  local home sudo_cmd=(sudo -u "$user" -H); home="$(getent passwd "$user" | cut -d: -f6)"
  [ "$(id -un)" = "$user" ] && sudo_cmd=()
  "${sudo_cmd[@]}" env "PATH=${HP_NODE_BIN_DIR:+$HP_NODE_BIN_DIR:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "HOME=$home" ${HP_NODE_BIN:+"HYBRID_PARKING_NODE=$HP_NODE_BIN"} "$@"
}

# File kredensial MariaDB sementara (mode 600) untuk --defaults-extra-file: password tidak muncul di argumen proses.
HP_TMP_FILES=()
hp_cleanup() { local f; for f in "${HP_TMP_FILES[@]}"; do [ -n "$f" ] && rm -f "$f"; done; }
trap hp_cleanup EXIT
db_defaults_file() {
  local host="$1" port="$2" user="$3" password="$4" file
  file="$(mktemp /tmp/hp-db.XXXXXX)"; chmod 600 "$file"; HP_TMP_FILES+=("$file")
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' "$host" "$port" "$user" "${password//\"/\\\"}" >"$file"
  printf '%s' "$file"
}

mariadb_bin() { command -v mariadb || command -v mysql; }
mariadb_dump_bin() { command -v mariadb-dump || command -v mysqldump; }

# Port TCP sedang dipakai? port_user mencetak proses pemakainya, mis. users:(("node",pid=1234,fd=24)).
port_user() { ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'users:(.*)' | head -n1; }
port_pids() { ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }
port_in_use() { [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]; }
