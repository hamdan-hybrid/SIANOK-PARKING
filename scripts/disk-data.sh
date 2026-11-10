# Disk penyimpanan: storage/ (foto kendaraan, backup database, sertifikat) ditaruh di hardisk terbesar.
# Di-source oleh setup.sh (bukan dijalankan langsung). Memakai APP_DIR, APP_USER, INTERACTIVE, STAMP, DISK_DATA,
# ask, step_end, info, warn, log, run_logged, as_user, HP_NODE_BIN, HP_PM2_NAME, HP_LOG_FILE.
#
# Pilihan (hanya disk dengan ruang kosong lebih besar dari disk aplikasi, minimal 20 GB; disk USB / removable dilewati):
#   1. storage/ sudah berupa mount / symlink (sudah di disk lain)   → tidak diubah.
#   2. Disk lain yang sudah terpasang permanen (/etc/fstab)         → dipakai.
#   3. Partisi / disk yang belum dipasang tetapi sudah berisi filesystem (ext4, xfs, btrfs, NTFS, exFAT)
#      → dipasang di /mnt/data tanpa diformat (isi lama tetap) dan dicatat di /etc/fstab (UUID, nofail).
#      Yang gagal dipasang, hanya bisa dibaca (NTFS Windows yang di-hibernate), atau penuh dikembalikan seperti semula.
#   4. Disk kosong total (tanpa partisi & filesystem) → diformat ext4 hanya bila operator mengetik YA di wizard.
#      Mode --yes / Perbarui sistem tidak pernah memformat.
# Folder <disk>/<nama-aplikasi> lalu di-bind ke storage/ lewat /etc/fstab (dibackup dulu ke /etc/fstab.bak-*).
# Data lama di storage/ dipindah hanya dari wizard atau --disk-data (aplikasi berhenti beberapa detik untuk salinan
# terakhir); mode --yes hanya memberi tahu. Salinan lama disimpan di _backup/storage-lama-<waktu>.
# Opsi setup.sh: --disk-data DIR (folder tujuan pilihan sendiri), --tanpa-disk-data (storage tetap di disk sistem;
# diingat di HP_STATE_DIR sehingga Perbarui sistem juga tidak memindah).

DD_MIN=$((20 * 1024 * 1024 * 1024))
DD_INFO=""; DD_FSTAB_BAK=""; DD_NTFS=""; DD_WHY=""
DD_MNT=""; DD_DEV=""; DD_FSTYPE=""; DD_DIR=""; DD_SKIP=()

dd_h() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%s B' "${1:-0}"; }
dd_avail() { df -B1 --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' '; }
dd_files() { find "$1" -type f 2>/dev/null | wc -l; }
dd_bytes() { find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }
# Path yang aman ditulis apa adanya ke /etc/fstab (tanpa spasi / karakter khusus).
dd_path_ok() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]; }
dd_posix() { case "$1" in ext4|xfs|btrfs) return 0 ;; *) return 1 ;; esac; }

# Tambah baris ke /etc/fstab. Baris baru diuji dulu (findmnt --verify) di file terpisah; /etc/fstab dibackup sekali per run.
dd_fstab_add() {
  local new tmp
  new="$(mktemp)"; printf '%s\n' "$@" >"$new"
  if ! findmnt --verify --tab-file "$new" >>"$HP_LOG_FILE" 2>&1; then rm -f "$new"; log "fstab: baris baru tidak lolos findmnt --verify"; return 1; fi
  if [ -z "$DD_FSTAB_BAK" ]; then
    DD_FSTAB_BAK="/etc/fstab.bak-$HP_PM2_NAME-$STAMP"
    cp -p /etc/fstab "$DD_FSTAB_BAK" || { rm -f "$new"; DD_FSTAB_BAK=""; return 1; }
  fi
  tmp="$(mktemp /etc/.fstab.XXXXXX)"
  if { cat /etc/fstab; [ -z "$(tail -c1 /etc/fstab)" ] || echo; cat "$new"; } >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" /etc/fstab; then
    rm -f "$new"; systemctl daemon-reload >>"$HP_LOG_FILE" 2>&1; return 0
  fi
  rm -f "$new" "$tmp"; return 1
}
# Hapus baris yang persis sama (membatalkan dd_fstab_add).
dd_fstab_del() {
  local pat tmp
  pat="$(mktemp)"; printf '%s\n' "$@" >"$pat"; tmp="$(mktemp /etc/.fstab.XXXXXX)"
  grep -vxF -f "$pat" /etc/fstab >"$tmp"; chmod 644 "$tmp"; mv -f "$tmp" /etc/fstab
  rm -f "$pat"; systemctl daemon-reload >>"$HP_LOG_FILE" 2>&1
}

# NTFS: ntfs-3g (stabil, dipakai Ubuntu bertahun-tahun), driver kernel ntfs3 bila ntfs-3g tidak bisa dipasang.
dd_ntfs_driver() {
  if ! command -v ntfs-3g >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    run_logged apt-get install -y --no-install-recommends ntfs-3g \
      || { run_logged apt-get update && run_logged apt-get install -y --no-install-recommends ntfs-3g; }
  fi
  command -v ntfs-3g >/dev/null && echo ntfs-3g || echo ntfs3
}

# Baris fstab disk data. NTFS / exFAT tidak punya izin Unix: pemilik & izin dari opsi mount (folder 750, file 640).
dd_fs_entry() { # fstype uuid mnt
  local fs="$1" uuid="$2" mnt="$3" own common="noatime,nofail,x-systemd.device-timeout=10s"
  own="uid=$(id -u "$APP_USER"),gid=$(id -g "$APP_USER"),dmask=027,fmask=137"
  case "$fs" in
    ext4) printf 'UUID=%s %s ext4 defaults,%s 0 2' "$uuid" "$mnt" "$common" ;;
    xfs|btrfs) printf 'UUID=%s %s %s defaults,%s 0 0' "$uuid" "$mnt" "$fs" "$common" ;;
    ntfs) printf 'UUID=%s %s %s %s,%s 0 0' "$uuid" "$mnt" "$DD_NTFS" "$own" "$common" ;;
    exfat) printf 'UUID=%s %s exfat %s,%s 0 0' "$uuid" "$mnt" "$own" "$common" ;;
  esac
}

# Daftar kandidat (urut terbesar dulu), satu baris per kandidat, dipisah TAB:
#   M  mountpoint  sisa  fstype  device          disk lain yang sudah terpasang permanen
#   F  device      size  fstype  uuid  model     filesystem yang belum dipasang
#   E  device      size  model                   disk kosong total
dd_candidates() {
  local app_dev json
  app_dev="$(findmnt -n -o SOURCE --target "$APP_DIR" 2>/dev/null | sed 's/\[.*//')"
  json="$(lsblk -J -b -o NAME,PATH,TYPE,SIZE,FSTYPE,FSAVAIL,MOUNTPOINTS,RM,RO,TRAN,PTTYPE,UUID,MODEL 2>/dev/null \
       || lsblk -J -b -o NAME,PATH,TYPE,SIZE,FSTYPE,FSAVAIL,MOUNTPOINT,RM,RO,TRAN,PTTYPE,UUID,MODEL 2>/dev/null)" || return 0
  printf '%s' "$json" | DD_FSTAB="$(findmnt -s -n -l -o TARGET 2>/dev/null)" DD_APP="$APP_DIR" DD_APP_DEV="$app_dev" \
    DD_APP_MNT="$(findmnt -n -o TARGET --target "$APP_DIR" 2>/dev/null)" DD_MIN="$DD_MIN" "${HP_NODE_BIN:-node}" -e '
    const { DD_FSTAB = "", DD_APP, DD_APP_DEV, DD_APP_MNT, DD_MIN } = process.env;
    const fstab = new Set(DD_FSTAB.split("\n").map(s => s.trim()).filter(Boolean));
    const min = Number(DD_MIN), FS = new Set(["ext4", "xfs", "btrfs", "ntfs", "exfat"]);
    const yes = v => v === true || v === 1 || v === "1";
    const bersih = v => String(v ?? "").replace(/[\t\r\n]+/g, " ").trim();
    // Folder sistem / data program lain (mis. /var/lib/mysql di disk sendiri) dan automount desktop (/media) tidak dipakai.
    const sistem = /^\/(boot|efi|usr|var|opt|etc|root|snap|media|run|proc|sys|dev|tmp|bin|sbin|lib|lib64)(\/|$)/;
    const out = { M: [], F: [], E: [] };
    const walk = (nodes, disk) => {
      for (const n of nodes || []) {
        const d = n.type === "disk" ? n : disk || n;
        const mps = (n.mountpoints || [n.mountpoint]).filter(Boolean);
        const lepas = yes(d.rm) || yes(n.rm) || d.tran === "usb" || /^(zram|loop|nbd|ram|sr|fd|mmcblk\d+boot)/.test(String(d.name));
        const fs = String(n.fstype || ""), size = Number(n.size) || 0;
        if (!lepas && !yes(n.ro) && n.path !== DD_APP_DEV) {
          for (const m of mps) {
            if (m === "/" || m === DD_APP_MNT || sistem.test(m) || !fstab.has(m) || !FS.has(fs)) continue;
            if (DD_APP === m || DD_APP.startsWith(m + "/") || m.startsWith(DD_APP + "/")) continue;
            out.M.push([m, Number(n.fsavail) || 0, fs, n.path]);
          }
          if (!mps.length && !n.children && FS.has(fs) && n.uuid && size >= min) out.F.push([n.path, size, fs, n.uuid, bersih(d.model)]);
          if (n.type === "disk" && !n.children && !fs && !mps.length && size >= min) out.E.push([n.path, size, bersih(n.model)]);
        }
        walk(n.children, d);
      }
    };
    walk(JSON.parse(require("fs").readFileSync(0, "utf8")).blockdevices);
    for (const [kind, rows] of Object.entries(out)) rows.sort((a, b) => b[1] - a[1]).forEach(r => console.log([kind, ...r].join("\t")));
  ' 2>>"$HP_LOG_FILE"
}

# Pasang filesystem yang belum terpasang; berhasil → DD_MNT/DD_DEV/DD_FSTYPE. Gagal / tidak layak → dikembalikan.
dd_try_mount() { # device fstype uuid
  local dev="$1" fs="$2" uuid="$3" mnt="" line="" cmt="" i=2 avail why=""
  # Sudah tercatat di fstab (mis. nofail yang gagal saat boot): pakai baris itu, jangan dobel.
  mnt="$(findmnt -s -n -o TARGET -S "UUID=$uuid" 2>/dev/null | head -n1)"
  [ -n "$mnt" ] || mnt="$(findmnt -s -n -o TARGET -S "$dev" 2>/dev/null | head -n1)"
  if [ -n "$mnt" ]; then
    mkdir -p "$mnt"
    run_logged mount "$mnt" || { DD_SKIP+=("$dev: ada di /etc/fstab ($mnt) tetapi gagal dipasang"); return 1; }
  else
    mnt=/mnt/data
    while mountpoint -q "$mnt" || [ -n "$(ls -A "$mnt" 2>/dev/null)" ] || { [ -e "$mnt" ] && [ ! -d "$mnt" ]; }; do mnt="/mnt/data$i"; i=$((i + 1)); done
    [ "$fs" = ntfs ] && [ -z "$DD_NTFS" ] && DD_NTFS="$(dd_ntfs_driver)"
    line="$(dd_fs_entry "$fs" "$uuid" "$mnt")"; cmt="# $HP_PM2_NAME: disk data $dev (setup.sh $STAMP)"
    mkdir -p "$mnt"
    if ! dd_fstab_add "$cmt" "$line"; then rmdir "$mnt" 2>/dev/null; DD_SKIP+=("$dev: baris /etc/fstab tidak valid"); return 1; fi
    if ! run_logged mount "$mnt"; then
      dd_fstab_del "$cmt" "$line"; rmdir "$mnt" 2>/dev/null
      DD_SKIP+=("$dev ($fs): gagal dipasang"); return 1
    fi
  fi
  if ! touch "$mnt/.$HP_PM2_NAME-uji-tulis" 2>/dev/null; then why="hanya bisa dibaca (NTFS: Windows di-hibernate / Fast Startup aktif)"
  else
    rm -f "$mnt/.$HP_PM2_NAME-uji-tulis"; avail="$(dd_avail "$mnt")"
    { [ "${avail:-0}" -gt "$APP_AVAIL" ] && [ "${avail:-0}" -ge "$DD_MIN" ]; } || why="sisa hanya $(dd_h "$avail")"
  fi
  if [ -n "$why" ]; then
    # Hanya yang dipasang langkah ini yang dilepas lagi; baris fstab milik operator dibiarkan.
    if [ -n "$line" ]; then run_logged umount "$mnt"; dd_fstab_del "$cmt" "$line"; rmdir "$mnt" 2>/dev/null; fi
    DD_SKIP+=("$dev: $why"); return 1
  fi
  DD_MNT="$mnt"; DD_DEV="$dev"; DD_FSTYPE="$fs"
}

# Format disk kosong total (ext4, satu partisi GPT). Dicek ulang tepat sebelum format.
dd_format() { # device → DD_FMT_PART, DD_FMT_UUID
  local dev="$1" part
  [ -z "$(lsblk -nro NAME "$dev" 2>/dev/null | tail -n +2)" ] || return 1
  [ -z "$(blkid -p -o value -s TYPE "$dev" 2>/dev/null)" ] || return 1
  [ -z "$(ls -A "/sys/class/block/${dev##*/}/holders" 2>/dev/null)" ] || return 1
  printf 'label: gpt\n,\n' | run_logged sfdisk --quiet "$dev" || return 1
  udevadm settle 2>/dev/null
  part="$(lsblk -nrpo PATH,TYPE "$dev" 2>/dev/null | awk '$2 == "part" { print $1; exit }')"
  [ -b "$part" ] && run_logged mkfs.ext4 -q -F -m 1 -L data "$part" || return 1
  udevadm settle 2>/dev/null
  DD_FMT_PART="$part"; DD_FMT_UUID="$(blkid -p -s UUID -o value "$part" 2>/dev/null)"
  [ -n "$DD_FMT_UUID" ]
}

# Saat boot PM2 (systemd pm2-<user>) menunggu storage terpasang; tetap jalan walau disk data gagal dipasang.
dd_pm2_after_mount() {
  local unit dir f tmp
  unit="$(systemd-escape -p --suffix=mount "$APP_DIR/storage")"
  dir="/etc/systemd/system/pm2-$APP_USER.service.d"; f="$dir/$HP_PM2_NAME-storage.conf"
  tmp="$(mktemp)"
  printf '[Unit]\n# Dibuat setup.sh %s: tunggu storage (disk data) terpasang sebelum aplikasi start.\nWants=%s\nAfter=%s\n' \
    "$HP_PM2_NAME" "$unit" "$unit" >"$tmp"
  if cmp -s "$tmp" "$f"; then rm -f "$tmp"
  else mkdir -p "$dir"; chmod 644 "$tmp"; mv -f "$tmp" "$f"; systemctl daemon-reload >>"$HP_LOG_FILE" 2>&1; fi
}

# Bind DD_DIR → storage/ lewat /etc/fstab.
dd_bind() {
  local st="$APP_DIR/storage" line cmt
  mkdir -p "$st"; chown "$APP_USER:" "$st"
  line="$DD_DIR $st none bind,nofail,x-systemd.requires-mounts-for=$DD_DIR 0 0"
  cmt="# $HP_PM2_NAME: storage di disk data (setup.sh $STAMP)"
  dd_fstab_add "$cmt" "$line" || return 1
  if run_logged mount "$st" && mountpoint -q "$st"; then dd_pm2_after_mount; return 0; fi
  dd_fstab_del "$cmt" "$line"; return 1
}

# Pindah isi storage/ (disk sistem) ke DD_DIR (kosong), lalu bind. Aplikasi berhenti hanya untuk salinan terakhir.
dd_move_and_bind() { # jumlah-file besar-byte
  local st="$APP_DIR/storage" n="$1" b="$2" opt lama rc stopped=0 ok=0
  dd_posix "$DD_FSTYPE" && opt=(-aH) || opt=(-rt)
  if ! command -v rsync >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    run_logged apt-get install -y --no-install-recommends rsync || { DD_WHY="rsync tidak bisa dipasang"; return 1; }
  fi
  info "Menyalin $n file ($(dd_h "$b")) ke $DD_DIR, aplikasi tetap berjalan..."
  # Kode 24 = ada file yang terhapus selama penyalinan (mis. rotasi backup): wajar, salinan terakhir menyamakan.
  run_logged rsync "${opt[@]}" "$st/" "$DD_DIR/"; rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ] || { DD_WHY="penyalinan gagal (rsync kode $rc, lihat log)"; return 1; }
  info "Salinan terakhir: aplikasi dihentikan sebentar..."
  as_user "$APP_USER" pm2 stop "$HP_PM2_NAME" >>"$HP_LOG_FILE" 2>&1 && stopped=1
  lama="$APP_DIR/_backup/storage-lama-$STAMP"
  if run_logged rsync "${opt[@]}" --delete "$st/" "$DD_DIR/" \
     && [ "$(dd_files "$st")" = "$(dd_files "$DD_DIR")" ] && [ "$(dd_bytes "$st")" = "$(dd_bytes "$DD_DIR")" ]; then
    mkdir -p "$APP_DIR/_backup"
    if mv "$st" "$lama"; then
      if dd_bind; then ok=1
      else rmdir "$st" 2>/dev/null; mv "$lama" "$st"; DD_WHY="bind ke storage gagal; storage dikembalikan (salinan tetap di $DD_DIR)"; fi
    else DD_WHY="storage lama tidak bisa dipindah ke _backup"; fi
  else DD_WHY="jumlah / ukuran file salinan tidak sama; storage tidak diubah (salinan di $DD_DIR)"; fi
  [ "$stopped" = 1 ] && as_user "$APP_USER" pm2 start "$HP_PM2_NAME" >>"$HP_LOG_FILE" 2>&1
  [ "$ok" = 1 ] && DD_LAMA="$lama"
  [ "$ok" = 1 ]
}

disk_data_step() {
  local st="$APP_DIR/storage" src kind rows row a n=0 b=0 desc target_files f_rows=() m_row="" e_row=""
  # 1. storage/ sudah di disk lain.
  if [ -L "$st" ] || mountpoint -q "$st"; then
    src="$(findmnt -n -o SOURCE --target "$st/" 2>/dev/null)"
    DD_INFO="$([ -L "$st" ] && printf '→ %s, ' "$(readlink -f "$st")")$src, sisa $(dd_h "$(dd_avail "$st/")")"
    if [ -L "$st" ]; then step_end SKIPPED "storage sudah di disk lain ($DD_INFO)"
    elif findmnt -s -n -M "$st" >/dev/null 2>&1 \
         || [ "$(systemctl is-enabled "$(systemd-escape -p --suffix=mount "$st")" 2>/dev/null)" = enabled ]; then
      dd_pm2_after_mount; step_end SKIPPED "storage sudah di disk lain ($DD_INFO)"
    else step_end "NEEDS ATTENTION" "storage terpasang dari $src tetapi tidak tercatat di /etc/fstab: tidak terpasang lagi setelah reboot"; fi
    return
  fi

  # --tanpa-disk-data diingat (Perbarui sistem menjalankan setup.sh --yes tanpa opsi); --disk-data DIR menghapusnya.
  case "$DISK_DATA" in
    off) touch "$HP_STATE_DIR/tanpa-disk-data" ;;
    "") [ -f "$HP_STATE_DIR/tanpa-disk-data" ] && DISK_DATA=off ;;
    *) rm -f "$HP_STATE_DIR/tanpa-disk-data" ;;
  esac
  if [ "$DISK_DATA" = off ]; then
    DD_INFO="disk sistem (--tanpa-disk-data)"; step_end SKIPPED "storage tetap di disk sistem (--tanpa-disk-data; aktifkan lagi: --disk-data DIR)"; return
  fi

  APP_AVAIL="$(dd_avail "$APP_DIR")"; APP_AVAIL="${APP_AVAIL:-0}"
  if [ -d "$st" ]; then n="$(dd_files "$st")"; b="$(dd_bytes "$st")"; fi
  if ! dd_path_ok "$APP_DIR"; then
    DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "path folder aplikasi berisi spasi / karakter khusus; storage tidak dipindah otomatis"; return
  fi

  # 2. Pilih tujuan.
  if [ -n "$DISK_DATA" ]; then
    DD_DIR="${DISK_DATA%/}"
    dd_path_ok "$DD_DIR" || { step_end "NEEDS ATTENTION" "--disk-data harus path absolut tanpa spasi: $DISK_DATA"; return; }
    mkdir -p "$DD_DIR" || { step_end "NEEDS ATTENTION" "folder $DD_DIR tidak bisa dibuat"; return; }
    DD_MNT="$(findmnt -n -o TARGET --target "$DD_DIR" 2>/dev/null)"; DD_DEV="$(findmnt -n -o SOURCE --target "$DD_DIR" 2>/dev/null)"
    DD_FSTYPE="$(findmnt -n -o FSTYPE --target "$DD_DIR" 2>/dev/null)"
    if [ "$DD_MNT" = "$(findmnt -n -o TARGET --target "$APP_DIR" 2>/dev/null)" ]; then
      DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "--disk-data $DD_DIR ada di disk yang sama dengan aplikasi"; return
    fi
    kind=D
  else
    rows="$(dd_candidates)"
    while IFS= read -r row; do
      case "$row" in
        M$'\t'*) [ -z "$m_row" ] && m_row="$row" ;;
        F$'\t'*) f_rows+=("$row") ;;
        E$'\t'*) [ -z "$e_row" ] && e_row="$row" ;;
      esac
    done <<<"$rows"
    kind=""
    if [ -n "$m_row" ]; then
      IFS=$'\t' read -r _ DD_MNT a DD_FSTYPE DD_DEV <<<"$m_row"
      if [ "${a:-0}" -gt "$APP_AVAIL" ] && [ "${a:-0}" -ge "$DD_MIN" ]; then kind=M; desc="$DD_DEV di $DD_MNT ($DD_FSTYPE, sisa $(dd_h "$a"))"; fi
    fi
    if [ -z "$kind" ] && [ "${#f_rows[@]}" -gt 0 ]; then
      kind=F; IFS=$'\t' read -r _ DD_DEV a DD_FSTYPE _ src <<<"${f_rows[0]}"
      desc="$DD_DEV ($(dd_h "$a") $DD_FSTYPE${src:+, $src}, belum dipasang)"
    fi
    if [ -z "$kind" ] && [ -n "$e_row" ]; then
      kind=E; IFS=$'\t' read -r _ DD_DEV a src <<<"$e_row"
      desc="$DD_DEV ($(dd_h "$a")${src:+ $src}, kosong belum diformat)"
    fi
    if [ -z "$kind" ]; then
      DD_INFO="disk sistem"
      step_end SKIPPED "tidak ada disk lain yang lebih besar; storage di disk sistem (sisa $(dd_h "$APP_AVAIL"))"; return
    fi
    # Data lama: hanya dipindah dari wizard (bisa lama untuk puluhan GB, aplikasi berhenti sebentar di akhir).
    if [ "$n" -gt 0 ] && [ "$INTERACTIVE" -ne 1 ]; then
      DD_INFO="disk sistem"
      step_end "NEEDS ATTENTION" "storage ($n file, $(dd_h "$b")) masih di disk sistem (sisa $(dd_h "$APP_AVAIL")); disk lebih besar: $desc. Pindahkan saat senggang: sudo bash $APP_DIR/setup.sh"
      return
    fi
    if [ "$n" -gt 0 ]; then
      info "storage berisi $n file ($(dd_h "$b")) di disk sistem (sisa $(dd_h "$APP_AVAIL"))."
      info "Disk lebih besar: $desc"
      a="$(ask "Pindahkan storage ke disk itu? Aplikasi berhenti beberapa detik di akhir penyalinan (y/n)" y)"
      [[ "$a" =~ ^[YyJj] ]] || { DD_INFO="disk sistem"; step_end SKIPPED "storage tidak dipindah (dipilih operator); disk lebih besar: $desc"; return; }
    fi
  fi

  # 3. Siapkan disk.
  case "$kind" in
    E)
      if [ "$INTERACTIVE" -ne 1 ]; then
        DD_INFO="disk sistem"
        step_end "NEEDS ATTENTION" "ada disk kosong $desc; untuk memakainya jalankan sudo bash $APP_DIR/setup.sh lalu ketik YA (disk diformat ext4)"
        return
      fi
      warn "Disk kosong ditemukan: $desc."
      warn "Memformat MENGHAPUS SEMUA isi disk ini."
      a="$(ask "Ketik YA untuk memformat $DD_DEV (ext4) dan memakainya untuk foto & backup, Enter = lewati" lewati)"
      if [ "$a" != YA ]; then DD_INFO="disk sistem"; step_end SKIPPED "disk kosong $DD_DEV tidak diformat (dilewati operator)"; return; fi
      info "Memformat $DD_DEV..."
      if ! dd_format "$DD_DEV"; then DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "format $DD_DEV gagal (lihat log)"; return; fi
      dd_try_mount "$DD_FMT_PART" ext4 "$DD_FMT_UUID" \
        || { DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "$DD_FMT_PART sudah diformat tetapi gagal dipasang: ${DD_SKIP[*]}"; return; }
      ;;
    F)
      for row in "${f_rows[@]}"; do
        IFS=$'\t' read -r _ DD_DEV a DD_FSTYPE src _ <<<"$row"
        info "Memasang $DD_DEV ($(dd_h "$a") $DD_FSTYPE) tanpa format..."
        dd_try_mount "$DD_DEV" "$DD_FSTYPE" "$src" && break
        DD_MNT=""
      done
      if [ -z "$DD_MNT" ]; then
        DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "disk lain tidak bisa dipakai: ${DD_SKIP[*]}; storage tetap di disk sistem"; return
      fi
      ;;
  esac
  [ -n "$DD_DIR" ] || DD_DIR="$DD_MNT/$HP_PM2_NAME"
  if ! dd_path_ok "$DD_DIR"; then DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "path disk data berisi spasi / karakter khusus: $DD_DIR"; return; fi
  [ -n "$DD_FSTYPE" ] || DD_FSTYPE="$(findmnt -n -o FSTYPE --target "$DD_MNT" 2>/dev/null)"

  # 4. Folder tujuan milik user aplikasi.
  if dd_posix "$DD_FSTYPE"; then
    if [ -d "$DD_DIR" ]; then [ "$(stat -c %U "$DD_DIR")" = "$APP_USER" ] || run_logged chown -R "$APP_USER:" "$DD_DIR"
    else install -d -m 750 -o "$APP_USER" -g "$(id -gn "$APP_USER")" "$DD_DIR"; fi
  else mkdir -p "$DD_DIR"; fi
  if ! as_user "$APP_USER" test -w "$DD_DIR"; then
    DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "$DD_DIR tidak bisa ditulis $APP_USER (NTFS/exFAT: pasang dengan uid=$(id -u "$APP_USER"))"; return
  fi

  # 5. Pindah data lama (bila ada) lalu bind.
  target_files="$(dd_files "$DD_DIR")"
  DD_LAMA=""
  if [ "$n" -gt 0 ] && [ "$target_files" -gt 0 ]; then
    DD_INFO="disk sistem"
    step_end "NEEDS ATTENTION" "storage ($n file) dan $DD_DIR ($target_files file) sama-sama berisi data; tidak digabung otomatis (disk data terpasang di $DD_MNT)"; return
  fi
  if [ "$n" -gt 0 ]; then
    if ! dd_move_and_bind "$n" "$b"; then DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "$DD_WHY"; return; fi
  elif ! dd_bind; then
    DD_INFO="disk sistem"; step_end "NEEDS ATTENTION" "bind $DD_DIR ke storage gagal (lihat log); storage tetap di disk sistem"; return
  fi

  DD_INFO="$DD_DIR (${DD_DEV:-?} ${DD_FSTYPE:-?}, sisa $(dd_h "$(dd_avail "$DD_DIR")"))"
  local note="storage → $DD_INFO"
  [ "$target_files" -gt 0 ] && note="$note; memakai $target_files file yang sudah ada di disk itu"
  [ -n "$DD_LAMA" ] && note="$note; $n file dipindah, salinan lama: $DD_LAMA (hapus setelah dicek: sudo rm -rf $DD_LAMA)"
  [ "${#DD_SKIP[@]}" -gt 0 ] && note="$note; dilewati: ${DD_SKIP[*]}"
  [ -n "$DD_FSTAB_BAK" ] && note="$note; /etc/fstab lama: $DD_FSTAB_BAK"
  step_end SUCCESS "$note"
}
