# REST API Gate

Semua **GET**, tanpa login. Hanya dari jaringan lokal lewat IP server (bukan domain), selain itu `Access denied`.
`KEY` = API key Interface (menu Perangkat, tombol 🔑).

## Kendaraan masuk

```
GET http://SERVER:3003/api/gate/masuk?id_gate=KEY&jenis_kendaraan=motor&rfid_member=&metode_masuk=tiket
```

- `metode_masuk`: `tiket` (default), `member`, `qr`, `anpr`, `manual`. Bila `rfid_member` diisi, otomatis `member`.
- Member: satu kartu boleh dipakai sebanyak kendaraan terdaftarnya (2 kendaraan = 2 di area bersamaan). No. tiket kendaraan pertama = nomor kartu RFID, berikutnya nomor kartu + `-2`, `-3`, …. Kendaraan dicocokkan lewat `jenis_kendaraan` ke kendaraan terdaftar yang belum di area. Kartu yang terbaca ulang dalam 10 detik ditolak (dianggap kendaraan yang sama).
- Proses: simpan (no. tiket 10 digit acak; member: lihat di atas) → cetak struk (tiket) + server buka gate (`GET http://<IP Interface>/open-gate/?sn=<serial number>`); foto camera diambil di latar belakang (±2 detik).
- Berhasil: `{"status":true,"no_tiket":"6943224415","gate_dibuka":true,...}`
- Gagal: `{"status":false,"pesan":"..."}`. Member: 409 `NAMA masih tercatat di area` (1 kendaraan) / `NAMA masih tercatat di area (2 dari 2 kendaraan)` / `Kartu NAMA baru saja dipakai masuk` / `NAMA sedang diproses masuk`.

## Bantuan (tombol bantuan di gate)

```
GET http://SERVER:3003/api/gate/bantuan?id_gate=KEY
```

- Proses: simpan riwayat ke `tbl_bantuan_gate` → foto semua camera Interface (`storage/parkir/<tanggal>/bantuan-<id>-<camera>.jpg`, latar belakang) → notifikasi WhatsApp ke semua nomor di menu Perusahaan.
- Ditekan lagi dari gate yang sama dalam 30 detik tidak dicatat ulang (`"diulang":true`).
- Berhasil: `{"status":true,"pesan":"Bantuan diminta, petugas segera datang","id_bantuan":12,"gate":"Gate Masuk 1","foto_diproses":1}`
- Gagal: `{"status":false,"pesan":"..."}`

## Akses member ANPR

```
GET http://SERVER:3003/api/gate/akses_member_anpr?id_gate=KEY&nopol=BK1234AB
```

- `nopol`: hasil baca plat; huruf besar, spasi & tanda baca diabaikan. Dicocokkan ke kendaraan langganan (menu Langganan).
- Syarat member: status Aktif, masa berlaku mencakup hari ini, nopol ini belum tercatat di area, kendaraan member di area belum mencapai jumlah kendaraan terdaftar, jenis kendaraan (tarif) sudah diatur.
- Proses sama dengan kendaraan masuk member: dicatat masuk di gate ini (`metode_masuk = anpr`, `anpr_masuk` = nopol), no. tiket = nomor kartu RFID atau nomor kartu + `-2`, `-3`, … bila kendaraan lain member ini sudah di area (tanpa RFID: 10 digit acak), server buka gate, foto di latar belakang.
- Berhasil: `{"status":true,"pesan":"Selamat datang, NAMA","no_tiket":"...","metode_masuk":"anpr","member":"NAMA","nopol":"BK1234AB","gate_dibuka":true,...}`
- Gagal: 400 `nopol wajib diisi` · 404 `Nopol X bukan kendaraan member` · 403 `Langganan NAMA tidak aktif (...)` · 409 `NAMA (NOPOL) masih tercatat di area` / `NAMA masih tercatat di area (2 dari 2 kendaraan)` / `Jenis kendaraan X belum diatur di data langganan`.

## Kendaraan keluar member (tap kartu di gate keluar)

```
GET http://SERVER:3003/api/gate/keluar?id_gate=KEY&rfid_member=04A1B2C3
```

- Server memotret semua camera Interface (jadi foto keluar transaksi) dan membaca nopol dari camera pertama dengan Gemini (`GEMINI_API_KEY`).
- Langsung keluar bila langganan Aktif, nopol terbaca = kendaraan member, dan kendaraannya tercatat di area: transaksi ditutup (Rp 0, `metode_keluar = member`, `anpr_keluar` = nopol, kasir kosong) lalu server membuka gate → `{"status":true,"pesan":"Sampai jumpa, NAMA","no_tiket":"...","nopol":"BA5144AZ","gate_dibuka":true}`.
- Selain itu (nopol tidak terbaca / bukan kendaraan member / tidak cocok dengan kendaraan di area / langganan tidak aktif) → HTTP 202 `{"status":false,"menunggu":true,"pesan":"Menunggu persetujuan kasir","alasan":"..."}`. Permintaan tampil di kasir yang Interface-nya gate ini (gate tanpa kasir → semua kasir); gate dibuka setelah kasir menekan Izinkan, transaksi atas nama kasir itu. Berlaku 10 menit, tap ulang mengganti permintaan lama.
- Gagal: 400 `rfid_member wajib diisi` · 404 `Kartu RFID tidak terdaftar` / `NAMA tidak tercatat di area` · 409 `NAMA sedang diproses keluar` / `NAMA (NOPOL) baru saja keluar` (tap ulang ≤ 60 detik setelah keluar).
- Baca nopol ±2–7 detik: timeout HTTP Interface minimal 15 detik.

## Capture ANPR

```
GET http://SERVER:3003/api/gate/capture?id_gate=KEY
```

- Dibalas segera `{"status":true}`; foto diambil di latar belakang dari camera pertama yang terhubung ke Interface.
- Foto disimpan di `storage/GateAnpr/<id perangkat>-<YYYYMMDDHHmmss>.jpg`; path (`GateAnpr/...`) ditulis ke `tbl_pengaturan_perangkat.anpr_foto` dan `nopol` diisi `ANPR`.
- Gagal (id_gate salah / IP tidak cocok): `{"status":false,"pesan":"..."}`. Gagal ambil foto hanya dicatat di log server.

## Update IP (DHCP)

```
GET http://SERVER:3003/api/gate/update-ip?apikey=KEY&ipaddrs=192.168.18.30:80&sn=SERIAL123
```

- `ipaddrs`: `IP` atau `IP:port`; kosong = IP pengirim.
- `sn` (opsional): serial number Interface, maks 64 karakter (huruf, angka, `. _ : - /`). Disimpan dan tampil di kartu perangkat; kosong = nilai lama dibiarkan.

## .env (opsional)

- `GATE_OPEN_PATH=/open-gate/` : path buka gate di Interface (default seperti ini; `?sn=` diisi serial number Interface).
- `GATE_LOCAL_ONLY=off` : matikan pembatasan jaringan lokal.
- `GATE_FRAME_CACHE=on` : simpan frame camera terus-menerus (foto instan, tapi ±11% CPU per camera).
- `GEMINI_API_KEY=...` : wajib untuk member keluar (baca nopol). Kosong = semua tap keluar diteruskan ke kasir.
- `GEMINI_MODEL=gemini-3.1-flash-lite`, `GEMINI_MODEL_CADANGAN=gemini-3.5-flash-lite` (dipakai bila model utama sibuk / timeout; kosong = tanpa cadangan), `GEMINI_THINKING=minimal`, `GEMINI_TIMEOUT=12` (detik), `PLAT_DAERAH=BA` (kode wilayah paling umum).
