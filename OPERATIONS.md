# Production Operations

## Start with automatic restart

Install PM2 once on the server, then run:

```bash
npm install
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup
```

## Zero-downtime reload

After deploying new code:

```bash
npm install
pm2 reload sianok-parking
```

`reload` rotates clustered workers instead of stopping the service first.

Keep `instances: 1`. Kasir live updates (SSE), cache, and login attempt limits live in process memory; several instances would split them.

If MariaDB is not ready at boot, the server retries the database every 5 seconds and only starts listening once the tables are ready.

Set `USER_ID_SECRET` (a long random string) in `.env` on production. Without it, encrypted IDs use a built-in default key.

## Database setup

Keep credentials only in `.env`. Do not commit that file.

```bash
mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" < database.sql
```

## Time zone

Ticket times, the book date and reports use the app's time zone. By default this is the server's time zone.
- Set `TZ` in `.env` when the server is not on local time: `TZ=Asia/Jakarta` (WIB), `TZ=Asia/Makassar` (WITA) or `TZ=Asia/Jayapura` (WIT).
- Each database connection uses the same offset (`SET time_zone`), so `NOW()` and `CURDATE()` match the app even when MariaDB runs on another machine.
- If the server runs on UTC and `TZ` is not set, the app prints a warning when it starts.

## Health check

```bash
curl http://127.0.0.1:3003/api/health
```

The API also applies request timeouts, security headers, and a per-IP rate limit. Put the app behind HTTPS at the reverse proxy in production.

## Local-only pages

The gate API (`/api/gate/*`) and the cashier pages (`/kasir`, `/kasir/*`, `/api/kasir/*`) only answer requests made to the server's IP from the same local subnet. Requests through a domain or from outside get `403 Access denied`. Disable with `GATE_LOCAL_ONLY=off` or `KASIR_LOCAL_ONLY=off` in `.env`.

## Monitor Server (Owner only)

Profile menu → **Monitor Server** shows disk, RAM, CPU, and database size, and offers a database backup download plus server restart/shutdown. Only Owner accounts can open it. Every action needs the CSRF token and the Owner's password again (5 wrong passwords lock actions for 5 minutes). Restart/shutdown also need the word `RESTART` / `SHUTDOWN` typed in, and run 5 seconds after confirmation. Each action is written to the server log with user ID and IP.

Restart/shutdown run `systemctl reboot|poweroff` directly when systemd-logind lets the app user do so without a password (`CanReboot`/`CanPowerOff` = `yes`, normally when that user is logged in on the server machine itself, e.g. desktop session). Otherwise (PM2 at boot, SSH-only servers) they fall back to `sudo -n`; allow only those two commands for the user that runs the app (replace `niagait`):

```bash
echo 'niagait ALL=(root) NOPASSWD: /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff' | sudo tee /etc/sudoers.d/sianok-parking-power
sudo chmod 440 /etc/sudoers.d/sianok-parking-power
sudo visudo -c
```

Without this rule the buttons stay disabled. Set `SERVER_POWER=local` in `.env` to allow restart/shutdown only from the local network through the server IP, or `SERVER_POWER=off` to turn them off. Backup uses `mariadb-dump` (or `mysqldump`; override with `DB_DUMP_BIN`) and the database credentials in `.env`.

## Backup & restore

Monitor Server → **Backup database** downloads `backup-<db>-<YYYYMMDD-HHMMSS>.sql.gz`. It contains every table, all data, triggers and routines, in one consistent snapshot (`--single-transaction`). Since 2026-10-23 the file has no `CREATE DATABASE` / `USE` line, so a restore always goes into the database you name. Older files still contain `USE <original db>` and will overwrite that database.

That download is not kept on the server. Store each downloaded file away from the server machine.

**Automatic daily backup (since 2026-10-24).**
- **When:** the app makes a backup every day at 02:00 server time. Change the time with `BACKUP_DB_WAKTU=HH:MM` in `.env`, or turn it off with `BACKUP_DB_WAKTU=off`.
- **Where:** files go to `storage/backup-database/backup-<db>-<YYYYMMDD-HHMMSS>.sql.gz`. The folder is mode 700 and each file mode 600. The content is the same as the manual download.
- **How many are kept:** the 3 newest files per database. When the 4th is written, the oldest is deleted, leaving the 2nd, 3rd and 4th.
- **If a backup fails:**
  - The old backups are kept.
  - The failure goes to the PM2 log and to the WhatsApp contacts.
  - Successful backups are only logged (`Backup database otomatis: …`).
- **Limitation:** the job runs inside the app, so no backup is made on a night when the app is not running at 02:00.
- **Offsite copy:** these files sit on the same disk as the database. Still copy a backup off the machine regularly.

`storage/` must never be committed to a git repository, because the backups contain the full database.

Restore into a separate database first, check it, then switch:

```bash
mariadb -u root -p -e "CREATE DATABASE db_sianok_pulih CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci"
gunzip -c backup-db-sianok-parking-20261023-021114.sql.gz | mariadb -u root -p db_sianok_pulih
mariadb -u root -p db_sianok_pulih -e "SELECT COUNT(*), SUM(total_bayar) FROM tbl_transaksi_pendapatan; SELECT SUM(total) FROM tbl_pendapatan_harian"
```

The two totals must match. Then set `DB_NAME=db_sianok_pulih` in `.env` and restart the app, or restore the same file into the production database name during a maintenance window.

On 2026-10-23 this was tested on a 365,000-transaction test database: a 14 MB backup took about 5 s, and the restore took about 46 s.


## Pages in a release (views.pak)

A release build has no `views/` folder. All pages (login, dashboard, kasir, payment, audit, installer, API docs, Manual Book) are packed into one compressed file, `views.pak`, so they cannot be opened or edited on the server. The SHA-256 fingerprint of the pack is built into `server.js` and `start.js`.

- A `views/` folder created by hand is ignored.
- If `views.pak` is changed or damaged, every page answers `500` with "Paket tampilan aplikasi rusak atau diubah", and the log shows `Paket tampilan views.pak tidak dapat dipakai`. The gate, payment and other APIs keep working. To fix it, extract `views.pak` (or the whole release) again from the official release archive and restart the app.
- To change a page, edit `views/` in the source and make a new build (`npm run build`).

When the app runs from source (`npm start`), pages are read from `views/` as usual.
