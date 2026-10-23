(() => {
  const root = document.querySelector('.hp-home');
  if (!root) return;

  // Data dari GET /api/dashboard. Pendapatan memakai tanggal buku, arus kendaraan memakai hari kalender.
  let data = null;
  let loading = false;
  let lastProbe = 0;
  const REFRESH_MS = 60_000;
  const PROBE_MS = 120_000;

  const PAY_COLORS = ['#0b2cc0', '#0088dd', '#1a9b62', '#eb6834', '#7c5cdb', '#c98500'];
  // Warna grafik lewat variabel CSS (--hp-c-<hex>) agar tema gelap bisa memakai versi yang lebih terang (theme-dark-extra.css).
  const warna = hex => (/^#[0-9a-f]{6}$/i.test(hex) ? `var(--hp-c-${hex.slice(1).toLowerCase()}, ${hex})` : hex);
  const deviceIcon = { Interface: 'ti-device-desktop', Camera: 'ti-camera', Printer: 'ti-printer' };
  const statusText = { online: ['Online', 'ti-circle-check', 'good'], offline: ['Offline', 'ti-circle-x', 'bad'], unknown: ['Belum dicek', 'ti-help-circle', 'unknown'] };
  const rupiah = value => 'Rp ' + Math.round(value).toLocaleString('id-ID');
  const number = value => Number(value || 0).toLocaleString('id-ID');
  const escapeHtml = value => String(value ?? '').replace(/[&<>'"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[c]));
  const $ = selector => root.querySelector(selector);
  const capital = value => String(value || '').replace(/^\w/, c => c.toUpperCase());
  const isoDate = iso => new Date(`${iso}T00:00:00`);
  const longDate = iso => isoDate(iso).toLocaleDateString('id-ID', { day: 'numeric', month: 'long', year: 'numeric' });
  const duration = minutes => {
    if (minutes === null || minutes === undefined) return '-';
    const total = Math.max(0, Math.round(minutes));
    const days = Math.floor(total / 1440), hours = Math.floor(total % 1440 / 60), mins = total % 60;
    if (days) return `${days}h ${hours}j`;
    return hours ? `${hours}j ${String(mins).padStart(2, '0')}m` : `${mins}m`;
  };
  const percentChange = (now, before) => before ? (now - before) / before * 100 : null;
  const deltaPill = delta => {
    if (delta === null) return '';
    const up = delta >= 0;
    return `<span class="hp-delta ${up ? 'hp-delta-up' : 'hp-delta-down'}" title="Dibanding kemarin"><i class="ti ${up ? 'ti-trending-up' : 'ti-trending-down'}"></i>${up ? '+' : ''}${delta.toLocaleString('id-ID', { maximumFractionDigits: 1 })}%</span>`;
  };

  function renderHeader() {
    const sameDay = data.tanggal_buku === data.hari_ini;
    $('[data-home-date]').textContent = isoDate(data.hari_ini).toLocaleDateString('id-ID', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
    const book = $('[data-home-book]');
    book.hidden = sameDay;
    book.textContent = ` · Tanggal buku ${longDate(data.tanggal_buku)}`;
    book.title = 'Pendapatan dan metode bayar dihitung per tanggal buku (menu Perusahaan)';
    $('[data-home-updated]').textContent = `Diperbarui ${new Date().toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' })}`;

    const offline = data.perangkat.filter(device => device.status === 'offline').length;
    const unknown = data.perangkat.filter(device => device.status === 'unknown').length;
    const chip = $('[data-home-status]');
    chip.classList.toggle('is-bad', offline > 0);
    chip.classList.toggle('is-warn', !offline && unknown > 0);
    chip.innerHTML = `<i></i> ${!data.perangkat.length ? 'Belum ada perangkat' : offline ? `${offline} perangkat offline` : unknown ? `${unknown} perangkat belum dicek` : 'Semua perangkat online'}`;
  }

  // Grafik garis kecil (SVG) di dalam kartu; tidak memerlukan ApexCharts.
  function sparkline(values, color) {
    if (values.length < 2 || !values.some(Boolean)) return '<span class="hp-spark hp-spark-empty"></span>';
    const width = 120, height = 36, min = Math.min(...values), range = Math.max(...values) - min || 1;
    const points = values.map((value, index) => [index / (values.length - 1) * width, height - 3 - (value - min) / range * (height - 6)]);
    const line = points.map(([x, y], index) => `${index ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`).join(' ');
    const id = `hp-spark-${color.slice(1)}`;
    return `<svg class="hp-spark" viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" aria-hidden="true">
      <defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color:${warna(color)}" stop-opacity=".22"/><stop offset="1" style="stop-color:${warna(color)}" stop-opacity="0"/></linearGradient></defs>
      <path d="${line} L${width},${height} L0,${height} Z" fill="url(#${id})"/>
      <path d="${line}" fill="none" style="stroke:${warna(color)}" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>`;
  }

  function renderKpis() {
    const { pendapatan, kendaraan, area, arus } = data;
    const sameDay = data.tanggal_buku === data.hari_ini;
    const bersih = pendapatan.hari_ini - pendapatan.pengeluaran;
    const percent = area.kapasitas ? Math.round(area.terisi / area.kapasitas * 100) : null;
    const hours = flowRange();
    const kpis = [
      { href: '#pendapatan', tone: 'blue', color: '#0b2cc0', icon: 'ti-wallet', label: sameDay ? 'Pendapatan hari ini' : 'Pendapatan tanggal buku',
        value: rupiah(pendapatan.hari_ini), delta: percentChange(pendapatan.hari_ini, pendapatan.kemarin),
        spark: pendapatan.minggu.map(item => item.total), foot: `Bersih ${bersih < 0 ? '-' : ''}${rupiah(Math.abs(bersih))}` },
      { href: '#in-area', tone: 'green', color: '#1a9b62', icon: 'ti-login', label: 'Kendaraan masuk', short: 'Masuk', value: number(kendaraan.masuk),
        delta: percentChange(kendaraan.masuk, kendaraan.masuk_kemarin), spark: hours.map(hour => arus.masuk[hour]), foot: `Kemarin ${number(kendaraan.masuk_kemarin)}` },
      { href: '#riwayat', tone: 'orange', color: '#eb6834', icon: 'ti-logout', label: 'Kendaraan keluar', short: 'Keluar', value: number(kendaraan.keluar),
        delta: percentChange(kendaraan.keluar, kendaraan.keluar_kemarin), spark: hours.map(hour => arus.keluar[hour]),
        foot: kendaraan.durasi === null ? 'Belum ada yang keluar' : `Rata-rata ${duration(kendaraan.durasi)}` },
      { href: '#in-area', tone: 'sky', icon: 'ti-parking', label: 'Kendaraan di area', short: 'Di area', value: number(area.terisi), meter: percent,
        foot: percent === null ? 'Kapasitas belum diatur' : `${percent}% dari ${number(area.kapasitas)} slot` },
    ];
    $('[data-home-kpis]').innerHTML = kpis.map(kpi => `
      <a class="hp-kpi hp-kpi-${kpi.tone}" href="${kpi.href}">
        <div class="hp-kpi-top"><span class="hp-kpi-icon"><i class="ti ${kpi.icon}"></i></span><span class="hp-kpi-label">${kpi.short ? `<span class="hp-kpi-long">${escapeHtml(kpi.label)}</span><span class="hp-kpi-short">${escapeHtml(kpi.short)}</span>` : escapeHtml(kpi.label)}</span></div>
        <strong class="hp-kpi-value">${escapeHtml(kpi.value)}</strong>
        <div class="hp-kpi-bottom">
          ${kpi.meter === undefined
            ? `${sparkline(kpi.spark, kpi.color)}${deltaPill(kpi.delta)}`
            : `<span class="hp-meter${kpi.meter > 90 ? ' is-full' : ''}"><span style="width:${Math.min(100, kpi.meter ?? 0)}%"></span></span>`}
        </div>
        <p class="hp-kpi-foot">${escapeHtml(kpi.foot)}</p>
      </a>`).join('');
  }

  const shortDate = iso => isoDate(iso).toLocaleDateString('id-ID', { day: 'numeric', month: 'short' });
  const range = (from, to) => from.slice(0, 7) === to.slice(0, 7) ? `${Number(from.slice(8))}–${shortDate(to)}` : `${shortDate(from)}–${shortDate(to)}`;

  function renderMonth() {
    const month = data.bulan;
    if (!month) return;
    const bersih = month.pendapatan - month.pengeluaran;
    const minus = value => `${value < 0 ? '-' : ''}${rupiah(Math.abs(value))}`;
    const items = [
      { label: 'Pendapatan', value: rupiah(month.pendapatan), extra: `${deltaPill(percentChange(month.pendapatan, month.pendapatan_lalu))}<small>${range(month.lalu_dari, month.lalu_sampai)}: ${rupiah(month.pendapatan_lalu)}</small>` },
      { label: 'Pengeluaran', value: rupiah(month.pengeluaran) },
      { label: 'Laba bersih', value: minus(bersih), tone: bersih < 0 ? 'bad' : '' },
      { label: 'Rata-rata per hari', value: rupiah(month.hari ? month.pendapatan / month.hari : 0), extra: `<small>${number(month.hari)} hari</small>` },
    ];
    $('[data-home-month]').innerHTML = `
      <div class="hp-month-title"><span class="hp-month-icon"><i class="ti ti-calendar-stats"></i></span>
        <span><strong>Bulan ini</strong><small>${range(month.dari, month.sampai)} ${month.sampai.slice(0, 4)}</small></span></div>
      ${items.map(item => `
      <div class="hp-month-item${item.tone ? ` is-${item.tone}` : ''}">
        <span>${item.label}</span><strong>${item.value}</strong>${item.extra ? `<div class="hp-month-extra">${item.extra}</div>` : ''}
      </div>`).join('')}`;
  }

  // Komposisi kendaraan masuk hari ini (tanpa yang dibatalkan).
  function renderMix() {
    const mix = data.komposisi;
    if (!mix) return;
    const MIX_COLORS = ['#0b2cc0', '#0088dd', '#7c5cdb', '#c98500'];
    const total = mix.jenis.reduce((sum, item) => sum + item.jumlah, 0);
    const pct = value => total ? Math.round(value / total * 100) : 0;
    const bar = parts => `<div class="hp-mix-bar">${parts.filter(part => part.jumlah).map(part => `<span style="flex-grow:${part.jumlah};background:${warna(part.color)}"></span>`).join('') || '<span></span>'}</div>`;
    const legend = parts => `<div class="hp-mix-legend">${parts.map(part => `<span><i style="background:${warna(part.color)}"></i>${escapeHtml(capital(part.nama))} <b>${number(part.jumlah)}</b> <small>${pct(part.jumlah)}%</small></span>`).join('')}</div>`;
    const jenis = mix.jenis.slice(0, 4).map((item, index) => ({ ...item, color: MIX_COLORS[index] }));
    const pelanggan = [{ nama: 'Umum', jumlah: mix.umum, color: '#0b2cc0' }, { nama: 'Member', jumlah: mix.member, color: '#1a9b62' }];
    $('[data-home-mix]').innerHTML = `
      <div class="hp-mix-item"><span class="hp-mix-label">Jenis kendaraan</span>${bar(jenis)}${total ? legend(jenis) : '<div class="hp-mix-legend"><span>Belum ada kendaraan</span></div>'}</div>
      <div class="hp-mix-item"><span class="hp-mix-label">Umum vs member</span>${bar(pelanggan)}${legend(pelanggan)}</div>
      <div class="hp-mix-item"><span class="hp-mix-label">Rata-rata bayar</span><strong class="hp-mix-value">${mix.rata_bayar === null ? '-' : rupiah(mix.rata_bayar)}</strong><small class="hp-mix-note">per kendaraan berbayar hari ini</small></div>`;
  }

  function renderPayments() {
    const sameDay = data.tanggal_buku === data.hari_ini;
    $('[data-home-payments-sub]').textContent = sameDay ? 'Pendapatan per metode hari ini' : `Pendapatan per metode, ${longDate(data.tanggal_buku)}`;
    const list = data.metode;
    if (!list.length) {
      $('[data-home-payments]').innerHTML = '<p class="hp-empty">Belum ada pendapatan pada tanggal buku ini</p>';
      return;
    }
    const total = list.reduce((sum, item) => sum + item.total, 0);
    const count = list.reduce((sum, item) => sum + item.jumlah, 0);
    const share = item => total ? item.total / total * 100 : 0;
    const color = index => PAY_COLORS[index] || '#b8c2d3';
    $('[data-home-payments]').innerHTML = `
      <div class="hp-pay-total"><strong>${rupiah(total)}</strong><span>${number(count)} transaksi</span></div>
      <div class="hp-pay-stack" role="img" aria-label="Komposisi pendapatan per metode">
        ${list.map((item, index) => share(item) ? `<span style="flex-grow:${share(item).toFixed(2)};background:${warna(color(index))}" title="${escapeHtml(item.nama)} ${Math.round(share(item))}%"></span>` : '').join('')}
      </div>
      <ul class="hp-pay-list">${list.map((item, index) => `
        <li class="hp-pay-row">
          <i class="hp-pay-dot" style="background:${warna(color(index))}"></i>
          <span class="hp-pay-name">${escapeHtml(item.nama)}<small>${number(item.jumlah)} transaksi</small></span>
          <span class="hp-pay-amount">${rupiah(item.total)}<small>${share(item).toLocaleString('id-ID', { maximumFractionDigits: 1 })}%</small></span>
        </li>`).join('')}
      </ul>`;
  }

  // Tren 30 hari: dua grafik batang berbagi sumbu tanggal (tidak memakai dua sumbu-Y).
  function renderTrend() {
    const days = data.tren || [];
    const box = $('[data-home-trend]');
    const compact = value => value >= 1e9 ? `${(value / 1e9).toLocaleString('id-ID', { maximumFractionDigits: 1 })} M`
      : value >= 1e6 ? `${(value / 1e6).toLocaleString('id-ID', { maximumFractionDigits: 1 })} jt`
      : value >= 1e3 ? `${Math.round(value / 1e3).toLocaleString('id-ID')} rb` : number(value);
    const dayName = iso => isoDate(iso).toLocaleDateString('id-ID', { weekday: 'short', day: 'numeric', month: 'short' });
    const sum = key => days.reduce((total, day) => total + day[key], 0);
    const totalRev = sum('pendapatan'), totalVeh = sum('kendaraan');
    if (!days.length || (!totalRev && !totalVeh)) {
      box.innerHTML = '<p class="hp-empty">Belum ada pendapatan atau kendaraan dalam 30 hari terakhir</p>';
      return;
    }
    const maxRev = Math.max(...days.map(day => day.pendapatan), 1);
    const maxVeh = Math.max(...days.map(day => day.kendaraan), 1);
    const withRev = days.filter(day => day.pendapatan > 0);
    const high = withRev.reduce((best, day) => !best || day.pendapatan > best.pendapatan ? day : best, null);
    const low = withRev.reduce((best, day) => !best || day.pendapatan < best.pendapatan ? day : best, null);
    const height = (value, max) => value ? Math.max(2, value / max * 100) : 0;
    const marker = day => day.tanggal === data.tanggal_buku ? ' is-book' : day.tanggal === data.hari_ini ? ' is-today' : '';
    const weekend = day => [0, 6].includes(isoDate(day.tanggal).getDay()) ? ' is-weekend' : '';
    const axis = index => (days.length - 1 - index) % 7 === 0 ? shortDate(days[index].tanggal) : '';
    const panel = (key, field, max, label, format) => `
      <div class="hp-trend-panel hp-trend-${key}">
        <div class="hp-trend-scale"><span>${format(max)}</span><span>${format(max / 2)}</span><span>0</span></div>
        <div class="hp-trend-plot">
          ${days.map((day, index) => `<span class="hp-trend-col${weekend(day)}${marker(day)}" data-trend-index="${index}"><i style="height:${height(day[field], max).toFixed(1)}%"></i></span>`).join('')}
        </div>
        <span class="hp-trend-label">${label}</span>
      </div>`;
    box.innerHTML = `
      <div class="hp-trend-chart">
        ${panel('rev', 'pendapatan', maxRev, 'Pendapatan', value => compact(value))}
        ${panel('veh', 'kendaraan', maxVeh, 'Kendaraan masuk', value => number(Math.round(value)))}
        <div class="hp-trend-axis"><span></span><div>${days.map((_, index) => `<span>${axis(index)}</span>`).join('')}</div></div>
        <div class="hp-trend-tip" hidden></div>
      </div>
      <div class="hp-trend-stats">
        <div><span>Total pendapatan</span><strong>${rupiah(totalRev)}</strong><small>${number(withRev.length)} hari ada pendapatan</small></div>
        <div><span>Rata-rata per hari</span><strong>${rupiah(totalRev / days.length)}</strong><small>${number(Math.round(totalVeh / days.length))} kendaraan/hari</small></div>
        <div><span>Tertinggi</span><strong>${high ? rupiah(high.pendapatan) : '-'}</strong><small>${high ? dayName(high.tanggal) : 'Belum ada'}</small></div>
        <div><span>Terendah</span><strong>${low ? rupiah(low.pendapatan) : '-'}</strong><small>${low ? dayName(low.tanggal) : 'Belum ada'}</small></div>
      </div>`;
    $('[data-home-trend-sub]').textContent = `${longDate(days[0].tanggal)} – ${longDate(days[days.length - 1].tanggal)} · pendapatan per tanggal buku`;

    // Tooltip per hari: arahkan ke kolom mana pun (pendapatan atau kendaraan).
    const chart = box.querySelector('.hp-trend-chart');
    const tip = box.querySelector('.hp-trend-tip');
    const highlight = index => chart.querySelectorAll('.hp-trend-col').forEach(col => col.classList.toggle('is-hover', col.dataset.trendIndex === String(index)));
    chart.addEventListener('pointermove', event => {
      const col = event.target.closest('.hp-trend-col');
      if (!col) return;
      const day = days[Number(col.dataset.trendIndex)];
      highlight(col.dataset.trendIndex);
      tip.innerHTML = `<b>${escapeHtml(dayName(day.tanggal))}</b>
        <span><i class="hp-dot-rev"></i>Pendapatan <strong>${rupiah(day.pendapatan)}</strong></span>
        <span><i class="hp-dot-veh"></i>Kendaraan <strong>${number(day.kendaraan)}</strong></span>`;
      tip.hidden = false;
      const area = chart.getBoundingClientRect(), rect = col.getBoundingClientRect();
      // Di samping kolom (kanan, atau kiri bila tidak muat) agar batang yang ditunjuk tidak tertutup.
      const right = rect.right - area.left + 8, width = tip.offsetWidth;
      tip.style.left = `${Math.max(0, right + width <= area.width ? right : rect.left - area.left - 8 - width)}px`;
    });
    chart.addEventListener('pointerleave', () => { tip.hidden = true; highlight(-1); });
  }

  function renderKasir() {
    const list = data.kasir || [];
    const cek = data.cek || { batal: data.kendaraan.batal, hilang: 0, manual: 0 };
    const time = value => value ? (value.slice(0, 10) === data.hari_ini ? value.slice(11) : `${isoDate(value.slice(0, 10)).toLocaleDateString('id-ID', { day: 'numeric', month: 'short' })} ${value.slice(11)}`) : '-';
    $('[data-home-kasir]').innerHTML = list.length ? list.map(kasir => `
      <li class="hp-cashier">
        <span class="hp-cashier-avatar">${escapeHtml(kasir.nama.trim().split(/\s+/).slice(0, 2).map(word => word[0]).join('').toUpperCase())}</span>
        <span class="hp-cashier-copy"><strong>${escapeHtml(kasir.nama)}</strong>
          <span class="${kasir.online ? 'is-online' : 'is-off'}">${kasir.online ? `Login ${time(kasir.login)}` : 'Sudah logout, belum tutup shift'} · ${number(kasir.jumlah)} trx</span></span>
        <span class="hp-cashier-cash"><strong>${rupiah(kasir.tunai)}</strong><small>tunai dari ${rupiah(kasir.total)}</small></span>
      </li>`).join('') : '<li class="hp-empty">Tidak ada kasir yang bertugas</li>';
    const checks = [
      { href: '#pembatalan', label: 'Pembatalan', value: cek.batal },
      { href: '#pendapatan', label: 'Tiket hilang', value: cek.hilang },
      { href: '#pendapatan', label: 'Tiket manual', value: cek.manual },
    ];
    $('[data-home-cek]').innerHTML = checks.map(item => `
      <a class="hp-check-item${item.value ? ' is-flag' : ''}" href="${item.href}"><strong>${number(item.value)}</strong><span>${item.label}</span></a>`).join('');
  }

  function renderDevices() {
    const devices = data.perangkat;
    const online = devices.filter(device => device.status === 'online').length;
    $('[data-home-device-summary]').textContent = devices.length ? `${online} dari ${devices.length} perangkat online` : 'Belum ada perangkat';
    if (!devices.length) {
      $('[data-home-devices]').innerHTML = '<li class="hp-empty">Tambahkan perangkat di menu Perangkat</li>';
      return;
    }
    $('[data-home-devices]').innerHTML = devices.map(device => {
      const [label, icon, tone] = statusText[device.status] || statusText.unknown;
      const info = [device.jenis, device.alamat, device.status === 'online' && device.latensi !== null ? `${device.latensi} ms` : '']
        .filter(Boolean).join(' · ');
      const checked = device.terakhir_dicek ? `Terakhir dicek ${device.terakhir_dicek}` : 'Belum pernah dicek';
      return `
      <li class="hp-device" title="${escapeHtml(checked)}">
        <span class="hp-device-icon"><i class="ti ${deviceIcon[device.jenis] || 'ti-device-desktop'}"></i></span>
        <span class="hp-device-copy"><strong>${escapeHtml(device.nama)}</strong><span>${escapeHtml(info)}</span></span>
        <span class="hp-status hp-status-${tone}"><i class="ti ${icon}"></i>${label}</span>
      </li>`;
    }).join('');
  }

  // Jam yang ditampilkan: dari 06.00 (atau jam pertama ada kendaraan) sampai jam sekarang.
  function flowRange() {
    const { masuk, keluar } = data.arus;
    const active = masuk.map((value, hour) => value || keluar[hour] ? hour : -1).filter(hour => hour >= 0);
    const start = Math.min(6, active[0] ?? 6);
    const end = Math.max(data.jam, active[active.length - 1] ?? 0, start + 1);
    return Array.from({ length: end - start + 1 }, (_, index) => start + index);
  }

  // Heatmap 24 jam: intensitas warna = jumlah / jumlah terbanyak (masuk & keluar satu skala).
  function renderFlow() {
    const { masuk, keluar } = data.arus;
    const totals = masuk.map((value, hour) => value + keluar[hour]);
    const peak = totals.indexOf(Math.max(...totals));
    const max = Math.max(...masuk, ...keluar, 1);
    const pad = hour => String(hour).padStart(2, '0');
    $('[data-home-flow-sub]').textContent = totals[peak]
      ? `Jam tersibuk ${pad(peak)}.00–${pad(peak + 1)}.00 · ${number(masuk[peak])} masuk, ${number(keluar[peak])} keluar`
      : 'Belum ada kendaraan hari ini';
    const cells = (values, tone) => values.map((value, hour) => {
      const level = value ? Math.max(12, Math.round(value / max * 100)) : 0;
      const state = hour > data.jam ? ' is-future' : value ? '' : ' is-zero';
      return `<span class="hp-heat-cell hp-heat-${tone}${state}${level > 55 ? ' is-dark' : ''}${hour === peak && totals[peak] ? ' is-peak' : ''}" style="--level:${level}%"
        title="${pad(hour)}.00–${pad(hour + 1)}.00 · ${number(value)} ${tone === 'in' ? 'masuk' : 'keluar'}">${hour > data.jam || !value ? '' : number(value)}</span>`;
    }).join('');
    const row = (label, values, tone) => `
      <div class="hp-heat-row"><span class="hp-heat-label">${label}</span><div class="hp-heat-cells">${cells(values, tone)}</div>
        <strong class="hp-heat-total">${number(values.reduce((sum, value) => sum + value, 0))}</strong></div>`;
    $('[data-home-flow]').innerHTML = `
      ${row('Masuk', masuk, 'in')}
      ${row('Keluar', keluar, 'out')}
      <div class="hp-heat-row hp-heat-axis"><span class="hp-heat-label"></span><div class="hp-heat-cells">${masuk.map((_, hour) => `<span>${hour % 3 ? '' : pad(hour)}</span>`).join('')}</div><span class="hp-heat-total">Total</span></div>`;
  }

  function render() {
    renderHeader();
    renderKpis();
    renderMonth();
    renderMix();
    renderFlow();
    renderPayments();
    renderTrend();
    renderKasir();
    renderDevices();
  }

  async function load() {
    if (loading) return;
    loading = true;
    try {
      const response = await fetch('/api/dashboard', { credentials: 'same-origin', headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      data = await response.json();
      render();
    } catch {
      const chip = $('[data-home-status]');
      chip.classList.remove('is-warn');
      chip.classList.add('is-bad');
      chip.innerHTML = '<i></i> Gagal memuat data';
    } finally {
      loading = false;
    }
  }

  // Cek koneksi perangkat (TCP) di latar, paling sering tiap 2 menit, lalu muat ulang status di beranda.
  async function probeDevices() {
    if (Date.now() - lastProbe < PROBE_MS) return;
    lastProbe = Date.now();
    try {
      const response = await fetch('/api/perangkat/status', { credentials: 'same-origin', headers: { Accept: 'application/json' } });
      if (response.ok) await load();
    } catch { /* status lama tetap ditampilkan */ }
  }

  const visible = () => !root.hidden && document.visibilityState === 'visible';
  function refresh() {
    if (!visible()) return;
    load().then(probeDevices);
  }

  window.addEventListener('hp:dashboard', refresh);
  document.addEventListener('visibilitychange', refresh);
  setInterval(refresh, REFRESH_MS);
  if (!root.hidden) refresh();
})();
