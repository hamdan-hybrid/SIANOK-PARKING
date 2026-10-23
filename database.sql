-- Sianok Parking MariaDB schema
-- Requires MariaDB 10.5+.

CREATE DATABASE IF NOT EXISTS `db-sianok-parking`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE `db-sianok-parking`;

CREATE TABLE IF NOT EXISTS tbl_perusahaan (
  id_perusahaan BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  nama VARCHAR(160) NOT NULL,
  email VARCHAR(160) NOT NULL,
  phone VARCHAR(30) NOT NULL,
  alamat VARCHAR(255) NULL,
  payment_link VARCHAR(500) NULL,
  link_sdk_qris VARCHAR(500) NULL,
  link_sdk_uang_elektronik VARCHAR(500) NULL,
  wa_notif JSON NULL COMMENT 'Format: [{"nama":"Nama","nomor":"0822..."}]',
  wa_api_key VARCHAR(255) NULL COMMENT 'API key gateway WhatsApp (notifikasi login & tutup kasir)',
  thermal_footer VARCHAR(500) NULL,
  cetak_otomatis TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'Kasir mencetak struk parkir keluar otomatis',
  tiket_tampil_jenis TINYINT(1) NOT NULL DEFAULT 1 COMMENT 'Cetak jenis kendaraan di tiket masuk',
  metode_closing ENUM('global', 'auto') NOT NULL DEFAULT 'global',
  tanggal DATE NULL,
  logo VARCHAR(500) NULL,
  serial_number VARCHAR(100) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_perusahaan),
  UNIQUE KEY uq_perusahaan_email (email),
  UNIQUE KEY uq_perusahaan_serial (serial_number),
  KEY idx_perusahaan_nama (nama)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_pengguna (
  id_user BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  nama_lengkap VARCHAR(160) NOT NULL,
  alamat VARCHAR(255) NULL,
  phone VARCHAR(30) NULL,
  username VARCHAR(80) NOT NULL,
  password_pin VARCHAR(255) NOT NULL COMMENT 'Simpan hash password/PIN, jangan plaintext',
  hak_akses ENUM('Owner', 'Admin', 'Kasir', 'Svp', 'Audit') NOT NULL DEFAULT 'Kasir',
  akses_omset TINYINT UNSIGNED NOT NULL DEFAULT 100,
  closing ENUM('yes', 'no') NOT NULL DEFAULT 'no',
  id_interface JSON NULL COMMENT 'Kasir: daftar id perangkat Interface yang dilayani',
  api_key_hash CHAR(64) NULL COMMENT 'Audit: SHA-256 API key (kunci asli hanya ditampilkan sekali)',
  api_key_hint VARCHAR(12) NULL COMMENT 'Audit: 4 karakter terakhir API key',
  api_key_created_at DATETIME NULL,
  api_key_used_at DATETIME NULL,
  pref_bahasa VARCHAR(5) NULL COMMENT 'Preferensi bahasa antarmuka: id, en, nan (Hokkien)',
  pref_tema VARCHAR(5) NULL COMMENT 'Preferensi tema: light, dark',
  foto VARCHAR(500) NULL,
  status ENUM('Aktif', 'Nonaktif') NOT NULL DEFAULT 'Aktif',
  last_login_at DATETIME NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_user),
  UNIQUE KEY uq_pengguna_username (username),
  UNIQUE KEY uq_pengguna_api_key (api_key_hash),
  KEY idx_pengguna_status (status),
  CONSTRAINT chk_pengguna_akses_omset CHECK (akses_omset BETWEEN 1 AND 100)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS hp_sessions (
  token_hash CHAR(64) NOT NULL,
  csrf_hash CHAR(64) NOT NULL,
  id_user BIGINT UNSIGNED NOT NULL,
  expires_at DATETIME NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (token_hash),
  KEY idx_hp_sessions_expiry (expires_at),
  CONSTRAINT fk_hp_sessions_user FOREIGN KEY (id_user) REFERENCES tbl_pengguna (id_user) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_metode_bayar (
  id_metode BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  id_perusahaan BIGINT UNSIGNED NOT NULL,
  metode VARCHAR(80) NOT NULL,
  tampil_kasir TINYINT(1) NOT NULL DEFAULT 1,
  metode_code VARCHAR(40) NOT NULL,
  normal_balance ENUM('kredit', 'debit') NOT NULL DEFAULT 'debit',
  aktif TINYINT(1) NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_metode),
  UNIQUE KEY uq_metode_perusahaan_code (id_perusahaan, metode_code),
  KEY idx_metode_perusahaan (id_perusahaan),
  KEY idx_metode_kasir (id_perusahaan, tampil_kasir, aktif),
  CONSTRAINT fk_metode_perusahaan FOREIGN KEY (id_perusahaan)
    REFERENCES tbl_perusahaan (id_perusahaan)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_tarif (
  id_tarif BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  jenis_kendaraan VARCHAR(60) NOT NULL,
  ikon VARCHAR(40) NULL COMMENT 'Kunci ikon kendaraan',
  tipe_ceklis SET('Normal', 'Tiket Hilang', 'Manual Ticket') NOT NULL DEFAULT 'Normal' COMMENT 'Bisa lebih dari satu tipe',
  formula JSON NULL COMMENT 'Aturan hitung tarif berbasis durasi',
  tarif INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Tarif dasar / blok awal (rupiah)',
  tampil_kasir TINYINT(1) NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_tarif),
  UNIQUE KEY uq_tarif_kendaraan_tipe (jenis_kendaraan, tipe_ceklis)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_pengaturan_perangkat (
  id_perangkat BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  nama_perangkat VARCHAR(80) NOT NULL,
  api_key CHAR(32) NULL COMMENT 'Interface: id_gate untuk REST API gate',
  serial_number VARCHAR(64) NULL COMMENT 'Interface: serial number, dilaporkan perangkat lewat update-ip',
  wifi_ssid VARCHAR(32) NULL COMMENT 'Interface: SSID WiFi untuk config perangkat',
  wifi_password VARCHAR(63) NULL COMMENT 'Interface: password WiFi untuk config perangkat',
  jenis ENUM('Camera', 'Printer', 'Interface') NOT NULL,
  rtsp_url VARCHAR(500) NULL COMMENT 'Khusus Camera',
  ip_address VARCHAR(45) NULL COMMENT 'Printer & Interface',
  port SMALLINT UNSIGNED NULL COMMENT 'Port untuk cek status',
  id_printer BIGINT UNSIGNED NULL COMMENT 'Interface: printer terhubung',
  id_camera JSON NULL COMMENT 'Interface: daftar id camera terhubung',
  anpr_foto VARCHAR(255) NULL COMMENT 'ANPR: foto',
  nopol VARCHAR(20) NULL COMMENT 'ANPR: nomor polisi',
  status ENUM('online', 'offline', 'unknown') NOT NULL DEFAULT 'unknown',
  latensi_ms INT UNSIGNED NULL,
  terakhir_dicek DATETIME NULL,
  terakhir_online DATETIME NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_perangkat),
  UNIQUE KEY uq_perangkat_nama (nama_perangkat),
  UNIQUE KEY uq_perangkat_api_key (api_key),
  KEY idx_perangkat_jenis (jenis)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_parking_lot (
  id_lot BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  nama_lot VARCHAR(80) NOT NULL,
  kapasitas INT UNSIGNED NOT NULL DEFAULT 0,
  buka_24jam TINYINT(1) NOT NULL DEFAULT 1,
  jam_buka TIME NULL,
  jam_tutup TIME NULL,
  in_area INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Kendaraan di dalam area, diperbarui oleh gate',
  running_text VARCHAR(255) NULL,
  ip_display VARCHAR(45) NULL COMMENT 'IP parking display',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_lot),
  UNIQUE KEY uq_parking_lot_nama (nama_lot)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_member (
  id_member BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  kode_member VARCHAR(20) NULL,
  nama_member VARCHAR(120) NOT NULL,
  phone VARCHAR(30) NULL,
  alamat VARCHAR(255) NULL,
  rfid VARCHAR(64) NULL COMMENT 'Kartu RFID member',
  id_metode BIGINT UNSIGNED NULL COMMENT 'Metode bayar member (non-kasir, saldo normal kredit)',
  tanggal_mulai DATE NOT NULL,
  tanggal_berakhir DATE NOT NULL,
  status ENUM('Aktif', 'Nonaktif') NOT NULL DEFAULT 'Aktif',
  catatan VARCHAR(255) NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_member),
  UNIQUE KEY uq_member_kode (kode_member),
  UNIQUE KEY uq_member_rfid (rfid),
  KEY idx_member_berakhir (tanggal_berakhir),
  KEY idx_member_nama (nama_member),
  KEY idx_member_metode (id_metode),
  CONSTRAINT fk_member_metode FOREIGN KEY (id_metode) REFERENCES tbl_metode_bayar (id_metode) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_member_kendaraan (
  id_kendaraan BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  id_member BIGINT UNSIGNED NOT NULL,
  id_tarif BIGINT UNSIGNED NULL COMMENT 'Tarif yang dipakai (menentukan jenis kendaraan)',
  nopol VARCHAR(15) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id_kendaraan),
  UNIQUE KEY uq_member_nopol (nopol),
  KEY idx_member_kendaraan_member (id_member),
  CONSTRAINT fk_member_kendaraan_member FOREIGN KEY (id_member) REFERENCES tbl_member (id_member) ON DELETE CASCADE,
  CONSTRAINT fk_member_kendaraan_tarif FOREIGN KEY (id_tarif) REFERENCES tbl_tarif (id_tarif) ON DELETE SET NULL
) ENGINE=InnoDB;

-- Seed minimal untuk instalasi baru.
INSERT INTO tbl_perusahaan (nama, email, phone, wa_notif, thermal_footer, metode_closing, serial_number)
SELECT 'PT Azka Maju Bersama', 'operasional@hybridsys.id', '0822-7354-9791', JSON_ARRAY(JSON_OBJECT('nama', 'Sianok Parking', 'nomor', '0822-7354-9791')), 'Terima kasih telah menggunakan layanan kami.', 'global', 'HSS-001'
-- Hanya bila belum ada data perusahaan (serial_number diganti kode instalasi saat dipasang lewat halaman Instalasi).
WHERE NOT EXISTS (SELECT 1 FROM tbl_perusahaan);

INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'Tunai', 1, 'CASH', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE metode_code = 'CASH');

INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'QRIS', 1, 'QRIS', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE metode_code = 'QRIS');

-- Kasir memilih "Kartu Uang Elektronik" (popup tempel kartu, SDK Uang Elektronik); pendapatan dicatat sesuai jenis kartu
-- (awalan nomor kartu) dengan metode di bawahnya, yang tidak tampil di kasir.
INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'Kartu Uang Elektronik', 1, 'KARTU', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE metode_code = 'KARTU');

-- Metode gabungan: satu popup kasir menampilkan QRIS sekaligus menunggu kartu ditempel (kedua link SDK diisi);
-- pendapatan dicatat sesuai channel yang dipakai (QRIS, atau jenis kartu).
INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'QRIS + Uang Elektronik', 1, 'QRIS_EMONEY', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE metode_code = 'QRIS_EMONEY');
INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'E-money Mandiri', 0, 'EMONEY', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE REPLACE(metode_code, '-', '') = 'EMONEY');

INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'BRIZZI BRI', 0, 'BRIZZI', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE metode_code = 'BRIZZI');

INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'TapCash BNI', 0, 'TAPCASH', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE metode_code = 'TAPCASH');

INSERT INTO tbl_metode_bayar (id_perusahaan, metode, tampil_kasir, metode_code, normal_balance)
SELECT id_perusahaan, 'Flazz BCA', 0, 'FLAZZ', 'debit'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (SELECT 1 FROM tbl_metode_bayar WHERE metode_code = 'FLAZZ');

-- Contoh perangkat (instalasi baru saja: data perusahaan bawaan dan tabel perangkat masih kosong). Ubah IP / RTSP di menu
-- Perangkat sesuai lapangan, atau hapus. PM1 = pintu masuk 1, PK2 = pintu keluar 2. api_key Interface dibuat server saat start.
SET @hp_contoh_perangkat = (SELECT COUNT(*) = 0 FROM tbl_pengaturan_perangkat)
  AND EXISTS (SELECT 1 FROM tbl_perusahaan WHERE serial_number = 'HSS-001');

INSERT INTO tbl_pengaturan_perangkat (nama_perangkat, jenis, rtsp_url, ip_address, port)
SELECT nama, jenis, rtsp, ip, port FROM (
  SELECT 'PM1 Printer' AS nama, 'Printer' AS jenis, NULL AS rtsp, '192.168.1.101' AS ip, 9100 AS port
  UNION ALL SELECT 'PK2 Printer', 'Printer', NULL, '192.168.1.102', 9100
  UNION ALL SELECT 'PM1 Camera', 'Camera', 'rtsp://admin:password@192.168.1.111:554/stream1', NULL, NULL
  UNION ALL SELECT 'PK2 Camera', 'Camera', 'rtsp://admin:password@192.168.1.112:554/stream1', NULL, NULL
) contoh
WHERE @hp_contoh_perangkat;

INSERT INTO tbl_pengaturan_perangkat (nama_perangkat, jenis, ip_address, port, id_printer, id_camera)
SELECT nama, 'Interface', ip, 80,
  (SELECT id_perangkat FROM tbl_pengaturan_perangkat WHERE nama_perangkat = printer),
  JSON_ARRAY((SELECT id_perangkat FROM tbl_pengaturan_perangkat WHERE nama_perangkat = camera))
FROM (
  SELECT 'PM1' AS nama, '192.168.1.121' AS ip, 'PM1 Printer' AS printer, 'PM1 Camera' AS camera
  UNION ALL SELECT 'PK2', '192.168.1.122', 'PK2 Printer', 'PK2 Camera'
) contoh
WHERE @hp_contoh_perangkat;

INSERT INTO tbl_pengguna (nama_lengkap, alamat, phone, username, password_pin, hak_akses, akses_omset, closing, status)
SELECT 'Administrator Owner', NULL, phone, 'admin', '$2b$12$MDBglo27ypjbjWukVo71.OfKalDLOjUJtQ5g0LUKOdKQhStk18xxa', 'Owner', 100, 'yes', 'Aktif'
FROM tbl_perusahaan
WHERE serial_number = 'HSS-001'
  AND NOT EXISTS (
    SELECT 1 FROM tbl_pengguna
    WHERE username = 'admin'
  );

CREATE TABLE IF NOT EXISTS tbl_transaksi_pendapatan (
  id_trx BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tanggal_buku DATE NOT NULL COMMENT 'Diambil dari tbl_perusahaan.tanggal saat input',
  jam TIME NOT NULL,
  id_kasir BIGINT UNSIGNED NULL COMMENT 'tbl_pengguna.id_user yang menginput',
  jenis_pendapatan ENUM('Parkir', 'Tiket Hilang', 'Tiket Manual', 'Langganan', 'Penggantian Kartu', 'Denda', 'Lainnya') NOT NULL,
  id_member BIGINT UNSIGNED NULL COMMENT 'Diisi untuk pendapatan Langganan',
  id_transaksi_parkir BIGINT UNSIGNED NULL COMMENT 'Diisi untuk pendapatan Parkir',
  jenis_kendaraan VARCHAR(120) NULL COMMENT 'Parkir: satu jenis; Langganan: dipisah koma jika lebih dari satu',
  nopol VARCHAR(255) NULL COMMENT 'Parkir: satu nopol; Langganan: dipisah koma jika lebih dari satu',
  total_bayar DECIMAL(15,2) NOT NULL,
  id_metode BIGINT UNSIGNED NULL COMMENT 'Metode bayar (tbl_metode_bayar)',
  metode VARCHAR(40) NULL COMMENT 'tbl_metode_bayar.metode_code saat transaksi',
  no_referensi VARCHAR(64) NULL,
  uraian VARCHAR(255) NULL,
  json_transaksi JSON NULL COMMENT 'Snapshot data saat transaksi (pelanggan, kendaraan, metode, kasir)',
  tgl_input TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id_trx),
  KEY idx_pendapatan_tanggal (tanggal_buku),
  KEY idx_pendapatan_urut (tanggal_buku, jam, id_trx),
  KEY idx_pendapatan_ringkas (tanggal_buku, jenis_pendapatan, id_metode, total_bayar),
  KEY idx_pendapatan_jenis (jenis_pendapatan, tanggal_buku),
  KEY idx_pendapatan_member (id_member),
  KEY idx_pendapatan_kasir (id_kasir),
  KEY idx_pendapatan_metode (id_metode),
  KEY idx_pendapatan_kode_metode (metode, tanggal_buku),
  KEY idx_pendapatan_kendaraan (jenis_kendaraan, tanggal_buku),
  KEY idx_pendapatan_nopol (nopol),
  KEY idx_pendapatan_referensi (no_referensi),
  KEY idx_pendapatan_parkir (id_transaksi_parkir),
  CONSTRAINT fk_pendapatan_kasir FOREIGN KEY (id_kasir) REFERENCES tbl_pengguna (id_user) ON DELETE SET NULL,
  CONSTRAINT fk_pendapatan_member FOREIGN KEY (id_member) REFERENCES tbl_member (id_member) ON DELETE SET NULL,
  CONSTRAINT fk_pendapatan_metode FOREIGN KEY (id_metode) REFERENCES tbl_metode_bayar (id_metode) ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tbl_pengeluaran (
  id_pengeluaran BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tgl_buku DATE NOT NULL,
  kategori VARCHAR(60) NOT NULL,
  berita VARCHAR(255) NOT NULL COMMENT 'Keterangan pengeluaran',
  nominal DECIMAL(15,2) NOT NULL,
  id_kasir BIGINT UNSIGNED NULL COMMENT 'tbl_pengguna.id_user yang menginput',
  lampiran VARCHAR(120) NULL COMMENT 'Nama file di storage/pengeluaran',
  lampiran_nama VARCHAR(255) NULL COMMENT 'Nama file asli',
  lampiran_tipe VARCHAR(40) NULL,
  lampiran_ukuran INT UNSIGNED NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id_pengeluaran),
  KEY idx_pengeluaran_tanggal (tgl_buku, id_pengeluaran),
  KEY idx_pengeluaran_kategori (kategori, tgl_buku),
  KEY idx_pengeluaran_ringkas (tgl_buku, kategori, nominal),
  KEY idx_pengeluaran_kasir (id_kasir),
  CONSTRAINT fk_pengeluaran_kasir FOREIGN KEY (id_kasir) REFERENCES tbl_pengguna (id_user) ON DELETE SET NULL
) ENGINE=InnoDB;

-- Rekap harian pendapatan, dijaga trigger (server juga membuatnya otomatis saat start).
CREATE TABLE IF NOT EXISTS tbl_pendapatan_harian (
  tanggal_buku DATE NOT NULL,
  jenis_pendapatan VARCHAR(20) NOT NULL COMMENT 'Sengaja VARCHAR: jenis baru di tabel transaksi tidak membuat trigger gagal',
  id_metode BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0 = tanpa metode',
  jumlah INT NOT NULL DEFAULT 0,
  total DECIMAL(18,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (tanggal_buku, jenis_pendapatan, id_metode)
) ENGINE=InnoDB COMMENT='Rekap harian tbl_transaksi_pendapatan, diperbarui oleh trigger';

DELIMITER $$
CREATE TRIGGER IF NOT EXISTS trg_pendapatan_harian_ins AFTER INSERT ON tbl_transaksi_pendapatan FOR EACH ROW INSERT INTO tbl_pendapatan_harian (tanggal_buku, jenis_pendapatan, id_metode, jumlah, total)
    VALUES (NEW.tanggal_buku, NEW.jenis_pendapatan, COALESCE(NEW.id_metode, 0), 1, NEW.total_bayar)
    ON DUPLICATE KEY UPDATE jumlah = jumlah + 1, total = total + NEW.total_bayar;$$
CREATE TRIGGER IF NOT EXISTS trg_pendapatan_harian_del AFTER DELETE ON tbl_transaksi_pendapatan FOR EACH ROW UPDATE tbl_pendapatan_harian SET jumlah = jumlah - 1, total = total - OLD.total_bayar
    WHERE tanggal_buku = OLD.tanggal_buku AND jenis_pendapatan = OLD.jenis_pendapatan AND id_metode = COALESCE(OLD.id_metode, 0);$$
CREATE TRIGGER IF NOT EXISTS trg_pendapatan_harian_upd AFTER UPDATE ON tbl_transaksi_pendapatan FOR EACH ROW BEGIN
    IF NOT (OLD.tanggal_buku <=> NEW.tanggal_buku AND OLD.jenis_pendapatan <=> NEW.jenis_pendapatan AND OLD.id_metode <=> NEW.id_metode AND OLD.total_bayar <=> NEW.total_bayar) THEN
      UPDATE tbl_pendapatan_harian SET jumlah = jumlah - 1, total = total - OLD.total_bayar
        WHERE tanggal_buku = OLD.tanggal_buku AND jenis_pendapatan = OLD.jenis_pendapatan AND id_metode = COALESCE(OLD.id_metode, 0);
      INSERT INTO tbl_pendapatan_harian (tanggal_buku, jenis_pendapatan, id_metode, jumlah, total)
        VALUES (NEW.tanggal_buku, NEW.jenis_pendapatan, COALESCE(NEW.id_metode, 0), 1, NEW.total_bayar)
        ON DUPLICATE KEY UPDATE jumlah = jumlah + 1, total = total + NEW.total_bayar;
    END IF;
  END$$
DELIMITER ;

CREATE TABLE IF NOT EXISTS tbl_transaksi_parkir (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  no_tiket VARCHAR(50) NULL COMMENT 'Nomor tiket',
  id_member BIGINT UNSIGNED NULL COMMENT 'ID member',
  jenis_kendaraan VARCHAR(20) NULL COMMENT 'motor / mobil',
  nopol VARCHAR(20) NULL COMMENT 'Nomor polisi',
  gate_masuk VARCHAR(100) NULL COMMENT 'Nama gate masuk',
  id_gate_masuk BIGINT UNSIGNED NULL COMMENT 'ID gate masuk',
  tgl_masuk DATE NULL COMMENT 'Tanggal masuk',
  jam_masuk TIME NULL COMMENT 'Jam masuk',
  foto_masuk JSON NULL COMMENT 'Foto beberapa kamera',
  anpr_masuk VARCHAR(20) NULL COMMENT 'Hasil ANPR masuk',
  metode_masuk VARCHAR(20) NULL COMMENT 'tiket / member / qr / anpr / manual',
  gate_keluar VARCHAR(100) NULL COMMENT 'Nama gate keluar',
  id_gate_keluar BIGINT UNSIGNED NULL COMMENT 'ID gate keluar',
  tgl_keluar DATE NULL COMMENT 'Tanggal keluar',
  jam_keluar TIME NULL COMMENT 'Jam keluar',
  tanggal_buku DATE NULL COMMENT 'Tanggal buku saat dibayar (tbl_perusahaan.tanggal)',
  foto_keluar JSON NULL COMMENT 'Foto beberapa kamera',
  anpr_keluar VARCHAR(20) NULL COMMENT 'Hasil ANPR keluar',
  metode_keluar VARCHAR(20) NULL COMMENT 'Metode keluar',
  id_kasir_keluar BIGINT UNSIGNED NULL COMMENT 'Kasir yang memproses keluar (tbl_pengguna.id_user)',
  durasi_parkir INT NULL COMMENT 'Durasi dalam menit',
  id_tarif BIGINT UNSIGNED NULL COMMENT 'ID tarif',
  tarif DECIMAL(15,2) NOT NULL DEFAULT 0 COMMENT 'Tarif parkir',
  diskon DECIMAL(15,2) NOT NULL DEFAULT 0 COMMENT 'Diskon',
  total_bayar DECIMAL(15,2) NOT NULL DEFAULT 0 COMMENT 'Total pembayaran',
  metode_bayar VARCHAR(20) NULL COMMENT 'cash / qris / member',
  keterangan JSON NULL COMMENT 'Tiket Hilang / Manual: data pengemudi, waktu masuk input, denda',
  status VARCHAR(20) NOT NULL DEFAULT 'in' COMMENT 'in = masih parkir, paid = sudah keluar & lunas, cancel = dibatalkan',
  tgl_update_status DATETIME NULL COMMENT 'Waktu update status',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Waktu transaksi dibuat',
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Waktu terakhir diubah',
  PRIMARY KEY (id),
  UNIQUE KEY uq_parkir_tiket (no_tiket),
  KEY idx_parkir_masuk (tgl_masuk, jam_masuk),
  KEY idx_parkir_keluar (tgl_keluar, jam_keluar),
  KEY idx_parkir_status_masuk (status, tgl_masuk, jam_masuk),
  KEY idx_parkir_status_update (status, tgl_update_status),
  KEY idx_parkir_status_buku (status, tanggal_buku),
  KEY idx_parkir_nopol (nopol),
  KEY idx_parkir_member (id_member)
) ENGINE=InnoDB COMMENT='Transaksi masuk/keluar kendaraan dari sistem gate';

CREATE TABLE IF NOT EXISTS tbl_bantuan_gate (
  id_bantuan BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  id_gate BIGINT UNSIGNED NULL COMMENT 'ID perangkat Interface (tbl_pengaturan_perangkat.id_perangkat)',
  nama_gate VARCHAR(100) NULL COMMENT 'Nama gate saat bantuan diminta',
  tgl_bantuan DATE NOT NULL COMMENT 'Tanggal bantuan diminta',
  jam_bantuan TIME NOT NULL COMMENT 'Jam bantuan diminta',
  foto JSON NULL COMMENT 'Foto beberapa kamera Interface',
  ip_pengirim VARCHAR(45) NULL COMMENT 'IP Interface pengirim',
  wa_terkirim INT NOT NULL DEFAULT 0 COMMENT 'Jumlah notifikasi WhatsApp terkirim',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Waktu dibuat',
  PRIMARY KEY (id_bantuan),
  KEY idx_bantuan_waktu (tgl_bantuan, jam_bantuan),
  KEY idx_bantuan_gate (id_gate)
) ENGINE=InnoDB COMMENT='Riwayat permintaan bantuan dari tombol gate';

CREATE TABLE IF NOT EXISTS tbl_closing (
  id_closing BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  jenis ENUM('shift', 'global') NOT NULL,
  tanggal_buku DATE NOT NULL COMMENT 'Tanggal buku yang ditutup',
  id_kasir BIGINT UNSIGNED NULL COMMENT 'Kasir yang melakukan closing',
  id_penyetuju BIGINT UNSIGNED NULL COMMENT 'SPV (hak akses Svp) yang memasukkan password',
  id_trx_awal BIGINT UNSIGNED NULL COMMENT 'id_trx pendapatan pertama yang tercakup',
  id_trx_akhir BIGINT UNSIGNED NULL COMMENT 'id_trx pendapatan terakhir yang tercakup',
  jumlah_transaksi INT UNSIGNED NOT NULL DEFAULT 0,
  total_pendapatan DECIMAL(15,2) NOT NULL DEFAULT 0,
  tunai_sistem DECIMAL(15,2) NOT NULL DEFAULT 0 COMMENT 'Tunai menurut sistem',
  tunai_input DECIMAL(15,2) NOT NULL DEFAULT 0 COMMENT 'Tunai fisik yang diinput kasir',
  selisih DECIMAL(15,2) NOT NULL DEFAULT 0 COMMENT 'tunai_input - tunai_sistem',
  in_area INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Kendaraan di area saat closing',
  rincian JSON NULL COMMENT 'Per metode bayar: nama, kode, jumlah, total',
  rincian_kendaraan JSON NULL COMMENT 'Per jenis kendaraan: nama, jumlah',
  waktu DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id_closing),
  KEY idx_closing_buku (tanggal_buku, jenis),
  KEY idx_closing_kasir (id_kasir, tanggal_buku),
  CONSTRAINT fk_closing_kasir FOREIGN KEY (id_kasir) REFERENCES tbl_pengguna (id_user) ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Closing shift (per kasir) dan closing global (tutup tanggal buku)';
