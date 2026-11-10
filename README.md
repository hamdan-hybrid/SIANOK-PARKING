# Sianok Parking

Sistem parkir: gate masuk & keluar, kasir, member, dan laporan.

Instalasi cukup dengan **satu perintah: `sudo bash setup.sh`**. Node.js, MariaDB, PM2, dan FFmpeg dipasang otomatis. Anda **tidak perlu** memasang nvm atau Node.js sendiri, dan tidak perlu menjalankan `npm start`.

## Kebutuhan server

| | |
|---|---|
| Sistem operasi | Ubuntu Server 22.04 atau 24.04, 64-bit (x86_64; ARM64 juga bisa) |
| RAM | minimal 2 GB |
| Disk | minimal 5 GB kosong. Foto dan backup otomatis dipindah ke hardisk kedua bila ada. |
| Internet | dibutuhkan saat instalasi dan update |
| Akses | user yang bisa menjalankan `sudo` |

## Instalasi

**1. Unduh aplikasi**

```bash
sudo apt-get install -y git
sudo git clone --depth 1 https://github.com/hamdan-hybrid/SIANOK-PARKING.git /var/www/SIANOK-PARKING
```

**2. Jalankan setup**

```bash
cd /var/www/SIANOK-PARKING
sudo bash setup.sh
```

Setup menanyakan beberapa hal: user layanan, port, nama database, dan alamat publik. Semua pertanyaan sudah berisi jawaban bawaan, jadi cukup tekan **Enter**. Untuk instalasi tanpa pertanyaan sama sekali, pakai `sudo bash setup.sh --yes`.

Di akhir, setup menampilkan ringkasan setiap langkah (**SUCCESS / SKIPPED / NEEDS ATTENTION / FAILED**), alamat akses, dan perintah untuk mengelola aplikasi.

**3. Buka aplikasi**

- Alamat: `http://<ip-server>:3003` (port bawaan; HTTPS bawaan di port 3446).
- Login awal: **admin / admin123**. Segera ganti password di menu **Pengguna**.

Setup aman dijalankan ulang kapan saja. Langkah yang sudah benar dilewati, dan data maupun database tidak dihapus.

## Yang dikerjakan setup.sh

1. Memeriksa server: versi Ubuntu, RAM, disk, internet, dan port.
2. Memasang Node.js 26, PM2, MariaDB, dan FFmpeg. Yang sudah terpasang dilewati.
3. Membuat database dan user database dengan password acak, lalu menulis `.env`.
4. Menaruh folder foto dan backup (`storage/`) di hardisk terbesar (lihat bagian berikut).
5. Menjalankan aplikasi dengan PM2, dan menyalakannya lagi otomatis setiap server restart.
6. Menjalankan health check dan mengunci file kode.

## Foto & backup di hardisk terbesar

Foto kendaraan dan backup database harian disimpan di folder `storage/`. Bila server punya hardisk lain yang lebih besar dari hardisk sistem, setup memakainya secara otomatis:

| Kondisi hardisk lain | Yang dilakukan setup |
|---|---|
| Sudah terpasang (tercatat di `/etc/fstab`) | Langsung dipakai. |
| Belum terpasang, tetapi sudah ada isinya (ext4, NTFS bekas Windows, exFAT, xfs, btrfs) | Dipasang di `/mnt/data` **tanpa diformat**. Isi lamanya tetap ada. |
| Masih kosong (disk baru, belum diformat) | Setup bertanya dulu. Disk hanya diformat bila Anda mengetik `YA`. Mode `--yes` tidak pernah memformat. |

- Foto tersimpan di `/mnt/data/sianok-parking`, tetapi aplikasi tetap membacanya sebagai `storage/`.
- Lokasi dan sisa ruangnya tampil di ringkasan setup (baris *Folder storage*) dan di menu **Monitor Server**.
- Flashdisk dan hardisk USB tidak dipakai otomatis.

**Server lama yang fotonya masih di hardisk sistem.** Jalankan `sudo bash setup.sh` saat parkir sepi, lalu jawab `y` saat ditawari pindah. Aplikasi hanya berhenti beberapa detik di akhir penyalinan. Salinan lama disimpan di `_backup/storage-lama-<waktu>` sampai Anda menghapusnya. Tombol *Perbarui sistem* tidak memindahkan foto, tetapi akan mengingatkan Anda.

**Pilihan lain:**

- Tetap di hardisk sistem: `sudo bash setup.sh --tanpa-disk-data`
- Folder pilihan sendiri: `sudo bash setup.sh --disk-data /folder/di/hardisk/lain`

## Update

- **Dari aplikasi:** menu profil → **Monitor Server** → **Perbarui sistem** (khusus akun Owner).
- **Dari terminal:** `sudo bash /var/www/SIANOK-PARKING/scripts/perbarui-sistem.sh`

Database dibackup dulu sebelum migrasi. Foto, `.env`, dan backup tidak disentuh.

## Perintah berguna

Jalankan dari folder aplikasi. Ganti `<user>` dengan user layanan yang tampil di ringkasan setup.

```bash
cd /var/www/SIANOK-PARKING
sudo -u <user> pm2 status sianok-parking      # status aplikasi
sudo -u <user> pm2 logs sianok-parking        # log aplikasi
sudo -u <user> pm2 reload sianok-parking      # restart tanpa jeda
sudo bash scripts/health-check.sh             # cek kesehatan lengkap
sudo bash scripts/backup-database.sh          # backup database sekarang
```

## Dokumentasi

- [INSTALL.md](INSTALL.md): rincian setiap langkah instalasi, pemulihan database, dan rollback.
- [OPERATIONS.md](OPERATIONS.md): operasional harian (PM2, backup, tutup harian).
- [GATE-API.md](GATE-API.md): API untuk perangkat gate.
