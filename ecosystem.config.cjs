module.exports = {
  apps: [{
    name: 'sianok-parking',
    // start.js membaca .env sendiri; bila .env belum lengkap tampil halaman Instalasi.
    script: './start.js',
    // setup.sh mengisi HYBRID_PARKING_NODE bila Node.js untuk Sianok Parking dipasang terpisah dari node bawaan server.
    interpreter: process.env.HYBRID_PARKING_NODE || 'node',
    // Satu proses: notifikasi kendaraan di area (SSE), cache, dan batas percobaan PIN/password disimpan di memori proses.
    // Lebih dari satu instance membuat data itu terpecah per proses. Mode cluster tetap dipakai agar `pm2 reload` tanpa jeda.
    instances: 1,
    exec_mode: 'cluster',
    // Error / crash → otomatis jalan lagi. Jeda restart naik bertahap (2 dtk s/d 15 dtk) bila error berulang,
    // kembali normal setelah proses stabil; batas restart dibuat besar agar tidak berhenti permanen.
    autorestart: true,
    exp_backoff_restart_delay: 2000,
    min_uptime: '10s',
    max_restarts: 1000,
    watch: false,
    // Batas pengaman bila memori bocor. Pemakaian normal 150–250 MB (saat ramai: foto, laporan, CCTV); 300M terlalu dekat
    // sehingga restart (kasir & gate terputus sebentar) bisa terjadi di jam sibuk. Dicek PM2 tiap 30 detik.
    max_memory_restart: '500M',
    kill_timeout: 10000,
    listen_timeout: 10000,
    env: { NODE_ENV: 'production' },
  }],
};
