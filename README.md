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
