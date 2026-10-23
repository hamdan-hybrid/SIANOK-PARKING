#!/usr/bin/env bash
# Backup database Sianok Parking ke <folder aplikasi>/_backup/database/<db>-<YYYYMMDD-HHMMSS>.sql.gz (mode 600).
# Kredensial dibaca dari .env aplikasi. Satu snapshot konsisten (--single-transaction), termasuk trigger & routine,
# tanpa CREATE DATABASE / USE: saat dipulihkan, database tujuan harus disebut (lihat INSTALL.md).
# Backup lama tidak pernah dihapus.
#
#   bash scripts/backup-database.sh [folder-aplikasi]
#
# Exit 0 = berhasil (path file dicetak di baris terakhir), 1 = gagal.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

APP_DIR="$(cd "${1:-$HERE/..}" && pwd)"
ENV_FILE="$APP_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "Backup gagal: $ENV_FILE tidak ada" >&2; exit 1; }

DB_HOST="$(env_get "$ENV_FILE" DB_HOST)"; DB_PORT="$(env_get "$ENV_FILE" DB_PORT)"
DB_NAME="$(env_get "$ENV_FILE" DB_NAME)"; DB_USER="$(env_get "$ENV_FILE" DB_USER)"
DB_PASSWORD="$(env_get "$ENV_FILE" DB_PASSWORD)"
[ -n "$DB_NAME" ] && [ -n "$DB_USER" ] || { echo "Backup gagal: DB_NAME / DB_USER belum diisi di .env" >&2; exit 1; }

DUMP="$(mariadb_dump_bin)" || { echo "Backup gagal: mariadb-dump / mysqldump tidak ditemukan" >&2; exit 1; }
DEFAULTS="$(db_defaults_file "${DB_HOST:-127.0.0.1}" "${DB_PORT:-3306}" "$DB_USER" "$DB_PASSWORD")"

DIR="$APP_DIR/_backup/database"
mkdir -p "$DIR"; chmod 700 "$DIR"
TARGET="$DIR/${DB_NAME}-$(date +%Y%m%d-%H%M%S).sql.gz"
PARTIAL="$TARGET.partial"

umask 077
if "$DUMP" --defaults-extra-file="$DEFAULTS" --single-transaction --quick --routines --triggers --events --hex-blob \
     --default-character-set=utf8mb4 "$DB_NAME" 2>"$PARTIAL.err" | gzip -6 >"$PARTIAL"; then
  rm -f "$PARTIAL.err"
  mv "$PARTIAL" "$TARGET"
  # Pemilik folder aplikasi ikut memiliki backup (skrip ini bisa dijalankan sebagai root oleh setup.sh).
  owner="$(stat -c %U "$APP_DIR")"; [ "$owner" != root ] && chown -R "$owner:" "$DIR" 2>/dev/null
  tables="$(gzip -dc "$TARGET" | grep -c '^CREATE TABLE')"
  echo "Backup OK: $tables tabel, $(du -h "$TARGET" | cut -f1)"
  echo "$TARGET"
  exit 0
fi
echo "Backup gagal: $(tail -n3 "$PARTIAL.err" 2>/dev/null)" >&2
rm -f "$PARTIAL" "$PARTIAL.err"
exit 1
