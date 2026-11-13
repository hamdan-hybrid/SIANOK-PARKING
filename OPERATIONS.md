# Production Operations

## Start with automatic restart

Install PM2 once on the server, then run:

```bash
npm install
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup
```

`ecosystem.config.cjs` sets `max_memory_restart: '500M'` (300M until 2026-11-10: normal busy-hour usage of 150–250 MB came too close). PM2 checks memory every 30 seconds and counts the whole RSS, file-backed pages included. If the app restarts every ~30 seconds, check `~/.pm2/pm2.log` of the app user (`/var/lib/<user>/.pm2/pm2.log` on a `setup.sh` install) for `exceeds --max-memory-restart value`. `pm2 describe sianok-parking` shows the restart count.

- **System fonts.** `@napi-rs/canvas` (ticket and receipt images) loads every system font when it is imported. A server with a full font package such as `fonts-noto` (~1,800 files) adds about 200 MB of RSS. On one client server that alone pushed the app over 300 MB and caused 590 restarts in 5 hours. `start.js` sets `DISABLE_SYSTEM_FONTS_LOAD=1` before loading the server, and tickets use their own fonts in `fonts/` (DejaVu). Setting the variable empty in `.env` loads system fonts again.
- **Memory log.** While RSS is above 220 MB the app logs `Memori: rss …, heap …, external … (arrayBuffers …)` every 10 minutes (pm2 out log). A growing `heap` points at JavaScript objects; growing `external`/`arrayBuffers` at buffers (photos, video, reports).
- **Photo thumbnails (since 2026-11-10).** The Transaksi page loads dozens of thumbnails at once (HTTP/2 through Cloudflare), and each camera photo is decoded in full (8–15 MB). Before the limit, 40 new thumbnails at once took about 780 MB of RSS (above `max_memory_restart`) and held the event loop for about 55 ms. Now at most 2 are made at the same time, each file only once even when requested together, and WebP encoding runs off the main thread: about 220 MB and 7 ms. Thumbnails are saved in `storage/parkir/.thumb/`, so each photo costs this only once.
- **Check the real usage.** In `/proc/<pid>/status`, `RssAnon` is the app's own memory. `RssFile` is mapped files (Node binary, native modules, fonts) that the kernel can drop.

**HTTPS through the domain.** Requests that come through Cloudflare / a reverse proxy with `X-Forwarded-Proto: https` get `Strict-Transport-Security: max-age=15552000` (180 days, without subdomains), so browsers stop trying plain HTTP for that domain. LAN access (`http://<ip>:<port>`) and the app's own self-signed HTTPS port never get the header.

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

## Daily closing (tanggal buku)

Company menu → *Metode tutup harian*:

- **Manual** (default). The book date moves one day when a cashier presses **Tutup Harian** with an SPV password, once for all areas and cashiers. That press also unlocks every cashier account.
- **Otomatis** + *Jam tutup harian otomatis* (24-hour picker, default 00:00). The current book date follows the closing time:
  - **00:00–11:59** (e.g. 03:00): after-midnight payments still belong to yesterday. A payment at 02/01 02:59 is book date 01/01; at 03:00 the book date becomes 02/01.
  - **12:00–23:59** (e.g. 23:00): payments after the closing time already belong to tomorrow. A payment at 01/01 23:00 is book date 02/01.
  - The rule is `TANGGAL_BUKU_SQL` in server.js and `closingTimeHint` in spa-router.js; keep them the same.
  - The app checks every 30 seconds, and 15 seconds after start. Once the closing time has passed, one transaction does all of this:
    - It writes one *tutup harian otomatis* row in `tbl_closing` for each cashier who still has transactions not yet closed (`jenis = 'global'`, `otomatis = 1`, no SPV). A cashier without transactions gets no row but is still logged out. Cash is not counted, so `tunai_input = tunai_sistem` and `selisih = 0`.
    - It sets the book date to the current one. A server that was off for several days jumps straight there.
    - It unlocks every cashier account and deletes every cashier session.
  - Open cashier pages then go back to the PIN page ("Tutup harian otomatis selesai").
  - WhatsApp *Tutup Harian Otomatis* sends the closed day's revenue:
    - per user who recorded it (cashiers, dashboard input, *Tanpa kasir*), split by payment method;
    - the total per payment method;
    - the grand total.
  - Log line: `Tutup harian otomatis (jam HH:MM): tanggal buku <old> -> <new>, N tutup kasir, semua kasir keluar`.
  - **Payment in progress.** While any cashier holds a payment lock (pay / QRIS / card popup open), the close waits, for 10 minutes at most. That payment still lands on the old book date and is included.
  - **Cashier closing is locked.** The cashier's *Tutup Kasir* button shows a lock and "Otomatis HH:MM". The server refuses both Tutup Shift and Tutup Harian (409). Changing the method or the time in the Company menu updates open cashier pages immediately.

Saving the Company form changes the book date only when its field was edited. A form opened before the closing time therefore does not move the date back.

New installs get today's date as the book date (`database.sql` seed). An existing company row with an empty book date is filled with today on the next `database.sql` import.

## One kasir account on several screens

One kasir account serves one gate and may be logged in on several devices at once. The screens stay in sync: a ticket scanned on one device appears on the others, and when one device settles it, the others show it as paid and clear.

- **Only one device executes a payment.** While a QRIS or card popup is open, the other devices of that account are locked and show a banner. `/api/kasir/bayar`, `qris/buat`, `emoney/mulai`, and `emoney/tap` enforce this on the server, and a ticket being paid is also locked against other kasir accounts.
- **Lock expiry.** A device keeps its lock with a heartbeat every 8 seconds. If it disappears (closed tab, lost network), the lock expires after about 30 seconds and the other devices unlock.
- **Last guard.** `UPDATE ... WHERE status = 'in'` still allows a ticket to be settled only once. A payment already proven paid by the QRIS or card SDK is not held back by the lock.
- **Not mirrored.** The Tiket Manual, Tiket Hilang, and Member popups stay on the device that opened them. A receipt, the gate command, and the exit photo come only from the device that executes.
- **Shift close.** It is refused while another device of the account is paying. Afterwards the other devices return to the PIN page.

Sync state and locks live in process memory (see `instances: 1`), so a restart clears them. Screens reconnect by themselves and keep the ticket on display.

## Role authorization (Users → Otorisasi)

The **Otorisasi** button on the Users page, and the (i) button next to *Hak akses* in the user form, open a read-only overview of what each role (Owner, Admin, Svp, Kasir, Audit) can do: a table of all roles plus one tab per role. The rules themselves are fixed in the server code. The overview is `otorisasiGrup` in `public/spa-router.js`, so update it whenever a role check in `server.js` changes. Rows tied to a menu that this app does not have are hidden automatically.

## Monitor Server (Owner only)

Profile menu → **Monitor Server** shows disk, RAM, CPU, and database size, and offers a database backup download plus server restart/shutdown. Only Owner accounts can open it. Every action needs the CSRF token and the Owner's password again (5 wrong passwords lock actions for 5 minutes). Restart/shutdown also need the word `RESTART` / `SHUTDOWN` typed in, and run 5 seconds after confirmation. Each action is written to the server log with user ID and IP.

Restart/shutdown run `systemctl reboot|poweroff` directly when systemd-logind lets the app user do so without a password (`CanReboot`/`CanPowerOff` = `yes`, normally when that user is logged in on the server machine itself, e.g. desktop session). Otherwise (PM2 at boot, SSH-only servers) they fall back to `sudo -n`; allow only those two commands for the user that runs the app (replace `niagait`):

```bash
echo 'niagait ALL=(root) NOPASSWD: /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff' | sudo tee /etc/sudoers.d/sianok-parking-power
sudo chmod 440 /etc/sudoers.d/sianok-parking-power
sudo visudo -c
```

Without this rule the buttons stay disabled. Set `SERVER_POWER=local` in `.env` to allow restart/shutdown only from the local network through the server IP, or `SERVER_POWER=off` to turn them off. Backup uses `mariadb-dump` (or `mysqldump`; override with `DB_DUMP_BIN`) and the database credentials in `.env`.

### System update (Perbarui sistem)

The **Perbarui sistem** card installs the latest release from GitHub (`package.json` → `repository.url`, branch `main`) after the Owner types `PERBARUI` and the password again. The UI never shows the source address ("latest version" only); `/api/server-monitor/perbarui*` do not return it and log lines are masked.

- `setup.sh` installs a root-owned updater `/usr/local/sbin/<name>-perbarui` (from `scripts/perbarui-sistem.sh`, with the app folder and repo URL baked in) and `/etc/sudoers.d/<name>-perbarui`: `<user> ALL=(root) NOPASSWD: /usr/local/sbin/<name>-perbarui ""` — that file only, no arguments. Skip with `setup.sh --tanpa-perbarui-web`. Release installs only (views.pak); source folders show the button disabled.
- The app runs `sudo -n <updater>`; it starts a transient systemd unit and returns, so the update survives the PM2 reload. Progress: `/var/lib/<name>-perbarui/status.json` (root-written, world-readable). Log: `/var/log/<name>/perbarui-sistem.log`.
- Steps: `git clone --depth 1` (or the codeload tarball when git is missing) into a root-only folder → verify release files and app name → stop if `build-info.json` is identical → snapshot old code (last 2 kept) → unlock → copy files (never `storage/`, `.env`, `_backup/`, `public/uploads`, `public/img`) → run **the downloaded** `setup.sh --yes --app-dir <app>` (pre-migration DB backup as the app user, migration, PM2 reload, health check, relock).
- Hardening: nothing the app user can write is executed as root (setup scripts, kunci-kode, and `database.sql` are read from the private download; backup runs as the app user), `DB_NAME` may not be a MariaDB system schema, and `chmod` skips symlinked data folders.
- WhatsApp is sent when an update starts and when it finishes or fails (`storage/perbarui-sistem-wa.json` prevents duplicates).
- `SERVER_UPDATE=local` limits the button to the local network through the server IP, `SERVER_UPDATE=off` disables it.
- Installs from before this feature need one manual `sudo bash scripts/update.sh <package.tar.gz>`; afterwards the button works.

## CCTV Monitor (Owner, Admin, Svp)

Profile menu → **CCTV Monitor** (below Monitor Server) shows the cameras from the Devices menu as live video. Owner, Admin and Svp accounts can open it (`CCTV_PERAN` in `cctv.js`, checked on `/api/cctv` and again on the video WebSocket). It works through the domain / Cloudflare Tunnel too, so they can watch from anywhere. Camera and RTSP ports are never exposed to the internet.

- **go2rtc, not the app, carries the video.** `setup.sh` installs [go2rtc](https://github.com/AlexxIT/go2rtc) (one MIT binary, version and SHA-256 pinned in `setup.sh`) at `/usr/local/bin/go2rtc`. "Perbarui sistem" installs it too, because the updater runs `setup.sh`. `cctv.js` starts go2rtc when CCTV Monitor opens and stops it 10 minutes after the last viewer leaves. go2rtc keeps one RTSP connection per camera for every viewer, with no re-encoding, and sends fragmented MP4 over a WebSocket. The browser plays it with Media Source Extensions (ManagedMediaSource on iPhone, iOS 17.1+).
- **Why a separate process.** In 1.1.3–1.1.4 the video went through the app's own memory. PM2 then restarted the whole app every ~30 seconds while CCTV was open (`max_memory_restart: '300M'`, checked every 30 s), and the cashier and gates went down with it. Now the app only checks login, the Owner role and the viewer limit, then pipes the WebSocket to go2rtc without reading the video.
- **Closed to the outside.** go2rtc's API is reachable only through a unix socket in `storage/go2rtc/` (folder 0700). When `storage/` sits on a filesystem without Unix permissions (NTFS or exFAT through `fuseblk`, where every file shows as root 777), the app deletes `storage/go2rtc/` and uses `/tmp/hp-go2rtc-<uid>/` instead, so the camera passwords stay private. No TCP port is opened, and go2rtc's built-in RTSP, WebRTC and HomeKit servers are off. The generated config `storage/go2rtc/go2rtc.yaml` (mode 0600, rewritten on every start) holds the camera URLs. A camera URL changed in the Devices menu reaches go2rtc on the next view, without a restart. `GO2RTC_BIN` in `.env` overrides the binary path.
- **Sub-stream.** Devices → Camera → *URL sub-stream (opsional)* (column `rtsp_live`) is used for live view when filled. Gate photos keep using the main *URL RTSP*. Set the sub-stream on the camera to H.264, about 640×360, 10–15 fps, 384–512 kbps. Browsers cannot reliably play H.265, and a camera without a sub-stream is shown as **Stream utama**, which uses more of the site's upload. A sub-stream at 3–4 Mbps is a main-stream setting and costs the same upload.
- **Upload limit.** Each viewer from the internet pulls video through the site's upload, which QRIS payments also use. Open CCTV Monitor tabs from the internet are limited to `CCTV_MAKS_PENONTON` in `.env` (default `3`, `0` = no limit). A tab counts once, whatever the number of cameras. Dashboards opened through the server IP on the local network are not counted.
- **Auto stop.** Video stops when the Owner leaves the page, hides the tab, or is inactive for 10 minutes. The "Satu camera" mode streams only the selected camera. A dropped camera or connection reconnects on its own after 2, 4, 8, then every 15 seconds.
- **Log.** Each viewer is written to the server log once per camera with user ID and IP (`CCTV Monitor: user #… menonton "…"`). go2rtc warnings and errors, for example a camera closing RTSP, appear as `CCTV Monitor (go2rtc): …`, at most 10 lines a minute, with RTSP user and password masked. `CCTV Monitor: go2rtc berhenti (…)` means go2rtc exited on its own.
- **Check.** `/usr/local/bin/go2rtc -version` shows the installed version. A tile showing `dial tcp <ip>:554: i/o timeout` means the server cannot reach the camera. Test from the server with `timeout 4 bash -c '</dev/tcp/<ip>/554'`. `ip neigh` showing `FAILED` or `INCOMPLETE` for the camera IP means the camera is off or unplugged. A tile showing *go2rtc belum terpasang di server* means the binary is missing: run "Perbarui sistem" or `sudo bash setup.sh --yes`.

## Storage disk (photos on the largest disk)

`setup.sh` (step "Disk penyimpanan", `scripts/disk-data.sh`) puts `storage/` on the largest disk. `storage/` holds vehicle photos, daily database backups and the SSL certificate. The disk is chosen in this order:

1. A disk already mounted from `/etc/fstab` with more free space than the app disk.
2. An unmounted partition that already has a filesystem. It is mounted at `/mnt/data` without formatting.
3. A blank disk. It is formatted only after the operator types `YA` in the wizard.

`/mnt/data/sianok-parking` is then bind-mounted onto `storage/` through `/etc/fstab`, with `nofail`. The old fstab is kept as `/etc/fstab.bak-sianok-parking-<time>`.

- **`--yes` and Perbarui sistem** never format a disk and never move existing photos. They report NEEDS ATTENTION instead.
- **Moving existing photos:** run `sudo bash setup.sh` at a quiet hour. rsync copies while the app keeps running, then the app stops for a few seconds for the final pass. The old copy stays in `_backup/storage-lama-<time>`.
- **Checking:** run `findmnt <app>/storage`. The health check warns when the fstab bind exists but the disk is not mounted, because photos then land on the system disk.
- **Opting out:** `--tanpa-disk-data` keeps `storage/` on the system disk, and the choice is remembered. `--disk-data DIR` uses a folder of your choice.
- **Details and undo:** see INSTALL.md → "Disk penyimpanan".

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
- **Missed schedule (catch-up, since 2026-11-10):** the job runs inside the app, so it cannot fire while the machine is off at 02:00. One minute after the app starts, if the newest backup is older than the last scheduled time (or there is none), it makes one straight away. That is at most one extra backup per schedule, so repeated restarts cannot push older backups out of the rotation. `BACKUP_DB_WAKTU=off` turns this off too.
- **Limitation:** the check runs only when the app starts. A machine that sleeps through 02:00 and wakes without restarting the app gets no catch-up.
- **Offsite copy:** these files sit on the same machine as the database (on the data disk when there is one, see "Storage disk"). Still copy a backup off the machine regularly.

`storage/` must never be committed to a git repository, because the backups contain the full database.

Restore into a separate database first, check it, then switch:

```bash
mariadb -u root -p -e "CREATE DATABASE db_sianok_pulih CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci"
gunzip -c backup-db-sianok-parking-20261023-021114.sql.gz | mariadb -u root -p db_sianok_pulih
mariadb -u root -p db_sianok_pulih -e "SELECT COUNT(*), SUM(total_bayar) FROM tbl_transaksi_pendapatan; SELECT SUM(total) FROM tbl_pendapatan_harian"
```

The two totals must match. Then set `DB_NAME=db_sianok_pulih` in `.env` and restart the app, or restore the same file into the production database name during a maintenance window.

On 2026-10-23 this was tested on a 365,000-transaction test database: a 14 MB backup took about 5 s, and the restore took about 46 s.

### Import database (Monitor Server)

Monitor Server → **Import database** restores a backup from the browser, without a terminal. It is Owner-only and asks for the word `IMPORT` plus the account password. **All current data is replaced by the file.**

- **Source:** either upload a `.sql.gz` / `.sql` file (maximum 2 GB, change with `IMPORT_DB_MAX_MB` in `.env`), or pick a backup already in `storage/backup-database`.
- **Checked first:** the whole file is read before anything changes. A truncated or damaged file, a dump of another application, or any statement a backup would not contain (GRANT, DROP DATABASE, functions or subqueries in INSERT, CREATE TABLE … SELECT, procedures, views, another database's tables) rejects the file, and the database is untouched.
- **During the import:** the app is in maintenance mode. The kasir, gates, REST API and dashboard answer `503`, and pages reload themselves. Allow about 1–2 minutes per 365,000 transactions.
- **Safety copy:** before the import, the current database is dumped to `storage/backup-database/sebelum-impor-<db>-<YYYYMMDD-HHMMSS>.sql.gz`. The 3 newest are kept, separately from the daily backups. To undo an import, choose that file in the same card and press **Pulihkan**.
- **If the import fails midway:** the safety copy is restored automatically, and the card says so.
- **What is not replaced:**
  - Login sessions (`hp_sessions`) stay, so people stay logged in. Sessions whose user no longer exists or now has a different username are deleted.
  - Tables that exist in the database but not in the file are left as they are.
  - Photos and other files under `storage/` are not in the backup. A photo that no transaction refers to any more stays on disk, and a restored transaction whose photo was deleted shows no photo.
- **Afterwards:** table migrations run, so an older backup is brought up to the current structure. Triggers from the file are never run; the app creates its own. Summary tables are rebuilt when they differ.
- **Notification:** success or failure goes to the PM2 log and the WhatsApp contacts of the imported database.

**If the card reports that the automatic restore also failed**, or the app died during an import (power cut, `pm2 restart`), the database may be half-imported. Restore the safety copy by hand with the app stopped, using the file name from the message or the newest `sebelum-impor-*` file:

```bash
pm2 stop sianok-parking
gunzip -c storage/backup-database/sebelum-impor-<db>-<YYYYMMDD-HHMMSS>.sql.gz | mariadb -u root -p <db>
pm2 start sianok-parking
```

The app recreates its triggers and rebuilds the summary tables when it starts.

### Summary tables (filled by triggers)

`tbl_pendapatan_harian`, `tbl_parkir_masuk_harian` and `tbl_parkir_keluar_harian` are derived from the transaction tables by triggers. Reports (Okupansi, Rekap Bulanan, dashboard revenue) read them instead of scanning a year of transactions. Never edit them by hand. At startup the app compares them with the transaction tables and rebuilds them when they differ; the full per-day comparison of the parkir tables runs 2 minutes after startup and logs `Rekap transaksi parkir dibangun ulang` when it had to fix something. The first start after the 1.1.1 update fills the parkir tables once (about 4 s for 365,000 transactions).


## Pages in a release (views.pak)

A release build has no `views/` folder. All pages (login, dashboard, kasir, payment, audit, installer, API docs, Manual Book) are packed into one compressed file, `views.pak`, so they cannot be opened or edited on the server. The SHA-256 fingerprint of the pack is built into `server.js` and `start.js`.

- A `views/` folder created by hand is ignored.
- If `views.pak` is changed or damaged, every page answers `500` with "Paket tampilan aplikasi rusak atau diubah", and the log shows `Paket tampilan views.pak tidak dapat dipakai`. The gate, payment and other APIs keep working. To fix it, extract `views.pak` (or the whole release) again from the official release archive and restart the app.
- To change a page, edit `views/` in the source and make a new build (`npm run build`).

When the app runs from source (`npm start`), pages are read from `views/` as usual.
