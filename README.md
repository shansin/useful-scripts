# 🛠️ Useful Scripts

A collection of high-performance utility scripts for system maintenance, backup automation, and AI model management.

---

## 📋 Table of Contents
- [backup/ (Directory Backup Utility)](#1-backup---directory-backup-utility)
- [link_ollama_lmstudio_models.py (Ollama<>Lm Studio Linker)](#2-link_ollama_lmstudio_modelspy---ollama-to-lm-studio-linker)
- [setup_sleep_schedule.sh (Auto Sleep/Wake Scheduler)](#3-setup_sleep_schedulesh---auto-sleepwake-scheduler)
- [ollama-metrics/ (Ollama API Metrics Dashboard)](#4-ollama-metrics---ollama-api-metrics-dashboard)
- [passwordless-ssh-setup.sh (Passwordless SSH Setup)](#5-passwordless-ssh-setupsh---passwordless-ssh-setup)
- [install-claude-statusline.sh (Claude Code Status Line)](#6-install-claude-statuslinesh---claude-code-status-line)
- [recreate-mac-shell.sh (Mac zsh Prompt Setup)](#7-recreate-mac-shellsh---mac-zsh-prompt-setup)
- [storage/setup-data-drive.sh (Encrypted Archive HDD Setup)](#8-storagesetup-data-drivesh---encrypted-archive-hdd-setup)
- [storage/system-backup.sh (Whole-System restic Backup)](#9-storagesystem-backupsh---whole-system-restic-backup), incl. smallrig and `setup-backup-disk.sh`
- [Getting Started](#getting-started)

---

## 📦 1. `backup/` - Directory Backup Utility

A robust, high-performance Python project designed for automated, timestamped backups. It leverages **7-Zip** for superior compression speed and efficiency. Lives in its own folder (`backup/`) with its own `pyproject.toml` / `uv.lock`.

### ✨ Key Features
- **🚀 Turbocharged Compression**: Uses 7-Zip (`7z.exe`) via subprocess for lightning-fast archiving.
- **📁 Backup Types**:
    - `zip`: Uses 7-Zip for high-performance compression.
    - `normal`: Standard directory copy with timestamps.
    - `incremental`: Syncs only new files to a fixed destination folder (no timestamps), ideal for large data sets or photos and videos.
- **⏱️ Performance Metrics**: Automatically calculates and logs the duration of each backup task.
- **⚙️ Granular Control**:
    - Manage multiple tasks via a single `backup_config.yml` file.
    - Set individual backup types per task.
    - Toggle tasks on/off with the `run` parameter.
    - **Override capability**: Run specific tasks via command line, bypassing the configuration's skip status.
- **🛡️ Robustness**: Gracefully handles missing source paths and permission issues.

### 🚀 Usage

All commands below are run from inside the `backup/` directory:

```powershell
cd backup
```

#### Standard Execution
Run all tasks where `run: true` is set in the config:
```powershell
uv run backup.py
```

#### Targeted Execution (Override)
Run a specific task immediately, even if it is disabled (`run: false`) in the config:
```powershell
uv run backup.py "YourTaskName"
```

### 🔧 Configuration (`backup_config.yml`)

The script looks for `backup_config.yml` in the current working directory (`backup/`). Copy `[Example] backup_config.yml` to `backup_config.yml` and edit it to match your setup.

```yaml
backup_settings:
  destination: "<DestinationPath>"           # Global backup root
  timestamp_format: "%Y%m%d_%H%M%S"       # Custom date/time format
  seven_zip_path: "C:/Program Files/7-Zip/7z.exe" # Path to 7z executable

tasks:
  - name: "<TaskName>"                  # Unique task identifier
    source: "<SourcePath>"
    type: "zip"                           # Type: zip, normal, or incremental
    run: false                            # Set to false to skip during bulk runs
    
  - name: "<Task2Name>"
    source: "<Source2Path>"
    type: "incremental"
    run: true
```

---

## 🤖 2. `link_ollama_lmstudio_models.py` - Ollama to LM Studio Linker

Avoid data duplication and save massive amounts of disk space by symlinking your **Ollama** models directly into **LM Studio**.

### ✨ Key Features
- **💾 Zero-Footprint Linking**: Uses NTFS/Unix symlinks to expose Ollama's model blobs to LM Studio without copying files.
- **🔍 Intelligent Discovery**: Automatically parses Ollama manifests to identify GGUF models and their respective tags.
- **📂 Structured Organization**: Automatically creates the directory hierarchy required by LM Studio (`ollama/model-name/model-name.gguf`).

### 🚀 Usage

> [!IMPORTANT]
> **Windows Users**: You MUST run this script in a **PowerShell terminal with Administrator privileges** to allow the creation of symbolic links.

1. Ensure Ollama models are downloaded and the service is available.
2. Run the script:
   ```powershell
   uv run .\link_ollama_lmstudio_models.py
   ```

---

## 💤 3. `setup_sleep_schedule.sh` - Auto Sleep/Wake Scheduler

A Linux utility that schedules the machine to **suspend at a chosen time** and **wake automatically via the RTC alarm**. Useful for energy savings and enforcing a sleep schedule on always-on workstations.

### ✨ Key Features
- **🛏️ Configurable Times**: Pass any sleep and wake times in `HH:MM` (24h) format.
- **♻️ Idempotent**: Re-running the script tears down the existing schedule and installs the new one — no leftover units or stale RTC alarms.
- **🧠 Smart Wake Resolution**: Wake target resolves to today's `HH:MM` if still in the future, otherwise tomorrow's — so a `00:00 → 06:00` schedule wakes 6 hours later, not 30.
- **🧩 systemd-native**: Installs a `scheduled-sleep.service` + `scheduled-sleep.timer` pair and enables them automatically.
- **🧹 Clean Undo**: Single `--undo` flag removes the timer, service, and any pending RTC alarm.

### 🚀 Usage

> [!IMPORTANT]
> Must be run as **root** (uses `systemctl`, writes to `/etc/systemd/system`, and calls `rtcwake`).

#### Install / Replace Schedule
```bash
sudo bash setup_sleep_schedule.sh <sleep_time> <wake_time>

# Examples
sudo bash setup_sleep_schedule.sh 00:00 06:00
sudo bash setup_sleep_schedule.sh 23:30 07:15
```

#### Remove Schedule
```bash
sudo bash setup_sleep_schedule.sh --undo
```

### 🔧 What It Installs
- `/etc/systemd/system/scheduled-sleep.service` — runs `rtcwake -m mem -l -t <wake_epoch>` to suspend and arm the wake alarm.
- `/etc/systemd/system/scheduled-sleep.timer` — fires the service daily at `<sleep_time>`.

---

## 📊 4. `ollama-metrics/` - Ollama API Metrics Dashboard

A live terminal dashboard for a local **Ollama** server. Ollama ships no Prometheus endpoint (`/metrics` is a 404), so this reconstructs history by parsing the service's systemd journal and combines it with live `/api/ps` and `nvidia-smi` readings. Lives in its own folder (`ollama-metrics/`) with its own `pyproject.toml`.

### ✨ Key Features
- **📈 Request Metrics**: Total volume, error rate, req/min, and p50/p95/p99/max latency, broken down by endpoint — plus filtered inference req/min and inference-only p95 (excludes `/api/ps` polling noise).
- **⚡ Token Throughput**: Generation and prompt-eval tok/s (avg, p50, p95) plus total tokens in and out; parses current Ollama `prompt processing` / `n_gen` log formats.
- **📊 Activity Graphs**: Cycle with `g` through req/min, inf req/min, inf done/min, p95, inf p95, gen/prompt tok/s, tokens out, GPU util/temp avg+max/power avg+max, errors — each with now + peak sparklines (multi-GPU values aggregated as avg/max).
- **🧠 Per-Model Activity**: Inferences, average generation speed, load count, and average load time for each model.
- **🎮 Live GPU State + History**: Resident models with VRAM use and keep-alive countdown, alongside per-GPU memory, utilisation, temperature, and power — plus in-memory util/temp/power trend graphs (live-only, fill in after launch).
- **🌐 Client Visibility**: Top client IPs — handy when the server answers over a LAN or Tailscale.
- **🪶 Zero Dependencies**: Pure Python 3.12 standard library. Backfills history once, then follows `journalctl -f` on a background thread so refreshes stay cheap.

### 🚀 Usage

> [!IMPORTANT]
> Requires read access to the service journal — your user must be in the `adm` or `systemd-journal` group.

```bash
cd ollama-metrics

./ollama_metrics.py                  # live dashboard (default 24h of history)
./ollama_metrics.py --window 7d      # summarise a week
./ollama_metrics.py --once           # one plain-text report, then exit
./ollama_metrics.py --json | jq .    # machine-readable snapshot
```

Keys: `q` quit · `r` refresh · `w` cycle window (1h → 24h → 7d) · `g` cycle graph · `p` pause.

See [`ollama-metrics/README.md`](ollama-metrics/README.md) for the full flag list, data sources, and caveats.

---

## 🔑 5. `passwordless-ssh-setup.sh` - Passwordless SSH Setup

An interactive terminal walkthrough that sets up key-based SSH login to your other machines. Built with Tailscale in mind, but works with any reachable host. Runs on macOS (stock bash 3.2) and Linux.

### ✨ Key Features
- **🔐 Key Creation**: Creates an `ed25519` key if `~/.ssh/id_ed25519` doesn't exist, and loads passphrase-protected keys into `ssh-agent` (macOS Keychain on a Mac).
- **🌐 Tailscale Discovery**: Lists online Linux/macOS peers from `tailscale status` so you pick machines by number — or type any hostname/IP.
- **📤 Key Copy + Verify**: Uses `ssh-copy-id` (with a fallback when it's missing), then confirms the key login actually works.
- **🏷️ Short Aliases**: Optionally adds `Host` entries to `~/.ssh/config` (e.g. `ssh bigrig` for `bigrig-linux`), backing the file up first.
- **♻️ Idempotent**: Skips hosts that already accept the key and aliases that already exist.

### 🚀 Usage
```bash
./passwordless-ssh-setup.sh                         # pick machines interactively
./passwordless-ssh-setup.sh bigrig-linux sb-linux   # set up specific machines
KEY=~/.ssh/id_work ./passwordless-ssh-setup.sh      # use a different key path
```

> [!TIP]
> For Linux machines on Tailscale, `sudo tailscale up --ssh` on the remote is a keyless alternative (subject to your tailnet's SSH ACLs).

---

## 📟 6. `install-claude-statusline.sh` - Claude Code Status Line

Installs a two-line [Claude Code](https://claude.com/claude-code) status line and wires it into `~/.claude/settings.json`.

```
◆ Opus 5.5 · high   ~/code/useful-scripts   ⎇ main ↑1 +2 ~1 ?3   $1.87
ctx █████    63%   cache █████▌   41m →23:57   5h ████▋    59% ↻2h13   7d ██▏      28% ↻2d7h
```

### ✨ Key Features
- **🧭 Line 1 — Who & Where**: Model and effort, current path, git branch with ahead/behind (`↑`/`↓`), staged `+`, modified `~`, untracked `?` (or `✓` when clean), and session cost.
- **📊 Line 2 — Gauges**: Smooth 1/8-cell bars on a dark track for context used, prompt-cache time left (with expiry time), and 5h/7d quota left (with reset countdown).
- **🚦 Health Colors**: Green → yellow → red. Quotas are colored by burn rate versus time elapsed in the window, not just raw usage.
- **🔤 No Special Fonts**: Plain Unicode only — no Nerd Font required.
- **🛡️ Safe Install**: Backs up `settings.json`, removes older statusline scripts, and smoke-tests the result. `--uninstall` removes it cleanly.

### 🚀 Usage
```bash
./install-claude-statusline.sh               # install / replace
./install-claude-statusline.sh --uninstall   # remove
CLAUDE_DIR=~/.claude ./install-claude-statusline.sh
```

> [!NOTE]
> Requires `jq` (`brew install jq` / `sudo apt-get install -y jq`). Colors use 24-bit truecolor (iTerm2, Ghostty, kitty, WezTerm, modern GNOME Terminal).

---

## 🐚 7. `recreate-mac-shell.sh` - Mac zsh Prompt Setup

Recreates my zsh setup on a fresh Mac: a dependency-free `vcs_info` prompt (cwd + git branch with `+`/`*` for staged/unstaged changes, clock on the right), shared history, case-insensitive menu completion, plus `zsh-autosuggestions`, `zsh-syntax-highlighting`, `fzf` and `zoxide`. Also installs iTerm2 (if missing) and adds my profile (Monaco 15, light colour scheme) as a Dynamic Profile named **Shell Setup**, set as default.

```bash
./recreate-mac-shell.sh              # install Homebrew + packages + iTerm2 (if missing), write configs
./recreate-mac-shell.sh --no-install # only write ~/.zshrc and the iTerm2 profile
```

Any existing `~/.zshrc` is backed up to `~/.zshrc.bak.<timestamp>`. Run `exec zsh` afterwards. Run it from Terminal.app (with iTerm2 quit) so the default-profile switch sticks; otherwise pick the profile manually in iTerm2 settings.

---

## 💽 8. `storage/setup-data-drive.sh` - Encrypted Archive HDD Setup

Builds or restores bigrig's 8 TB SATA archive disk (backups + video projects, idle most of the time): LUKS2 with TPM2 auto-unlock, ext4 at `/srv/data`, a hardened Samba share for the Mac, and tuning that lets the disk spin down safely. Run it after an OS reinstall and the disk comes back exactly as it was. Re-run it any time to fix drift.

> [!NOTE]
> **How it fits with [`system-backup.sh`](#9-storagesystem-backupsh---whole-system-restic-backup):** this script sets up the *data disk*. `system-backup.sh` backs up the *root disk* onto it every night. A full restore brings back this disk's config files too, but not what lives outside them. You still need this script to re-link the disk to a new TPM (motherboard swap, BIOS change, header repair), to set up a replacement data disk, to rebuild without a backup, and to keep the LUKS header backup current.

### ✨ Key Features
- **♻️ Idempotent**: Each config file is rendered and compared first. Unchanged files are left alone, changed ones get a `.bak-<timestamp>` backup. A re-run on a configured box changes nothing.
- **🛡️ Never formats by accident**: Plain runs only use an existing LUKS volume. Formatting needs `--format-new-disk`, a disk with no partitions or signatures, **and** typing the disk serial.
- **🔐 TPM self-healing**: If the TPM2 binding no longer unseals (new machine, BIOS/Secure Boot change), it asks for the recovery passphrase once and re-enrolls to PCR 7.
- **😴 Spin-down done right**: 30-min idle spin-down, smartd that never wakes a sleeping disk, and an hourly poll interval (30-min polls kept resetting the drive's idle timer).
- **🩺 Monitoring**: SMART short test weekly, long test monthly, temperature warn/crit 45/55 °C, sysstat disk history, plus `--status`, which reports health without waking the disk.

### 🚀 Usage

> [!IMPORTANT]
> Must be run as **root**. Apply mode spins the disk up once (reading the LUKS header). `--status` won't wake it.

```bash
sudo bash storage/setup-data-drive.sh                    # apply / restore (never formats)
sudo bash storage/setup-data-drive.sh --status           # health, sleep state, recent wake-ups
sudo bash storage/setup-data-drive.sh --format-new-disk  # first-time setup of a BLANK disk

# replacement disk:
DISK=/dev/disk/by-id/ata-<model>_<serial> sudo -E bash storage/setup-data-drive.sh --format-new-disk
```

Interface names, subnets, mount point and schedules are in the config block at the top.

### 🔧 What It Manages
- **Disk**: GPT partition (4K-aligned, type 8309) → LUKS2 (4K sectors, passphrase + TPM2 PCR 7) → ext4 (`-m 0`). `/etc/crypttab` and `/etc/fstab` both use `nofail`. The mountpoint is `chattr +i` underneath.
- **Share**: `/etc/samba/smb.conf` (SMB3-only on 445, LAN + Tailscale only, macOS fruit, recycle bin). nmbd masked, ufw rules for 445/tcp + mDNS.
- **Purge**: `samba-recycle-purge.{service,timer}` + `timer.d/weekly.conf` delete `.recycle` items older than 30 days, Sundays at 03:05.
- **Longevity**: `/etc/hdparm.conf` (spindown 241 = 30 min), `/etc/smartd.conf` entry (`-n standby,48,q`), `/etc/default/smartmontools` (`--interval=3600`).
- **Safety copies**: `/root/luks-header-<serial>.img` (copy it off the box) and `/root/smart-baseline-<serial>.txt`.

### 🧯 When Things Go Wrong

**The TPM is only a convenience.** It saves typing the passphrase at boot. LUKS slot 0 is the passphrase, and the passphrase alone opens the disk on any Linux machine. If the motherboard or CPU dies, connect the disk to any PC (spare SATA port or a USB-to-SATA adapter), boot an Ubuntu live USB and run:

```bash
sudo cryptsetup open --readonly /dev/sdX1 data   # asks the passphrase
sudo mkdir -p /mnt/data && sudo mount -o ro /dev/mapper/data /mnt/data
```

On a new motherboard, enable the firmware TPM (AMD fTPM) in the BIOS and re-run this script. It asks for the passphrase once and re-links the disk to the new TPM. Until then Linux still boots, because the disk is `nofail`. It just won't mount.

**Why the LUKS header backup matters even though you know the passphrase.** The data is encrypted with a random master key. The header (first 16 MB of the partition) stores that key, locked by the passphrase and the TPM. If the header is damaged (bad sectors, formatting the wrong disk, a stray `dd`, clicking through Windows' "Initialize disk"), the passphrase has nothing to unlock. All 8 TB is then gone for good, even though the data is intact. LUKS2 keeps two copies of the header metadata, but only one copy of the locked key.

| What fails | Without the header copy | With it |
|---|---|---|
| Root NVMe dies, data disk fine | Restore from restic (section 9) | not needed |
| **Data-disk header damaged, NVMe fine** | **All videos + all backups lost** | `luksHeaderRestore`, everything back |
| Both | Everything lost | Fix the header, then restore from restic |

Copy the header off the box once, and store it **off the data disk** (a password-manager attachment works well). From the Mac:

```bash
# on bigrig: a temporary copy you own, plus its checksum
sudo install -m 600 -o "$USER" -g "$USER" /root/luks-header-<serial>.img ~/ && sha256sum ~/luks-header-<serial>.img
# on the Mac: fetch it and compare the checksum
scp <user>@bigrig-linux.local:luks-header-<serial>.img ~/Desktop/ && shasum -a 256 ~/Desktop/luks-header-<serial>.img
# on bigrig: remove the temporary copy
rm ~/luks-header-<serial>.img
```

Going through the Samba share instead? Delete the copy on Linux with `rm`. Deleting it in Finder only moves it to the share's `.recycle` folder, which is on the same disk.

Restoring a damaged header (from a live USB): test it first without writing anything, then make it permanent:

```bash
sudo cryptsetup open --readonly --header luks-header-<serial>.img /dev/sdX1 data   # data visible? then:
sudo cryptsetup close data
sudo cryptsetup luksHeaderRestore /dev/sdX1 --header-backup-file luks-header-<serial>.img
```

> [!WARNING]
> Protect the header file as you would the passphrase: the file plus the passphrase it was made with opens the disk. After **changing the passphrase**, make a new header backup and delete the old one. The old one still opens with the old passphrase. Re-running this script writes the new backup and keeps the previous one as `/root/luks-header-<serial>.img.bak-<stamp>`. Delete that `.bak`, then copy the new file off the box again. A TPM re-enroll also rewrites the header, but your off-box copy still works with the passphrase.

---

## 🗄️ 9. `storage/system-backup.sh` - Whole-System restic Backup

Nightly [restic](https://restic.net) backup of the entire bigrig-linux root disk to the encrypted data disk (`/srv/data/Backups/bigrig-linux`). The same script also runs on smallrig-linux with its own profile (see "smallrig-linux" below). Each run also writes an offline **restore kit**, so a wiped machine can go from an Ubuntu live USB back to its exact state in about an hour.

### ✨ Key Features
- **💯 Whole system**: `/` + `/boot/efi` on one filesystem: `/etc`, `/home` (including `~/.ssh`), Docker images and volumes, Ollama models, `/opt`. Skips swap, tmp, apt debs, Docker build cache, and `~/.cache` (except `huggingface`).
- **🔑 Your password, or none**: `install` asks for a restic password. Your own is saved root-only (`/root/.config/restic/bigrig-linux.pass`, 0600) so nightly runs are unattended. Press Enter for none (`--insecure-no-password`), and the LUKS data disk's encryption plus root-only 0700 permissions still protect the repo.
- **🧰 Restore kit + doomsday guide**: `Backups/README-RESTORE.txt` is a step-by-step "root NVMe died" walkthrough, regenerated every run with this machine's disks (model/serial/role), IDs and copy-paste live-USB commands. `Backups/bigrig-linux-restore/` holds a restic binary, the partition layout and package lists, so it works without internet. Keep a copy of the guide off the disk too.
- **⏰ Hands-off**: systemd timer at 04:45 (after the app DB dumps), catches up after downtime, lowest CPU priority. Keeps 7 daily / 4 weekly / 6 monthly / 1 yearly. Sundays add prune + `restic check --read-data-subset=5%`.
- **🛰️ Second copy on len-linux**: after each run, `restic copy` sends the new snapshots to a second repo on len-linux (SFTP over Tailscale, same password and retention), so the backups survive the data disk, or all of bigrig, dying. Root uses a dedicated key that len-linux only allows for SFTP, as a passwordless `restic` account: no shell, no commands, no forwarding. A failed copy never blocks the local backup: the run exits 1 and `status` flags it. Set `REMOTE_HOST=` (empty) in the config block to turn it off.

### 🚀 Usage

> [!IMPORTANT]
> Must be run as **root**. Restoring needs the data-disk passphrase, plus your restic password if you set one. Keep both in your password manager.

```bash
sudo bash storage/system-backup.sh install   # repo (asks for a password), excludes, timer (idempotent)
sudo system-backup run                       # first backup now (~420 GB, about an hour)
sudo system-backup status                    # snapshots, last success, next run
sudo system-backup run --maintenance         # force prune + verify
```

### 🔧 What It Installs
- `/usr/local/sbin/system-backup` (a copy of this script), `/etc/restic/bigrig-linux.excludes`
- `/root/.config/restic/bigrig-linux.pass` (0600), only if you set a password
- `/etc/systemd/system/system-backup.{service,timer}`
- `/root/.ssh/restic-bigrig-linux` (SSH key for the len-linux copy) and `/root/.ssh/known_hosts.restic`

#### Setting up the len-linux copy (one time)
1. `sudo bash storage/system-backup.sh install` creates the key and prints four commands to paste on len-linux. They create the `restic` account and authorize the key for SFTP only.
2. Run `install` again. It initializes the len-linux repo with the same chunking as the local one, so copies deduplicate.
3. Run `sudo system-backup run` in tmux. The first copy is about 300 GB (about 1.5 h at ~57 MB/s over Tailscale); after that it's only each night's changes.
4. Save the **private** key (`sudo cat /root/.ssh/restic-bigrig-linux`) in your password manager. A live USB needs it to restore from len-linux if both of bigrig's disks are gone.

### 🧯 Recovery Scenarios

The full copy-paste commands for every case are in `Backups/README-RESTORE.txt`. Keep a copy off the data disk and re-copy it after big changes (new disks, new passphrase).

| Situation | What to do |
|---|---|
| Root NVMe died, got wiped, or Linux won't boot | Guide steps 1–9: Ubuntu live USB → unlock data disk read-only → partition any new NVMe (root fills it) → `restic restore` → `grub-install`. About 1.5 h. |
| Motherboard/CPU died, disks fine | Same steps on the new board; nothing is tied to the old one. To just read the data, plug the 8 TB disk into any Linux PC (section 8). After the first boot, enable fTPM and re-run `setup-data-drive.sh`. |
| Only need some files back | `restic ls latest /path` to browse, then `restic restore latest --include /path --target /tmp/restored`. Works on a running bigrig or from a live USB. |
| Data disk rejects the correct passphrase | Damaged LUKS header: restore it from the header backup (section 8). |
| Only the data disk died | `setup-data-drive.sh --format-new-disk`, then `system-backup.sh install` with the **same** restic password. History is safe on len-linux, and the new local repo copies len-linux's chunking. |
| Root NVMe **and** data disk dead | Guide section "BOTH DISKS DEAD": live USB → `apt install restic` → the SSH key from your password manager → restore over the network from len-linux. The disk layout comes out of the snapshot (`restic dump latest /var/backups/system-metadata/layout.sfdisk`). |

Quick check that a backup can be read back (about 2 minutes):

```bash
sudo restic -r /srv/data/Backups/bigrig-linux restore latest --include /etc --target /tmp/drill
sudo diff -rq /etc /tmp/drill/etc | head -20   # nothing, or only files changed since the snapshot
sudo rm -rf /tmp/drill
```

> [!NOTE]
> From the Mac, `bigrig-linux/` and `bigrig-linux-restore/` show a red "no entry" badge. That's intended: they're root-only (0700), so nothing on the Mac can change or delete the backups. The restore runs as root, from a live USB or on bigrig itself.

### 🖥️ smallrig-linux

The script picks a profile by hostname (config block at the top). smallrig's differs from bigrig's in three ways:

| | bigrig-linux | smallrig-linux |
|---|---|---|
| Local disk | 8 TB IronWolf, LUKS + TPM, Samba share (`setup-data-drive.sh`) | 500 GB laptop HDD, plain ext4, label `backup` (`setup-backup-disk.sh`) |
| Repo | `/srv/data/Backups/bigrig-linux`, restic password | `/srv/backup/smallrig-linux`, **no password** (no encryption anywhere) |
| Second copy | len-linux (`restic` account) | none: local disk only |

`storage/setup-backup-disk.sh` prepares smallrig's disk the same way `setup-data-drive.sh` does bigrig's, minus encryption and sharing: GPT + ext4 `-m 0`, fstab by UUID with `nofail`, `chattr +i` on the empty mountpoint, 30-minute spin-down, smartd (hourly, `-n standby`, short test Sundays, long test monthly) and a SMART baseline. It's idempotent: re-running it only fixes drift.

```bash
sudo bash storage/setup-backup-disk.sh --format-new-disk  # first time / replacement disk (asks for the serial)
sudo bash storage/setup-backup-disk.sh                    # re-apply config, never formats
sudo bash storage/setup-backup-disk.sh --status           # mount, health, sleep (won't wake the disk)
sudo bash storage/system-backup.sh install                # then the backup, exactly as on bigrig
```

Recovery works like bigrig's rows above, minus the len-linux row: if smallrig's root NVMe and backup disk both die, there is no other copy. smallrig's guide is `/srv/backup/README-RESTORE.txt`, and it covers the unencrypted disk (no passphrase or LUKS steps).

---

## ⚙️ Getting Started

### Prerequisites
- **Python 3.12+**
- **7-Zip** (for `backup/backup.py`)
- **uv** (Recommended for dependency management)

### Environment Setup
The dependency-managed Python project lives in `backup/`. From the repo root:

```powershell
cd backup
uv sync
```

`ollama-metrics/` is standard library only — no setup needed, just run it.

### Manual Installation (without uv)
If you prefer standard pip:
```powershell
cd backup
pip install -r requirements.txt
python backup.py
```
