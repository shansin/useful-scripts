#!/usr/bin/env bash
# system-backup.sh — nightly restic backup of the whole bigrig-linux system to the
# encrypted data disk, plus an offline "restore kit" for bare-metal recovery.
#
#   sudo bash system-backup.sh install   # set up repo, excludes, timer (idempotent)
#   sudo system-backup run               # back up now (the timer runs this nightly)
#   sudo system-backup run --maintenance # ...and also prune + verify (auto on Sundays)
#   sudo system-backup status            # snapshots, last success, next run
#
# What it does
#   Repo      /srv/data/Backups/bigrig-linux (root-only 0700) on the LUKS-encrypted data
#             disk. `install` asks for a restic password: type your own (saved root-only
#             in /root/.config/restic/ so nightly runs are unattended; keep it in your
#             password manager too) or press Enter for none (--insecure-no-password,
#             restic >= 0.17; the disk encryption still protects it). Copying the repo to
#             unencrypted media? `restic copy` it into a password-protected repo instead.
#   Scope     / and /boot/efi, --one-file-system (skips /srv/data, /mnt/backup, /proc...).
#             Includes /etc, /home (with ~/.ssh), /var/lib/docker (images + volumes),
#             Ollama models, /opt. Excludes swap, tmp, apt debs, docker build cache,
#             ~/.cache except huggingface, Trash, CACHEDIR.TAG-marked dirs.
#   Metadata  Before each run: partition layout (sfdisk), filesystem UUIDs, EFI boot
#             entries, package lists, docker images -> /var/backups/system-metadata
#             (so it's inside every snapshot) and the restore kit.
#   Kit       /srv/data/Backups/bigrig-linux-restore: restic binary + this script +
#             metadata. Guide: /srv/data/Backups/README-RESTORE.txt (copy in the kit as
#             RESTORE.txt), a step-by-step "root NVMe died" walkthrough with this
#             machine's disks, IDs and commands, regenerated on every run.
#   Schedule  04:45 nightly (after the T3 03:30 / numz 04:15 DB dumps), catches up after
#             downtime. Lowest CPU priority. Keep 7 daily / 4 weekly / 6 monthly / 1 yearly.
#             Sundays: prune + `restic check --read-data-subset=5%`.
set -euo pipefail

# ------------------------------------------------------------------ config
NAME=bigrig-linux
DATA_MNT=/srv/data
REPO=$DATA_MNT/Backups/$NAME
KIT=$DATA_MNT/Backups/$NAME-restore
PASSFILE=/root/.config/restic/$NAME.pass   # present = password mode, absent = no password
EXCLUDES=/etc/restic/$NAME.excludes
META=/var/backups/system-metadata
STATE=/var/lib/system-backup
INSTALLED=/usr/local/sbin/system-backup
UNIT=system-backup
SCHEDULE='*-*-* 04:45:00'
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 1)
CHECK_SUBSET=5%
BACKUP_PATHS=(/ /boot/efi)

export RESTIC_REPOSITORY=$REPO
STAMP=$(date +%Y%m%d-%H%M%S)

# Password mode when PASSFILE exists; otherwise the repo has no password and restic
# requires --insecure-no-password on every command.
restic() {
  if [[ -s $PASSFILE ]]; then RESTIC_PASSWORD_FILE=$PASSFILE command restic "$@"
  else command restic --insecure-no-password "$@"; fi
}
mode_desc() { if [[ -s $PASSFILE ]]; then echo "password in $PASSFILE"; else echo "no password"; fi; }
RESTIC_BIN=$(type -P restic || true)

# ------------------------------------------------------------------ helpers
die()  { echo -e "\n❌ ERROR: $*" >&2; exit 1; }
step() { echo -e "\n==> $*"; }
ok()   { echo "    ✅ $*"; }
warn() { echo "    ⚠️  $*"; }
info() { echo "    $*"; }

# write_file PATH [MODE] < content. Returns 0 if changed, 1 if already identical.
write_file() {
  local path=$1 mode=${2:-644} tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
  [[ -e $path ]] && cp -a "$path" "$path.bak-$STAMP" && info "backup: $path.bak-$STAMP"
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

need_root()  { [[ $EUID -eq 0 ]] || die "run with sudo"; }
need_mount() { mountpoint -q "$DATA_MNT" || die "$DATA_MNT is not mounted (data disk locked or missing?)"; }
repo_ready() { [[ -f $REPO/config ]]; }

# ------------------------------------------------------------------ renderers
render_excludes() {
  cat <<'EOF'
# restic excludes for system-backup (one pattern per line, ! re-includes)
/swap.img
/tmp/*
/var/tmp/*
/var/crash/*
/var/cache/apt/archives/*.deb
/var/lib/docker/buildkit
/root/.cache
/home/*/.cache/*
!/home/*/.cache/huggingface
/home/*/.local/share/Trash
/lost+found
EOF
}

render_service() {
  cat <<EOF
[Unit]
Description=restic whole-system backup to $REPO
RequiresMountsFor=$DATA_MNT

[Service]
Type=oneshot
ExecStart=$INSTALLED run
Nice=19
CPUSchedulingPolicy=batch
IOSchedulingClass=idle
TimeoutStartSec=12h
EOF
}

render_timer() {
  cat <<EOF
[Unit]
Description=Nightly restic whole-system backup

[Timer]
OnCalendar=$SCHEDULE
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
}

# ------------------------------------------------------------------ metadata + restore kit
collect_metadata() {
  local root_src root_disk esp_src swap_bytes=0 data_disk
  root_src=$(findmnt -no SOURCE /)
  data_disk=$(lsblk -s -nro NAME,TYPE "$(findmnt -no SOURCE "$DATA_MNT")" | awk '$2 == "disk" { print $1; exit }' || true)
  root_disk=/dev/$(lsblk -no PKNAME "$root_src")
  esp_src=$(findmnt -no SOURCE /boot/efi || true)
  [[ -f /swap.img ]] && swap_bytes=$(stat -c %s /swap.img)
  [[ -n $(lsblk -no UUID "$root_src") ]] || die "could not read the root filesystem UUID"
  [[ -z $esp_src || -n $(lsblk -no UUID "$esp_src") ]] || die "could not read the ESP UUID"

  mkdir -p "$META"
  sfdisk -d "$root_disk"                       > "$META/sfdisk.txt"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS > "$META/lsblk.txt"
  blkid                                        > "$META/blkid.txt" || true
  cp /etc/fstab "$META/fstab"
  [[ -f /etc/crypttab ]] && cp /etc/crypttab "$META/crypttab"
  efibootmgr -v                                > "$META/efibootmgr.txt" 2>&1 || true
  cat /proc/cmdline                            > "$META/cmdline.txt"
  dpkg --get-selections                        > "$META/dpkg-selections.txt"
  apt-mark showmanual                          > "$META/apt-manual.txt"
  snap list                                    > "$META/snap-list.txt" 2>&1 || true
  docker image ls                              > "$META/docker-images.txt" 2>&1 || true
  { uname -a; cat /etc/os-release; } > "$META/os.txt"
  cat > "$META/restore-info.env" <<EOF
# Values the restore needs (captured $(date -Is))
HOST=$(hostname)
ROOT_DISK=$root_disk
ROOT_DISK_MODEL="$(lsblk -dno MODEL "$root_disk" | xargs)"
ROOT_DISK_BYTES=$(lsblk -dbno SIZE "$root_disk")
ROOT_PART=$root_src
ROOT_FSTYPE=$(findmnt -no FSTYPE /)
ROOT_UUID=$(lsblk -no UUID "$root_src")
ROOT_LABEL=$(lsblk -no LABEL "$root_src")
ESP_PART=$esp_src
ESP_UUID=$( [[ -n $esp_src ]] && lsblk -no UUID "$esp_src")
SWAP_BYTES=$swap_bytes
DATA_DISK=/dev/$data_disk
DATA_DISK_MODEL="$(lsblk -dno MODEL "/dev/$data_disk" | xargs)"
DATA_DISK_SERIAL=$(lsblk -dno SERIAL "/dev/$data_disk")
BOARD="$(cat /sys/class/dmi/id/board_vendor /sys/class/dmi/id/board_name 2>/dev/null | xargs)"
EOF
  # Every disk with its role, so the right one is picked in a crisis (names can change).
  local n role
  for n in $(lsblk -dn -e7 -o NAME); do
    if   [[ /dev/$n == "$root_disk" ]]; then role="<- ROOT: restore target (replace with the new disk)"
    elif [[ $n == "$data_disk" ]];      then role="<- DATA: holds these backups"
    elif lsblk -nro FSTYPE "/dev/$n" | grep -qi bitlocker; then role="<- WINDOWS (BitLocker): leave alone"
    else                                     role="<- other: not involved, leave alone"; fi
    printf '    %-9s %-7s %-28s %-21s %s\n' "$n" "$(lsblk -dno SIZE "/dev/$n" | xargs)" \
      "$(lsblk -dno MODEL "/dev/$n" | xargs)" "$(lsblk -dno SERIAL "/dev/$n" | xargs)" "$role"
  done > "$META/disks.txt"
}

# The disaster-recovery guide. Printed from restore-info.env so the IDs are always current.
render_restore_doc() {  # $1 = latest snapshot description
  # shellcheck disable=SC1091
  source "$META/restore-info.env"
  local esp_serial=${ESP_UUID//-/} r_flags pw_need pw_note
  local root_sfx=${ROOT_PART#"$ROOT_DISK"} esp_sfx=${ESP_PART#"$ROOT_DISK"}
  if [[ -s $PASSFILE ]]; then
    r_flags="--no-lock"
    pw_need="[ ] Your RESTIC password (password manager); restic asks for it"
    pw_note="     # restic asks for YOUR restic password each time (or: export RESTIC_PASSWORD=...)"
  else
    r_flags="--insecure-no-password --no-lock"
    pw_need="[ ] (no restic password: this repo was set up without one)"
    pw_note=""
  fi
  cat <<EOF
==========================================================================
  $HOST DISASTER RECOVERY: READ THIS FIRST
==========================================================================
Regenerated automatically on every backup. Do not edit (it gets replaced).
KEEP A COPY OFF THIS DISK (Mac, phone, printout): you can only read this one after
step 2, unlocking the data disk. It's on the "data" share as Backups/README-RESTORE.txt.
Last refreshed: $(date '+%F %R %Z')      Latest snapshot: $1

WHAT IS IN THIS FOLDER  (Backups/ on the 8TB data disk)
  $HOST/            restic repository: nightly snapshots of the WHOLE root disk
                         (Ubuntu, /etc, /home, Docker images+volumes, Ollama models)
  $HOST-restore/    restore kit: restic program, disk layout, package lists,
                         the backup script, and a copy of this guide (RESTORE.txt)
  README-RESTORE.txt     this file

WHEN TO USE THIS
  The root NVMe ($ROOT_DISK_MODEL) died, got wiped, or Linux is broken beyond
  repair. This rebuilds it EXACTLY as of the last snapshot, in about 1.5 hours.
  The data disk is only READ, never changed.

WHAT YOU NEED
  [ ] A replacement NVMe at least as big as the old one ($ROOT_DISK_BYTES bytes, ~2 TB)
  [ ] A USB stick (8 GB+), written on any computer:
        Ubuntu Desktop 26.04 from https://ubuntu.com/download/desktop
        written with balenaEtcher (Mac/Windows) or Rufus (Windows)
  [ ] The DATA-DISK passphrase (password manager)
  $pw_need
  [ ] ~1.5 hours, a keyboard and a monitor on this machine

DISKS IN THIS MACHINE AT LAST BACKUP: identify disks by MODEL + SERIAL, names can change
$(cat "$META/disks.txt")
  !! Two disks can be about the same size. ALWAYS confirm model + serial before
     erasing anything (step 3).

--------------------------------------------------------------------------
STEP 1  Boot the USB stick
  - Plug it in, power on, tap F8 for the boot menu ($BOARD;
    F2/Del opens the BIOS). Pick the "UEFI: <your USB stick>" entry.
    Secure Boot can stay ON.
  - Choose "Try Ubuntu" (NOT "Install"). Open a terminal (Ctrl+Alt+T), then:
      sudo -i

STEP 2  Unlock the data disk, READ-ONLY so the backups can't be damaged
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE
    -> find $DATA_DISK_MODEL (serial $DATA_DISK_SERIAL); its partition says crypto_LUKS
  cryptsetup open /dev/sdX1 data          # <- that partition, e.g. sda1; asks the passphrase
  mkdir -p /mnt/data && mount -o ro /dev/mapper/data /mnt/data
  KIT=/mnt/data/Backups/$HOST-restore
  export RESTIC_REPOSITORY=/mnt/data/Backups/$HOST
  R="\$KIT/restic $r_flags"
  \$R snapshots                            # list of backups, newest at the bottom${pw_note:+
$pw_note}

STEP 3  Choose the TARGET disk. IT WILL BE ERASED.
  lsblk -d -o NAME,SIZE,MODEL,SERIAL
  T=/dev/nvme1n1        # <- set this to the NEW root disk. Check model + serial!

STEP 4  Partition and format it with the old IDs (so the boot setup works unchanged)
  sfdisk \$T < \$KIT/metadata/sfdisk.txt
  lsblk \$T                                # expect 2 partitions: big root + 1 GB EFI
  ROOT=\${T}$root_sfx   ESP=\${T}$esp_sfx
  mkfs.vfat -F 32 -i $esp_serial \$ESP
  mkfs.ext4 -U $ROOT_UUID ${ROOT_LABEL:+-L $ROOT_LABEL }\$ROOT

STEP 5  Restore everything (40-60 min, progress is shown)
  mkdir -p /mnt/root && mount \$ROOT /mnt/root
  mkdir -p /mnt/root/boot/efi && mount \$ESP /mnt/root/boot/efi
  \$R restore latest --target /mnt/root
  # older backup instead? replace "latest" with an ID from "\$R snapshots"

STEP 6  Recreate what the backup skips on purpose
  mkdir -p /mnt/root/{proc,sys,dev,run,tmp,var/tmp,srv/data,mnt/backup}
  chmod 1777 /mnt/root/tmp /mnt/root/var/tmp
  fallocate -l $SWAP_BYTES /mnt/root/swap.img && chmod 600 /mnt/root/swap.img && mkswap /mnt/root/swap.img

STEP 7  Make it bootable
  for d in dev dev/pts proc sys sys/firmware/efi/efivars run; do mount --bind /\$d /mnt/root/\$d; done
  chroot /mnt/root grub-install
  chroot /mnt/root update-grub
  chroot /mnt/root dracut --regenerate-all --force

STEP 8  Reboot
  umount -R /mnt/root; umount /mnt/data; reboot       # pull out the USB stick
  Doesn't boot? Tap F8 and pick "ubuntu" on the new disk.

STEP 9  After the first boot
  - Log in normally. Docker apps (T3, numz) start by themselves; check:  docker ps
  - /srv/data should mount by itself. If it doesn't (new motherboard/TPM, BIOS reset):
      sudo bash ~/code/useful-scripts/storage/setup-data-drive.sh
    (asks the data-disk passphrase once and re-links it to the TPM)
  - Turn backups back on:  sudo bash ~/code/useful-scripts/storage/system-backup.sh install
  - Anything broken?       systemctl --failed

--------------------------------------------------------------------------
IF SOMETHING GOES WRONG
  * "\$KIT/restic: No such file": the kit is missing. With internet:
        apt update && apt install -y restic      then use  R="restic $r_flags"
  * New disk is SMALLER and sfdisk refuses the layout:
        cp \$KIT/metadata/sfdisk.txt /tmp/layout.txt
        edit /tmp/layout.txt: delete the "last-lba:" line, and delete "size=..., "
        from the ROOT partition's line (root is the last partition, so it fills the disk)
        sfdisk \$T < /tmp/layout.txt
  * restore prints errors about ownership/permissions under /boot/efi: harmless
    (the EFI partition is FAT, which can't store them). Other errors: re-run it.
  * The restore stopped halfway: run the same restore command again.
  * Stuck at a "grub>" prompt or no boot entry: boot the USB again, redo steps 2, 5
    (mount commands only), and 7.
  * Only the DATA disk died (Linux is fine): none of this applies. Put in the new
    disk and run:  sudo bash ~/code/useful-scripts/storage/setup-data-drive.sh --format-new-disk
    then  sudo bash ~/code/useful-scripts/storage/system-backup.sh install
    (backup history starts over unless another copy exists elsewhere)
EOF
}

write_kit() {  # $1 = latest snapshot description
  mkdir -p "$KIT"
  chmod 700 "$KIT"
  cmp -s "$RESTIC_BIN" "$KIT/restic" 2>/dev/null || install -m 755 "$RESTIC_BIN" "$KIT/restic"
  install -m 755 "$(readlink -f "$0")" "$KIT/system-backup.sh"
  rm -rf "$KIT/metadata"; cp -a "$META" "$KIT/metadata"
  render_restore_doc "${1:-none yet}" > "$KIT/RESTORE.txt"
  install -m 644 "$KIT/RESTORE.txt" "$DATA_MNT/Backups/README-RESTORE.txt"
}

# ------------------------------------------------------------------ commands
cmd_install() {
  need_root
  step "Packages"
  if [[ -z $RESTIC_BIN ]]; then
    apt-get update && apt-get install -y --no-install-recommends restic
    RESTIC_BIN=$(type -P restic)
  fi
  ok "restic $(restic version | awk '{print $2}')"
  for t in sfdisk efibootmgr; do command -v "$t" >/dev/null || warn "$t missing (metadata will be incomplete)"; done

  step "Repository $REPO"
  need_mount
  mkdir -p "$REPO"
  chown root:root "$REPO"; chmod 700 "$REPO"
  repo_ready || [[ -z $(ls -A "$REPO") ]] || die "$REPO is not empty and not a restic repo. Refusing to touch it"
  mkdir -p "$(dirname "$PASSFILE")"; chmod 700 "$(dirname "$PASSFILE")"
  local pw pw2
  if repo_ready; then
    if restic cat config >/dev/null 2>&1; then
      ok "repository opens ($(mode_desc))"
    else
      # e.g. a rebuilt machine: the repo exists but this box doesn't know its password
      read -rsp "    Repository password (Enter if it has none): " pw; echo
      if [[ -n $pw ]]; then ( umask 077; printf '%s\n' "$pw" > "$PASSFILE" ); else rm -f "$PASSFILE"; fi
      restic cat config >/dev/null 2>&1 || { rm -f "$PASSFILE"; die "that password does not open $REPO"; }
      ok "repository opens ($(mode_desc))"
    fi
  else
    info "Choose a restic password. It's saved root-only in $PASSFILE so nightly runs"
    info "work unattended (keep a copy in your password manager). Or press Enter for no"
    info "password: the repo is still protected by the data-disk encryption."
    read -rsp "    Password: " pw; echo
    if [[ -n $pw ]]; then
      read -rsp "    Again:    " pw2; echo
      [[ $pw == "$pw2" ]] || die "passwords don't match, nothing created"
      ( umask 077; printf '%s\n' "$pw" > "$PASSFILE" )
    else
      rm -f "$PASSFILE"
    fi
    restic init >/dev/null
    ok "repository initialized ($(mode_desc))"
  fi

  step "Restore kit + guide"
  collect_metadata
  if [[ -f $KIT/RESTORE.txt ]]; then
    write_kit "$(grep -m1 -o 'Latest snapshot: .*' "$KIT/RESTORE.txt" | cut -d' ' -f3-)"
  else
    write_kit "none yet (run: sudo system-backup run)"
  fi
  ok "$DATA_MNT/Backups/README-RESTORE.txt written"

  step "Config + scheduled job"
  if render_excludes | write_file "$EXCLUDES"; then ok "excludes written"; else ok "excludes unchanged"; fi
  if cmp -s "$(readlink -f "$0")" "$INSTALLED" 2>/dev/null; then ok "$INSTALLED up to date"
  else install -m 755 "$(readlink -f "$0")" "$INSTALLED"; ok "installed $INSTALLED"; fi
  local changed=0
  render_service | write_file /etc/systemd/system/$UNIT.service && changed=1
  render_timer   | write_file /etc/systemd/system/$UNIT.timer   && changed=1
  (( changed )) && systemctl daemon-reload
  systemctl enable --now $UNIT.timer >/dev/null 2>&1
  ok "timer enabled, next run: $(systemctl show $UNIT.timer -p NextElapseUSecRealtime --value)"

  step "Done"
  if compgen -G "$STATE/last-success" >/dev/null; then
    info "Check it any time:  sudo system-backup status"
  else
    info "Run the first backup now (~420 GB, about an hour; use tmux):  sudo system-backup run"
  fi
}

cmd_run() {
  need_root; need_mount
  repo_ready || die "no repository at $REPO. Run: sudo bash $0 install"
  local maint=0 rc=0 snap
  [[ ${1:-} == --maintenance || $(date +%u) == 7 ]] && maint=1

  exec 9>/run/lock/$UNIT.lock
  flock -n 9 || die "another backup is already running"

  step "Metadata"
  collect_metadata
  ok "saved to $META"

  step "Backup ${BACKUP_PATHS[*]}"
  restic backup --one-file-system --exclude-caches --exclude-file "$EXCLUDES" \
    --tag system "${BACKUP_PATHS[@]}" || rc=$?
  case $rc in
    0) ok "snapshot created" ;;
    3) warn "snapshot created, but some files could not be read (usually files that vanished mid-backup)" ;;
    *) die "restic backup failed (exit $rc)" ;;
  esac
  snap=$(restic snapshots --latest 1 --json | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)

  step "Retention ${KEEP[*]}"
  restic forget "${KEEP[@]}" | tail -3
  if (( maint )); then
    step "Maintenance: prune + verify $CHECK_SUBSET of data"
    restic prune | tail -3
    restic check --read-data-subset="$CHECK_SUBSET" || die "restic check found problems"
    ok "repository verified"
  fi

  step "Restore kit + guide"
  write_kit "$snap ($(date '+%F %R'))"
  ok "$KIT and $DATA_MNT/Backups/README-RESTORE.txt refreshed"

  mkdir -p "$STATE"
  echo "$(date +%s) $(date -Is) snapshot=$snap rc=$rc" > "$STATE/last-success"
  step "Done: snapshot $snap"
}

cmd_status() {
  need_root
  step "Last successful run"
  if [[ -f $STATE/last-success ]]; then
    local epoch age_h
    read -r epoch _ < "$STATE/last-success"
    age_h=$(( ( $(date +%s) - epoch ) / 3600 ))
    info "$(cut -d' ' -f2- "$STATE/last-success")  (${age_h}h ago)"
    (( age_h <= 36 )) || warn "older than 36h: check  journalctl -u $UNIT"
  else
    warn "never"
  fi
  step "Scheduled job"
  info "timer: $(systemctl is-active $UNIT.timer)   next: $(systemctl show $UNIT.timer -p NextElapseUSecRealtime --value)"
  info "last job result: $(systemctl show $UNIT.service -p Result --value)"
  step "Snapshots (reads the data disk)"
  need_mount
  restic snapshots --compact | tail -12
  info "repo size on disk: $(du -sh "$REPO" | cut -f1)"
}

case ${1:-} in
  install) cmd_install ;;
  run)     shift; cmd_run "$@" ;;
  status)  cmd_status ;;
  *)       sed -n '2,8p' "$0"; exit 1 ;;
esac
