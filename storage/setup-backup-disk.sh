#!/usr/bin/env bash
# setup-backup-disk.sh — build or restore smallrig's local backup HDD: plain ext4 (no
# encryption), mounted at /srv/backup, spun down when idle, SMART-monitored. It holds the
# nightly system-backup.sh restic repo. Idempotent: re-running only fixes drift.
#
#   sudo bash setup-backup-disk.sh                    # apply / restore (never formats)
#   sudo bash setup-backup-disk.sh --status           # read-only health report (won't wake the disk)
#   sudo bash setup-backup-disk.sh --format-new-disk  # ALSO wipe + partition + mkfs (asks for the serial)
#   DISK=/dev/disk/by-id/ata-XXXX sudo -E bash setup-backup-disk.sh ...   # a different/replacement disk
#
# What it reproduces (smallrig-linux, set up 2026-11-16):
#   Layout    GPT, 1 partition (1 MiB aligned), name "backup" -> ext4, label backup, -m 0.
#             No LUKS: this disk only holds the unencrypted restic repo of this machine.
#   Boot      fstab by UUID: noatime,nofail,device-timeout=30s (boot never blocks on a
#             missing disk). The mountpoint is chattr +i underneath, so nothing lands on
#             the root disk if the backup disk isn't mounted. Old fstab lines for this
#             disk (any UUID it had before a format, or the same mountpoint) are replaced.
#   Longevity Spin down after 30 min idle (force_spindown_time 241 in /etc/hdparm.conf;
#             udev reapplies it at boot). smartd uses -n standby (never wakes a sleeping
#             disk) and polls HOURLY, so its polls don't keep resetting the idle timer.
#   Monitor   smartd: short self-test Sun 03:00, long self-test 1st of month 04:00,
#             temp warn 45C / crit 55C. Tests that fall due while the disk sleeps run
#             when it next wakes. sysstat records per-disk I/O (`sar -d`).
#   Safety    SMART baseline saved in /root.
#
# Same pattern as setup-data-drive.sh (bigrig's encrypted, shared archive disk).
set -euo pipefail

# ------------------------------------------------------------------ config
DISK=${DISK:-/dev/disk/by-id/ata-ST9500424AS_5WS0M7B2}
PART_NAME=backup
FS_LABEL=backup
MNT=/srv/backup
SPINDOWN=241                      # hdparm -S: 241 = 1 x 30 min
SMARTD_INTERVAL=3600              # seconds between smartd polls (must exceed spin-down)
SMART_SCHEDULE='(S/../../7/03|L/../01/./04)'
PKGS=(gdisk e2fsprogs smartmontools hdparm sysstat)

PART=${DISK}-part1
SMARTD_COMMENT="# $MNT backup disk: short test Sun 03:00, long test 1st of month 04:00, temp warn 45C crit 55C"
SMARTD_LINE="$DISK -n standby,48,q -a -o on -S on -s $SMART_SCHEDULE -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner"
HDPARM_COMMENT="# $MNT backup disk: idle except the nightly backup, spin down after 30 min (241 = 1 x 30 min)"
STAMP=$(date +%Y%m%d-%H%M%S)

# ------------------------------------------------------------------ helpers
die()  { echo -e "\n❌ ERROR: $*" >&2; exit 1; }
step() { echo -e "\n==> $*"; }
ok()   { echo "    ✅ $*"; }
warn() { echo "    ⚠️  $*"; }
info() { echo "    $*"; }

# write_file PATH [MODE] < content. Returns 0 if the file changed, 1 if already identical.
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

# All /dev/disk/by-id names of $DISK (hdparm.conf may use any of them, e.g. wwn-...).
disk_aliases() {
  local dev l
  dev=$(readlink -f "$DISK")
  for l in /dev/disk/by-id/*; do
    [[ $(readlink -f "$l") == "$dev" ]] && echo "$l"
  done
  echo "$DISK"
}

# ------------------------------------------------------------------ renderers (pure: print desired content)
# fstab: drop lines for $MNT or any of the given old UUIDs, append ours.
render_fstab() {  # $1 = current file, $2 = our UUID, $3.. = old UUIDs to drop
  local file=$1 uuid=$2; shift 2
  awk -v m="$MNT" -v olds="$*" '
    BEGIN { n = split(olds, o, " "); for (i = 1; i <= n; i++) drop["UUID=" o[i]] = 1 }
    $0 !~ /^[[:space:]]*#/ && ($2 == m || ($1 in drop)) { next }
    { print }' "$file"
  echo "UUID=$uuid $MNT ext4 defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2"
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

# hdparm.conf: replace any block for this disk (under any of its names) with ours.
# force_spindown_time: plain spindown_time is skipped by the udev hook on drives
# without APM support, which this old laptop drive may lack.
render_hdparm_conf() {  # $1 = current file
  local block content=""
  block=$(printf '%s\n%s {\n\tforce_spindown_time = %s\n}' "$HDPARM_COMMENT" "$DISK" "$SPINDOWN")
  [[ -f $1 ]] && content=$(<"$1")
  if [[ $content == *"$block"* ]]; then cat "$1"; return 0; fi
  if [[ -f $1 ]]; then
    awk -v names="$(disk_aliases | tr '\n' ' ')" -v c="$HDPARM_COMMENT" '
      BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) mine[a[i] " {"] = 1 }
      $0 == c { next }
      ($0 in mine) { skip = 1; next }
      skip && /^}/ { skip = 0; next }
      skip { next }
      { print }' "$1"
  fi
  printf '\n%s\n' "$block"
}

# ------------------------------------------------------------------ status (read-only)
status() {
  step "Disk $DISK"
  [[ -e $DISK ]] || die "$DISK not found"
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINTS "$(readlink -f "$DISK")" | sed 's/^/    /'
  step "Mount"
  if mountpoint -q "$MNT"; then df -h "$MNT" | sed 's/^/    /'; else warn "$MNT not mounted"; fi
  grep -E "[[:space:]]$MNT[[:space:]]" /etc/fstab | sed 's/^/    fstab: /' || warn "no fstab line for $MNT"
  step "Power state + SMART health (skipped if asleep, so it won't wake the disk)"
  smartctl -n standby -H "$DISK" | grep -E "Power mode|STANDBY|overall-health|result" | sed 's/^/    /' || true
  step "Spin-down + smartd"
  grep -B1 -A2 -F "$DISK {" /etc/hdparm.conf | sed 's/^/    /' || warn "no hdparm.conf entry"
  info "smartd: $(systemctl is-active smartmontools)  $(grep -E '^smartd_opts=' /etc/default/smartmontools 2>/dev/null || echo 'default 30-min interval')"
  info "recent sleep/wake + tests (smartd):"
  journalctl -u smartmontools --since "-3 days" --no-pager -o short 2>/dev/null \
    | grep -E "resuming checks|Self-Test|self-test" | tail -6 | sed 's/^/      /' || true
}

# ------------------------------------------------------------------ format (destructive)
format_disk() {
  local dev root_src olds=() p
  dev=$(readlink -f "$DISK")
  root_src=$(findmnt -no SOURCE /)
  lsblk -no PKNAME "$root_src" | grep -qx "$(basename "$dev")" && die "$dev holds / - refusing"
  step "FORMAT $DISK"
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINTS "$dev" | sed 's/^/    /'
  local serial ans
  serial=$(lsblk -dno SERIAL "$dev" | xargs)
  echo
  read -rp "    This ERASES everything on $dev ($(lsblk -dno MODEL "$dev" | xargs)). Type its serial ($serial) to continue: " ans
  [[ -n $serial && $ans == "$serial" ]] || die "serial didn't match, nothing changed"

  # remember old filesystem UUIDs so their fstab lines get replaced
  mapfile -t olds < <(lsblk -nro UUID "$dev" | grep . || true)
  printf '%s\n' "${olds[@]}" > "/run/setup-backup-disk.old-uuids"
  for p in $(lsblk -nro MOUNTPOINTS "$dev" | grep . || true); do
    umount "$p" && info "unmounted $p"
  done
  lsblk -nro MOUNTPOINTS "$dev" | grep -q . && die "something on $dev is still mounted"

  for p in "$DISK"-part*; do [[ -e $p ]] && wipefs -a "$p" >/dev/null; done
  wipefs -a "$DISK" >/dev/null
  printf 'label: gpt\n,,L,name=%s\n' "$PART_NAME" | sfdisk -q "$DISK"
  udevadm settle
  for _ in {1..20}; do [[ -e $PART ]] && break; sleep 0.5; done
  [[ -e $PART ]] || die "$PART didn't appear"
  mkfs.ext4 -q -F -L "$FS_LABEL" -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$PART"
  ok "partitioned + formatted ext4 (label $FS_LABEL)"
}

# ------------------------------------------------------------------ apply
apply() {
  local format=$1 uuid serial olds=()
  step "Packages"
  local missing=()
  for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if (( ${#missing[@]} )); then
    apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}" >/dev/null
    ok "installed ${missing[*]}"
  else
    ok "all present"
  fi

  [[ -e $DISK ]] || die "$DISK not found (set DISK=/dev/disk/by-id/... for a replacement disk)"
  serial=$(lsblk -dno SERIAL "$(readlink -f "$DISK")" | xargs)
  (( format )) && format_disk
  [[ -f /run/setup-backup-disk.old-uuids ]] && mapfile -t olds < /run/setup-backup-disk.old-uuids

  step "Filesystem"
  [[ -e $PART ]] || die "$PART not found. If this is a NEW disk, re-run with --format-new-disk"
  [[ $(blkid -s TYPE -o value "$PART") == ext4 && $(blkid -s LABEL -o value "$PART") == "$FS_LABEL" ]] \
    || die "$PART is not ext4 labeled '$FS_LABEL'. Look at it; for a new disk use --format-new-disk"
  uuid=$(blkid -s UUID -o value "$PART")
  ok "ext4 $FS_LABEL  UUID=$uuid"

  step "Mount $MNT"
  mkdir -p "$MNT"
  if ! mountpoint -q "$MNT"; then
    [[ -z $(ls -A "$MNT") ]] || die "$MNT is not empty and not mounted - look at it first"
    chattr +i "$MNT"   # nothing can land on the root disk if the backup disk fails to mount
  fi
  if render_fstab /etc/fstab "$uuid" "${olds[@]}" | write_file /etc/fstab; then
    ok "fstab updated"
  else
    ok "fstab already correct"
  fi
  findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1 || warn "findmnt --verify reports warnings for /etc/fstab"
  systemctl daemon-reload
  mountpoint -q "$MNT" || mount "$MNT"
  chown root:root "$MNT"; chmod 755 "$MNT"
  ok "mounted ($(df -h --output=avail "$MNT" | tail -1 | xargs) free)"
  rm -f /run/setup-backup-disk.old-uuids
  for d in /run/media/*/*; do   # leftovers from the old desktop automount
    [[ -d $d ]] && ! mountpoint -q "$d" && [[ -z $(ls -A "$d") ]] && rmdir "$d" 2>/dev/null && info "removed empty $d"
  done

  step "Spin-down after 30 min idle"
  if render_hdparm_conf /etc/hdparm.conf | write_file /etc/hdparm.conf; then
    hdparm -S "$SPINDOWN" "$DISK" >/dev/null   # (sends IDLE, so only on change: it spins the disk up)
    ok "hdparm.conf updated and applied"
  else
    ok "hdparm.conf already correct (udev reapplies it at boot)"
  fi

  step "smartd monitoring"
  local smartd_changed=0
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

  step "SMART baseline"
  if compgen -G "/root/smart-baseline-$serial*.txt" >/dev/null; then
    ok "already have one in /root"
  else
    { echo "### smartctl -x ($STAMP)"; smartctl -x "$DISK" || true; } > "/root/smart-baseline-$serial.txt" 2>&1
    ok "saved /root/smart-baseline-$serial.txt"
  fi
  smartctl -H "$DISK" | grep -q "PASSED" && ok "SMART overall health: PASSED" \
    || warn "SMART health is NOT 'PASSED': sudo smartctl -a $DISK"

  step "Done"
  info "Next: sudo bash ~/code/useful-scripts/storage/system-backup.sh install"
  info "Check health/sleep any time: sudo bash $0 --status"
}

main() {
  local format=0
  case ${1:-} in
    "")                ;;
    --format-new-disk) format=1 ;;
    --status)          [[ $EUID -eq 0 ]] || die "run with sudo"; status; exit 0 ;;
    -h|--help)         sed -n '2,9p' "$0"; exit 0 ;;
    *)                 die "unknown option '$1' (try --help)" ;;
  esac
  [[ $EUID -eq 0 ]] || die "run with: sudo bash $0"
  apply "$format"
}

# Run only when executed (sourcing exposes the render_* functions for dry checks).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
