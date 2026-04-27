# 🛠️ Useful Scripts

A collection of high-performance utility scripts for system maintenance, backup automation, and AI model management.

---

## 📋 Table of Contents
- [backup/ (Directory Backup Utility)](#1-backup---directory-backup-utility)
- [link_ollama_lmstudio_models.py (Ollama<>Lm Studio Linker)](#2-link_ollama_lmstudio_modelspy---ollama-to-lm-studio-linker)
- [setup_sleep_schedule.sh (Auto Sleep/Wake Scheduler)](#3-setup_sleep_schedulesh---auto-sleepwake-scheduler)
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

## ⚙️ Getting Started

### Prerequisites
- **Python 3.12+**
- **7-Zip** (for `backup/backup.py`)
- **uv** (Recommended for dependency management)

### Environment Setup
The Python project lives in `backup/`. From the repo root:

```powershell
cd backup
uv sync
```

### Manual Installation (without uv)
If you prefer standard pip:
```powershell
cd backup
pip install -r requirements.txt
python backup.py
```
