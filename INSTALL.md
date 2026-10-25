# Instalasi Sianok Parking (Ubuntu Server 22.04 / 24.04)

## Instalasi satu perintah

```bash
tar -xzf sianok-parking-<versi>-<tanggal>.tar.gz
cd sianok-parking
sudo bash setup.sh
```

Wizard hanya menanyakan:

| Pertanyaan | Bawaan |
|---|---|
| User layanan (non-root) | pemilik folder / user yang menjalankan sudo, atau `hybrid` (dibuat otomatis) |
| Port HTTP aplikasi | dari `.env`, atau 3003 |
| Port HTTPS bawaan aplikasi | dari `.env`, atau 3446 (`off` = tanpa HTTPS sendiri) |
| Nama database | dari `.env`, atau `db-sianok-parking` |
| Alamat publik | kosong (hanya jaringan lokal) |

Tanpa pertanyaan: `sudo bash setup.sh --yes` (opsi lain: `--help`).

Selebihnya otomatis. Setiap tahap tampil dengan status **SUCCESS / FAILED / SKIPPED / NEEDS ATTENTION**:

1. **Pemeriksaan server**: versi Ubuntu, CPU, RAM, disk, internet, folder aplikasi, `.env`, data foto, port, dan PM2 yang berjalan.
2. **Paket sistem (APT)**: `ffmpeg` (berisi ffprobe), `mariadb-server`, `mariadb-client`, `openssl`, `curl`, `xz-utils`, `ca-certificates`, `iproute2`, dan `procps`. Hanya yang belum ada yang dipasang. `build-essential` tidak dipasang karena modul native (`@napi-rs/canvas`, `esbuild`) berupa biner jadi.
3. **Node.js v26.12.1**:
   - Tarball resmi nodejs.org dipasang di `/usr/local/lib/nodejs` setelah SHA-256 diverifikasi.
   - Node lama milik aplikasi lain tidak diubah. Sianok Parking memakai Node 26 secara khusus lewat `HYBRID_PARKING_NODE`.
4. **PM2**: dipasang bila belum ada, berikut `pm2-logrotate` (20 MB per file, 14 file, dikompres).
5. **MariaDB**:
   - Layanan diaktifkan dan diset otomatis start.
   - Server yang baru dipasang diamankan: user anonim dan database `test` dihapus.
   - Server lama tidak diubah. Password root tidak diubah.
6. **Database dan user**:
   - Database dibuat bila belum ada.
   - User `sianok_parking`@localhost dibuat dengan password acak 48 karakter (`/dev/urandom`) dan hak hanya pada database itu.
   - Password disimpan di `.env` (mode 600) dan tidak pernah ditampilkan.
   - Bila `.env` sudah berisi kredensial yang valid, kredensial itu dipakai ulang.
7. **Port**: proses lain yang memakai port tidak dihentikan. Wizard meminta port lain.
8. **`.env`**:
   - File lama dibackup dulu ke `_backup/.env.bak-<waktu>`.
   - Hanya kunci yang kurang yang ditambahkan. API key, link SDK, dan nilai lain dipertahankan.
9. **Folder data**: `storage/` (foto kendaraan), `public/uploads`, `public/img`, dan `_backup` milik user layanan. Data lama tidak dipindah atau dihapus.
10. **FFmpeg/FFprobe** diuji sebagai user layanan: demuxer RTSP tersedia, snapshot JPEG berhasil dibuat lalu dibaca ulang dengan ffprobe. Ini sama dengan cara `gate.js` mengambil foto kamera.
11. **Dependency aplikasi**: modul native diuji dengan cara dimuat. Bila gagal atau tidak ada, dijalankan `npm ci --omit=dev` sesuai `package-lock.json`.
12. **Migrasi**:
    - Database yang sudah berisi data dibackup dulu ke `_backup/database/`.
    - Lalu `database.sql` diterapkan. Isinya hanya `CREATE … IF NOT EXISTS` dan data awal bila kosong.
    - Kolom tambahan dibuat aplikasi saat start. Tidak ada `DROP` atau reset.
13. **PM2**:
    - Aplikasi dijalankan sebagai user layanan (bukan root): `pm2 startOrReload ecosystem.config.cjs`.
    - Proses yang sudah ada di-reload, bukan diduplikasi.
    - `pm2 startup` membuat layanan systemd `pm2-<user>` agar aplikasi jalan lagi setelah reboot.
    - Tidak pernah memakai `pm2 delete all` atau `restart all`.
14. **Opsional**: izin tombol Restart/Shutdown server di Monitor Server (`--izinkan-restart-server`).
15. **Health check**, lalu ringkasan akhir.

Installer aman dijalankan ulang. Tahap yang sudah benar ditandai SKIPPED.

Exit code: `0` berhasil, `1` gagal, `2` berhasil dengan hal yang perlu diperhatikan.

Log installer: `/var/log/sianok-parking/setup-<waktu>.log` (mode 600, tanpa password).

## Perintah harian

```bash
sudo -u <user> pm2 status sianok-parking
sudo -u <user> pm2 reload sianok-parking      # restart tanpa jeda
sudo -u <user> pm2 logs sianok-parking
sudo bash scripts/health-check.sh             # cek kesehatan lengkap
sudo bash scripts/check-dependencies.sh       # cek server (hanya membaca)
sudo bash scripts/backup-database.sh          # backup ke _backup/database/
sudo bash scripts/kunci-kode.sh status        # kode terkunci? catatan akses aktif?
sudo bash scripts/kunci-kode.sh log           # siapa membaca / menyalin / mengubah kode (7 hari)
sudo bash scripts/update.sh <paket.tar.gz>    # update ke versi baru
```

Login awal pada database baru: `admin` / `admin123`. Segera ganti di menu Pengguna.

## Kunci kode & catatan akses

Langkah terakhir `setup.sh` mengunci file kode di folder rilis dengan atribut *immutable* (`chattr +i`): `server.js`, `start.js`, `laporan-worker.js`, `views.pak`, file konfigurasi & dokumentasi, serta folder `public/` (kecuali `public/uploads` dan `public/img`), `fonts/`, dan `scripts/`. File yang terkunci tidak bisa diedit, ditimpa, dihapus, atau di-rename oleh siapa pun, termasuk root, sebelum kuncinya dibuka.

Yang tetap bisa ditulis: `storage/` (foto, backup database, SSL), `public/uploads`, `public/img`, `_backup/`, `.env`, dan `node_modules/`.

`auditd` mencatat setiap perubahan kode, setiap pemakaian `chattr` (membuka kunci), dan setiap pembacaan atau penyalinan kode inti (`server.js`, `start.js`, `laporan-worker.js`, `views.pak`): user, waktu, dan program yang dipakai. Lihat dengan `sudo bash scripts/kunci-kode.sh log`. Pembacaan oleh aplikasi sendiri (saat start dan ekspor laporan) disembunyikan; tambahkan `--semua` untuk menampilkannya.

Keduanya tidak memperlambat aplikasi: kunci hanya diperiksa saat ada yang mencoba mengubah file, dan yang dicatat hanya akses ke file kode, bukan foto atau database.

- Buka kunci (mis. untuk update manual): `sudo bash scripts/kunci-kode.sh buka`. Kunci lagi: `sudo bash scripts/kunci-kode.sh kunci`, atau jalankan `sudo bash setup.sh --yes`.
- Tanpa kunci & catatan akses: `sudo bash setup.sh --tanpa-kunci`.
- Folder source (tanpa `views.pak`) tidak pernah dikunci.

## Health check

`scripts/health-check.sh` memeriksa hal berikut:

- **Runtime:** Node.js ≥ 26.12.1, npm, dan PM2.
- **Layanan:** MariaDB aktif.
- **FFmpeg/FFprobe:** keduanya berfungsi.
- **Modul aplikasi:** modul native dapat dimuat.
- **Konfigurasi:** `.env` ber-mode 600.
- **Database:** koneksi berhasil dan tabel inti ada.
- **Folder data:** bisa ditulis user layanan.
- **Proses PM2:** status `online` dan menjalankan folder ini.
- **Stabilitas:** tidak ada restart loop (jumlah restart diamati selama ±15 detik).
- **Port:** didengarkan oleh proses Sianok Parking.
- **Respons aplikasi:** `GET /api/health` mengembalikan `{"ok":true}` dan halaman login mengembalikan HTTP 200.
- **Log:** log error tanpa pesan kritis.

Tidak ada transaksi palsu, dan gate tidak pernah dibuka.

## Backup & pemulihan

Backup otomatis dibuat setiap kali `setup.sh` menemukan database yang sudah berisi data. Backup manual bisa dibuat dengan `scripts/backup-database.sh`.

- **Lokasi:** `_backup/database/<db>-<waktu>.sql.gz`, mode 600.
- **Isi:** satu snapshot konsisten, termasuk trigger dan routine, tanpa `CREATE DATABASE` / `USE`.
- **Retensi:** backup lama tidak pernah dihapus. Salin backup ke luar server secara berkala.

Pulihkan ke database terpisah dulu, periksa, baru dipakai:

```bash
sudo mariadb -e "CREATE DATABASE db_sianok_pulih CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
gunzip -c _backup/database/<file>.sql.gz | sudo mariadb db_sianok_pulih
sudo mariadb db_sianok_pulih -e "SELECT COUNT(*), SUM(total_bayar) FROM tbl_transaksi_pendapatan; SELECT SUM(total) FROM tbl_pendapatan_harian"
```

Kedua total harus sama. Setelah itu ada dua pilihan:

- Ganti `DB_NAME` di `.env` ke database pulihan, beri hak ke user aplikasi, lalu `pm2 reload sianok-parking`.
- Atau pulihkan file yang sama ke nama database produksi saat jam tutup.

```bash
sudo mariadb -e "GRANT ALL PRIVILEGES ON \`db_sianok_pulih\`.* TO 'sianok_parking'@'localhost', 'sianok_parking'@'127.0.0.1'"
```

## Rollback instalasi / update

- **`.env`:** kembalikan dengan `cp _backup/.env.bak-<waktu> .env && chmod 600 .env`.
- **Database:** pulihkan dari `_backup/database/` (lihat langkah di atas).
- **Update / versi aplikasi:** `sudo bash scripts/update.sh <paket-rilis.tar.gz>` (versi baru, atau versi sebelumnya untuk rollback). Skrip ini membuka kunci kode, mengekstrak paket ke folder yang sama tanpa menyentuh `storage/`, `public/uploads`, `public/img`, `_backup/`, dan `.env`, lalu menjalankan `sudo bash setup.sh --yes`, yang mengunci kode lagi.
- **Node.js:** versi lain tetap tersimpan di `/usr/local/lib/nodejs/`. Node bawaan server tidak pernah ditimpa.

## Jaringan & HTTPS

- MariaDB hanya untuk koneksi lokal (`127.0.0.1`). Installer memberi peringatan bila MariaDB mendengarkan di semua alamat, tetapi tidak mengubah konfigurasi atau firewall.
- Aplikasi punya HTTPS sendiri di port `HTTPS_PORT` (sertifikat self-signed di `storage/ssl`, atau `HTTPS_CERT`/`HTTPS_KEY`).
- Untuk akses publik, gunakan reverse proxy atau Cloudflare Tunnel yang sudah ada dengan target `http://127.0.0.1:<PORT>`, lalu isi `SITE_URL`. Installer tidak mengubah proxy atau tunnel.

## Halaman Instalasi lewat browser (cara lama)

Masih tersedia. `npm start` tanpa `.env` lengkap membuka halaman Instalasi di `http://<ip>:3003` dengan kode instalasi yang tampil di terminal. `setup.sh` memakai fungsi impor database yang sama (`node start.js --pasang-database`).
