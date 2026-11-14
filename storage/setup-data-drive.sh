#!/usr/bin/env bash
# setup-data-drive.sh — build or restore the bigrig archive HDD (encrypted, shared,
# spun down when idle, SMART-monitored). Idempotent: re-running only fixes drift.
#
#   sudo bash setup-data-drive.sh                    # apply / restore (never formats)
#   sudo bash setup-data-drive.sh --status           # read-only health report (won't wake the disk)
#   sudo bash setup-data-drive.sh --format-new-disk  # ALSO partition+encrypt+mkfs a BLANK disk
#   DISK=/dev/disk/by-id/ata-XXXX sudo -E bash setup-data-drive.sh ...   # a different/replacement disk
#
# After an OS reinstall with the data disk intact, plain apply is all you need: it
# finds the existing LUKS volume, re-enrolls the TPM if the old binding no longer
# unseals (asks for the recovery passphrase once), and restores everything below.
#
# What it reproduces (bigrig-linux, set up 2026-11-12, tuned 2026-11-14):
#   Layout    GPT, 1 partition 4K-aligned, type 8309 "Linux LUKS", name "data"
#             -> LUKS2, 4096-byte sectors, label data_crypt
#                keyslots: recovery passphrase + TPM2 bound to PCR 7 (Secure Boot state)
#             -> ext4, label data, -m 0, inode tables written up front
#   Boot      crypttab: tpm2-device=auto,headless=true,nofail (auto-unlock; boot never
#             blocks on a missing disk). fstab: noatime,nofail,device-timeout=30s.
#             Mountpoint is chattr +i underneath, so nothing lands on the root disk
#             if the data disk isn't mounted.
#   Share     Samba [data]: SMB3 only on 445, LAN + Tailscale + localhost only, one
#             user, no guests, macOS "fruit" tuning, recycle bin in .recycle.
#             nmbd masked; ufw allows 445 on LAN/Tailscale and mDNS on LAN.
#   Purge     samba-recycle-purge.timer deletes .recycle items >30 days, weekly
#             Sun 03:05 (same spin-up as smartd's Sunday short test).
#   Longevity Spin down after 30 min idle (hdparm -S 241 in /etc/hdparm.conf; udev
#             reapplies it at boot). The drive honors this timer; `hdparm -C` prints
#             "unknown" for its EPC idle states. Use `--status` instead.
#             smartd uses -n standby (never wakes a sleeping disk) and polls HOURLY:
#             each poll of an awake disk resets its idle timer, so the default 30-min
#             poll raced the 30-min spin-down and the disk rarely slept.
#   Monitor   smartd: short self-test Sun 03:00, long self-test 1st of month 04:00,
#             temp warn 45C / crit 55C. Tests that fall due while the disk sleeps run
#             when it next wakes. sysstat records per-disk I/O (`sar -d`), and a ~10 s
#             await spike there marks a spin-up.
#   Safety    LUKS header backup + SMART baseline saved in /root.
#
# Not on this box: on the Mac client, stop Finder writing .DS_Store to shares
# (fewer wake-ups):  defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
set -euo pipefail

# ------------------------------------------------------------------ config
DISK=${DISK:-/dev/disk/by-id/ata-ST8000NT001-3LZ101_WWZD1H5W}
OWNER=${OWNER:-${SUDO_USER:-shsin}}
MAPPER=data
PART_NAME=data
LUKS_LABEL=data_crypt
FS_LABEL=data
MNT=/srv/data
TPM2_PCRS=7
LAN_IF=enp11s0
LAN_NET=192.168.1.0/24
TS_IF=tailscale0
TS_NET=100.64.0.0/10
SPINDOWN=241                      # hdparm -S: 241 = 1 x 30 min
SMARTD_INTERVAL=3600              # seconds between smartd polls (must exceed spin-down)
SMART_SCHEDULE='(S/../../7/03|L/../01/./04)'
PURGE_CALENDAR='Sun *-*-* 03:05'
RECYCLE_DAYS=30

PART=${DISK}-part1
PKGS=(cryptsetup-bin systemd-cryptsetup gdisk e2fsprogs samba samba-vfs-modules
      smartmontools hdparm sysstat ufw avahi-daemon)

SMARTD_COMMENT="# 8TB data drive: short test Sun 03:00, long test 1st of month 04:00, temp warn 45C crit 55C"
SMARTD_LINE="$DISK -n standby,48,q -a -o on -S on -s $SMART_SCHEDULE -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner"
HDPARM_COMMENT="# $MNT archive disk: mostly idle, spin down after 30 min (241 = 1 x 30 min)"
SMB_HEADER="# Managed by useful-scripts/storage/setup-data-drive.sh"
PURGE_DIR=/etc/systemd/system/samba-recycle-purge.timer.d
STAMP=$(date +%Y%m%d-%H%M%S)

# ------------------------------------------------------------------ helpers
die()  { echo -e "\n❌ ERROR: $*" >&2; exit 1; }
step() { echo -e "\n==> $*"; }
ok()   { echo "    ✅ $*"; }
warn() { echo "    ⚠️  $*"; }
info() { echo "    $*"; }

# write_file PATH [MODE] < content. Returns 0 if the file changed, 1 if already identical.
# Backs up the old file and keeps its mode when replacing.
write_file() {
  local path=$1 mode=${2:-644} tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
  if [[ -e $path ]]; then
    mode=$(stat -c %a "$path")
    cp -a "$path" "$path.bak-$STAMP"
    info "backup: $path.bak-$STAMP"
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

# ------------------------------------------------------------------ renderers (pure: print desired content)
render_smb_conf() {
  cat <<EOF
[global]
   workgroup = WORKGROUP
   server string = bigrig
   server role = standalone server

   # Network exposure: SMB3 over 445 only, LAN + Tailscale + localhost only
   disable netbios = yes
   smb ports = 445
   server min protocol = SMB3_00
   server smb encrypt = desired
   hosts allow = 127.0.0.1 ::1 $LAN_NET $TS_NET
   hosts deny = ALL

   # No guest / anonymous access
   map to guest = never
   restrict anonymous = 2
   usershare allow guests = no

   # No printing
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

   # macOS compatibility (faster Finder, no ._ files)
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

[data]
   veto files = /lost+found/
   path = $MNT
   valid users = $OWNER
   read only = no
   browseable = yes
   create mask = 0644
   directory mask = 0755
   vfs objects = catia fruit streams_xattr recycle

   # Recycle bin: SMB deletes go to .recycle (purged after $RECYCLE_DAYS days by systemd timer)
   recycle:repository = .recycle
   recycle:keeptree = yes
   recycle:versions = yes
   recycle:touch = yes
   recycle:directory_mode = 0700
   recycle:exclude = *.tmp,*.temp,~\$*,.DS_Store,._*,Thumbs.db
   recycle:exclude_dir = .recycle
EOF
}

render_purge_service() {
  cat <<EOF
[Unit]
Description=Purge Samba recycle bin items older than $RECYCLE_DAYS days
RequiresMountsFor=$MNT
ConditionPathIsDirectory=$MNT/.recycle

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/find $MNT/.recycle -mindepth 1 -not -type d -atime +$RECYCLE_DAYS -delete
ExecStart=/usr/bin/find $MNT/.recycle -mindepth 1 -type d -empty -delete
EOF
}

render_purge_timer() {
  cat <<'EOF'
[Unit]
Description=Daily Samba recycle bin purge

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Drop-in: weekly instead of daily, aligned with the Sunday SMART short test (one spin-up).
render_purge_dropin() {
  cat <<EOF
[Timer]
OnCalendar=
OnCalendar=$PURGE_CALENDAR
RandomizedDelaySec=0
EOF
}

# smartd.conf: our entry goes first (explicit entries must precede DEVICESCAN).
render_smartd_conf() {  # $1 = current file (may not exist)
  printf '%s\n' "$SMARTD_COMMENT" "$SMARTD_LINE"
  [[ -f $1 ]] || return 0
  awk -v d="$DISK " -v c="$SMARTD_COMMENT" 'index($0, d) == 1 || $0 == c { next } { print }' "$1"
}

render_default_smartmontools() {  # $1 = current file
  local want="smartd_opts=\"--interval=$SMARTD_INTERVAL\""
  if [[ ! -f $1 ]]; then echo "$want"
  elif grep -qE '^smartd_opts=' "$1";   then sed -E "0,/^smartd_opts=.*/s##$want#" "$1"
  elif grep -qE '^#smartd_opts=' "$1";  then sed -E "0,/^#smartd_opts=.*/s##$want#" "$1"
  else cat "$1"; echo "$want"
  fi
}

render_hdparm_conf() {  # $1 = current file
  local block content=""
  block=$(printf '%s\n%s {\n\tspindown_time = %s\n}' "$HDPARM_COMMENT" "$DISK" "$SPINDOWN")
  [[ -f $1 ]] && content=$(<"$1")
  if [[ $content == *"$block"* ]]; then cat "$1"; return 0; fi
  if [[ -f $1 ]]; then
    awk -v d="$DISK {" -v c="$HDPARM_COMMENT" '
      $0 == c { next }
      $0 == d { skip = 1; next }
      skip && /^}/ { skip = 0; next }
      skip { next }
      { print }' "$1"
  fi
  printf '\n%s\n' "$block"
}

# set_tab_line FILE FIELD KEY LINE: make LINE the (only) entry whose field FIELD == KEY.
render_tab() {
  local file=$1 field=$2 key=$3 line=$4
  [[ -f $file ]] || { echo "$line"; return 0; }
  awk -v f="$field" -v k="$key" -v l="$line" '
    $0 !~ /^[[:space:]]*#/ && $f == k { if (!done) print l; done = 1; next }
    { print }
    END { if (!done) print l }' "$file"
}

# ------------------------------------------------------------------ disk preparation
format_blank_disk() {
  local dev=$1 serial=$2 total last_usable start=2048 end
  step "FORMAT: partition + LUKS2 + ext4 on $dev (serial $serial)"
  lsblk -nro MOUNTPOINTS "$dev" | grep -q '[^[:space:]]' && die "something on $dev is mounted"
  (( $(lsblk -nro TYPE "$dev" | grep -c '^part$' || true) == 0 )) \
    || die "$dev already has partitions; refusing to format (wipe it yourself if you really mean to)"
  [[ -z $(wipefs --noheadings --output TYPE "$dev" 2>/dev/null) ]] \
    || die "$dev has filesystem/RAID signatures; refusing to format (wipe it yourself if you really mean to)"

  # 4K-aligned at both ends: last usable GPT sector = total - 34
  total=$(cat "/sys/block/$(basename "$dev")/size")
  last_usable=$(( total - 34 ))
  end=$(( start + ( (last_usable - start + 1) / 8 * 8 ) - 1 ))
  info "partition 1: sectors $start..$end"

  echo; echo "    This ERASES $dev ($(lsblk -dno MODEL,SIZE "$dev" | xargs))."
  read -rp "    Type the disk serial ($serial) to continue: " ans
  [[ $ans == "$serial" ]] || die "aborted"

  sgdisk --zap-all "$DISK" >/dev/null
  sgdisk -n1:${start}:${end} -t1:8309 -c1:"$PART_NAME" "$DISK"
  udevadm settle
  for _ in $(seq 20); do [[ -b $PART ]] && break; sleep 0.5; done
  [[ -b $PART ]] || die "partition device did not appear"
  ok "partition created"

  info "LUKS2 format: type YES, then choose the RECOVERY passphrase (store it in your password manager)"
  cryptsetup luksFormat --type luks2 --sector-size 4096 --label "$LUKS_LABEL" "$PART"
  info "TPM2 enroll: enter the recovery passphrase once more"
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$PART"
  systemd-cryptsetup attach "$MAPPER" "$PART" none tpm2-device=auto,headless=true
  info "mkfs.ext4 (~10 min: writes inode tables now, not lazily for days afterward)"
  mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -L "$FS_LABEL" "/dev/mapper/$MAPPER"
  ok "disk formatted"
}

# ------------------------------------------------------------------ status (read-only)
status() {
  [[ -b $DISK ]] || die "$DISK not found"
  local dev st
  dev=$(readlink -f "$DISK")
  step "Disk"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$dev"
  info "model $(lsblk -dno MODEL "$dev")  serial $(lsblk -dno SERIAL "$dev")  firmware $(cat "/sys/block/$(basename "$dev")/device/rev")"

  step "Power state"
  st=$(smartctl -n standby -i "$DISK" 2>&1 | grep -iE 'power mode|standby mode' || true)
  info "${st:-unknown}"
  if [[ $st == *STANDBY* && $st != *IDLE* ]]; then
    info "(asleep: skipping SMART and keyslot reads so the disk is not woken)"
  else
    step "SMART"
    smartctl -H "$DISK" | grep -i 'result' || true
    smartctl -A "$DISK" | grep -E '^ *(4|5|9|12|187|188|193|194|197|198|199) ' || true
    step "Self-test log (latest)"
    smartctl -l selftest "$DISK" | sed -n '/^Num/,$p' | head -4 || true
    step "Keyslots"
    systemd-cryptenroll "$PART" || true
  fi

  step "Mount"
  findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS "$MNT" || warn "$MNT not mounted"
  mountpoint -q "$MNT" && df -h "$MNT" | tail -1

  step "Spin-down + smartd"
  grep -A2 -F "$DISK {" /etc/hdparm.conf | sed 's/^/    /' || warn "no hdparm.conf entry"
  info "smartd: $(systemctl is-active smartmontools)  $(grep -E '^smartd_opts=' /etc/default/smartmontools || echo 'default 30-min interval')"
  info "recent sleep/wake (smartd):"
  journalctl -u smartmontools --since -7d --no-pager -o short 2>/dev/null \
    | grep -E 'resuming checks|self-test|Temperature changed' | tail -6 | sed 's/^/      /' || true

  step "Share"
  info "smbd: $(systemctl is-active smbd)   purge timer next: $(systemctl show samba-recycle-purge.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
}

# ------------------------------------------------------------------ apply
apply() {
  local format=$1 dev serial ptype slots luks_uuid fs_uuid tmp hdr smb_changed=0 smartd_changed=0
  local p missing=()

  step "Packages"
  for p in "${PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    ok "installed: ${missing[*]}"
  else
    ok "all present"
  fi

  step "Disk"
  [[ -b $DISK ]] || die "$DISK not found (replacement disk? run with DISK=/dev/disk/by-id/...)"
  dev=$(readlink -f "$DISK")
  serial=$(lsblk -dno SERIAL "$dev")
  ok "$dev  $(lsblk -dno MODEL,SIZE "$dev" | xargs)  serial $serial"

  ptype=""
  [[ -b $PART ]] && ptype=$(blkid -p -o value -s TYPE "$PART" 2>/dev/null || true)
  if [[ $ptype == crypto_LUKS ]]; then
    ok "existing LUKS volume on $PART, keeping its data"
  elif (( format )); then
    format_blank_disk "$dev" "$serial"
  else
    die "no LUKS volume on $PART. If this is a NEW BLANK disk, re-run with --format-new-disk"
  fi

  step "Unlock keys (LUKS keyslots + TPM2)"
  systemd-cryptenroll --tpm2-device=list 2>/dev/null | grep -q /dev/tpm || die "no TPM2 device found"
  slots=$(systemd-cryptenroll "$PART")
  echo "$slots" | sed 's/^/    /'
  grep -qE 'password|recovery' <<<"$slots" \
    || warn "NO passphrase/recovery slot: a TPM reset would lock you out. Add one: sudo systemd-cryptenroll --password $PART"
  if grep -qw tpm2 <<<"$slots" && cryptsetup open --test-passphrase --token-only "$PART" 2>/dev/null; then
    ok "TPM2 unseals the volume"
  else
    warn "TPM2 slot missing or can't unseal (new machine / Secure Boot or firmware change), so (re)enrolling now"
    info "enter the recovery passphrase:"
    systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$PART"
    cryptsetup open --test-passphrase --token-only "$PART" || die "TPM2 unlock still fails after enrollment"
    ok "TPM2 enrolled (PCR $TPM2_PCRS)"
  fi

  step "crypttab (auto-unlock at boot)"
  luks_uuid=$(blkid -s UUID -o value "$PART")
  if render_tab /etc/crypttab 1 "$MAPPER" \
       "$MAPPER  UUID=$luks_uuid  none  tpm2-device=auto,headless=true,nofail" | write_file /etc/crypttab; then
    ok "updated"
  else
    ok "already correct"
  fi
  systemctl daemon-reload
  systemctl start "systemd-cryptsetup@$MAPPER.service" || die "unlock failed (journalctl -u systemd-cryptsetup@$MAPPER)"
  [[ -e /dev/mapper/$MAPPER ]] || die "/dev/mapper/$MAPPER missing after unlock"
  [[ $(blkid -s TYPE -o value "/dev/mapper/$MAPPER") == ext4 ]] || die "/dev/mapper/$MAPPER is not ext4"
  ok "/dev/mapper/$MAPPER open (ext4)"

  step "fstab + mount"
  fs_uuid=$(blkid -s UUID -o value "/dev/mapper/$MAPPER")
  if render_tab /etc/fstab 2 "$MNT" \
       "UUID=$fs_uuid  $MNT  ext4  noatime,nofail,x-systemd.device-timeout=30s  0  2" | write_file /etc/fstab; then
    ok "fstab updated"
  else
    ok "fstab already correct"
  fi
  findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1 || die "findmnt --verify rejected /etc/fstab"
  systemctl daemon-reload
  mkdir -p "$MNT"
  if ! mountpoint -q "$MNT"; then
    [[ -z $(ls -A "$MNT") ]] || die "$MNT is not empty while unmounted; move those files first"
    chattr +i "$MNT"
    mount "$MNT"
  fi
  mountpoint -q "$MNT" || die "$MNT failed to mount"
  [[ $(stat -c %U:%G "$MNT") == "$OWNER:$OWNER" ]] || chown "$OWNER:$OWNER" "$MNT"
  [[ $(stat -c %a "$MNT") == 755 ]] || chmod 755 "$MNT"
  ok "$MNT mounted, owned by $OWNER"

  step "Samba"
  tmp=$(mktemp)
  { echo "$SMB_HEADER"; render_smb_conf; } > "$tmp"
  if [[ -f /etc/samba/smb.conf ]] && cmp -s <(grep -v '^# Managed by' "$tmp") <(grep -v '^# Managed by' /etc/samba/smb.conf); then
    ok "smb.conf already correct"
  else
    testparm -s "$tmp" >/dev/null 2>&1 || { testparm -s "$tmp"; die "testparm rejected the new smb.conf"; }
    write_file /etc/samba/smb.conf < "$tmp" || true
    smb_changed=1
    ok "smb.conf written"
  fi
  rm -f "$tmp"
  if pdbedit -L 2>/dev/null | grep -q "^$OWNER:"; then
    ok "Samba user $OWNER exists"
  else
    info "set the Samba password for $OWNER (separate from the login password):"
    smbpasswd -a "$OWNER"
  fi
  systemctl disable --now nmbd >/dev/null 2>&1 || true
  systemctl mask nmbd >/dev/null 2>&1 || true
  systemctl enable smbd >/dev/null 2>&1
  if (( smb_changed )) || ! systemctl is-active --quiet smbd; then systemctl restart smbd; fi
  systemctl is-active --quiet smbd || die "smbd not running (journalctl -u smbd)"
  ok "smbd running, nmbd masked"
  systemctl enable --now avahi-daemon >/dev/null 2>&1 || warn "avahi-daemon not started (no $(hostname).local discovery)"

  step "Firewall (ufw)"
  if ip link show "$LAN_IF" >/dev/null 2>&1; then
    ufw allow in on "$LAN_IF" from "$LAN_NET" to any port 445 proto tcp comment 'SMB LAN' >/dev/null
    ufw allow in on "$LAN_IF" from "$LAN_NET" to any port 5353 proto udp comment 'mDNS LAN' >/dev/null
    ok "445/tcp + 5353/udp allowed on $LAN_IF from $LAN_NET"
  else
    warn "LAN interface $LAN_IF not found: edit LAN_IF and re-run"
  fi
  ufw allow in on "$TS_IF" to any port 445 proto tcp comment 'SMB Tailscale' >/dev/null
  ok "445/tcp allowed on $TS_IF"
  ufw status | grep -q 'Status: active' \
    || warn "ufw is inactive (rules saved). Enable after checking SSH access: sudo ufw allow OpenSSH && sudo ufw enable"

  step "Recycle-bin purge (weekly, $PURGE_CALENDAR)"
  local units_changed=0
  render_purge_service | write_file /etc/systemd/system/samba-recycle-purge.service && units_changed=1
  render_purge_timer   | write_file /etc/systemd/system/samba-recycle-purge.timer   && units_changed=1
  render_purge_dropin  | write_file "$PURGE_DIR/weekly.conf"                        && units_changed=1
  if (( units_changed )); then
    systemctl daemon-reload
    systemctl restart samba-recycle-purge.timer 2>/dev/null || true
  fi
  systemctl enable --now samba-recycle-purge.timer >/dev/null 2>&1
  ok "timer enabled, next run: $(systemctl show samba-recycle-purge.timer -p NextElapseUSecRealtime --value)"

  step "Spin-down after 30 min idle"
  if render_hdparm_conf /etc/hdparm.conf | write_file /etc/hdparm.conf; then
    hdparm -S "$SPINDOWN" "$DISK" >/dev/null   # (sends IDLE, so only on change: it spins the disk up)
    ok "hdparm.conf updated and applied"
  else
    ok "hdparm.conf already correct (udev reapplies it at boot)"
  fi

  step "smartd monitoring"
  render_smartd_conf /etc/smartd.conf | write_file /etc/smartd.conf && smartd_changed=1
  render_default_smartmontools /etc/default/smartmontools | write_file /etc/default/smartmontools && smartd_changed=1
  systemctl enable smartmontools >/dev/null 2>&1 || true
  if (( smartd_changed )) || ! systemctl is-active --quiet smartmontools; then
    smartd -q showtests >/dev/null || die "smartd rejected /etc/smartd.conf"
    systemctl restart smartmontools
  fi
  systemctl is-active --quiet smartmontools || die "smartd not running (journalctl -u smartmontools)"
  ok "smartd: hourly polls, -n standby, tests $SMART_SCHEDULE, temp 45/55C"

  step "sysstat (per-disk I/O history for sar -d)"
  [[ -f /etc/default/sysstat ]] && sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
  systemctl enable --now sysstat >/dev/null 2>&1 || warn "could not enable sysstat"
  ok "enabled"

  step "LUKS header backup"
  hdr=/root/luks-header-$serial.img
  tmp=$(mktemp -u /root/.luks-header.XXXXXX)
  cryptsetup luksHeaderBackup "$PART" --header-backup-file "$tmp"
  if [[ -f $hdr ]] && cmp -s "$tmp" "$hdr"; then
    rm -f "$tmp"; ok "$hdr is current"
  else
    [[ -f $hdr ]] && mv "$hdr" "$hdr.bak-$STAMP"
    mv "$tmp" "$hdr"; chmod 600 "$hdr"
    ok "wrote $hdr"
    warn "copy it OFF this machine (it's the only way in if the on-disk header gets damaged)"
  fi

  step "SMART baseline"
  if compgen -G "/root/smart-baseline-$serial*.txt" >/dev/null; then
    ok "already have one in /root"
  else
    { echo "### smartctl -x ($STAMP)"; smartctl -x "$DISK" || true
      echo; echo "### smartctl -l farm"; smartctl -l farm "$DISK" || true; } > "/root/smart-baseline-$serial.txt" 2>&1
    ok "saved /root/smart-baseline-$serial.txt"
  fi

  step "Done"
  local lan_ip
  lan_ip=$(ip -4 -br addr show "$LAN_IF" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  info "Mac:     smb://$(hostname).local/data   (or smb://${lan_ip:-<lan-ip>}/data)"
  info "Windows: \\\\${lan_ip:-<lan-ip>}\\data"
  info "Check health/sleep any time: sudo bash $0 --status"
}

main() {
  local format=0
  case ${1:-} in
    "")                ;;
    --format-new-disk) format=1 ;;
    --status)          [[ $EUID -eq 0 ]] || die "run with sudo"; status; exit 0 ;;
    -h|--help)         sed -n '2,8p' "$0"; exit 0 ;;
    *)                 die "unknown option '$1' (try --help)" ;;
  esac
  [[ $EUID -eq 0 ]] || die "run with: sudo bash $0"
  apply "$format"
}

# Run only when executed (sourcing exposes the render_* functions for dry checks).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
