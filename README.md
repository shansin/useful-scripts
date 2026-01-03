# 🛠️ Useful Scripts

A collection of high-performance utility scripts for system maintenance, backup automation, and AI model management.

---

## 📋 Table of Contents
- [backup.py (Directory Backup Utility)](#1-backuppy---directory-backup-utility)
- [link_ollama_lmstudio_models.py (Ollama<>Lm Studio Linker)](#2-link_ollama_lmstudio_modelspy---ollama-to-lm-studio-linker)
- [Getting Started](#getting-started)

---

## 📦 1. `backup.py` - Directory Backup Utility

A robust, high-performance Python script designed for automated, timestamped backups. It leverages **7-Zip** for superior compression speed and efficiency.

### ✨ Key Features
- **🚀 Turbocharged Compression**: Uses 7-Zip (`7z.exe`) via subprocess for lightning-fast archiving.
- **📁 Directory Sync**: Supports raw directory copying (`shutil.copytree`) when zipping is disabled.
- **⏱️ Performance Metrics**: Automatically calculates and logs the duration of each backup task.
- **⚙️ Granular Control**:
    - Manage multiple tasks via a single `backup_config.yml` file.
    - Toggle tasks on/off with the `run` parameter.
    - **Override capability**: Run specific tasks via command line, bypassing the configuration's skip status.
- **🛡️ Robustness**: Gracefully handles missing source paths and permission issues, ensuring your entire backup queue isn't stalled by a single failure.

### 🚀 Usage

#### Standard Execution
Run all tasks where `run: true` is set in the config:
```powershell
uv run .\backup.py
```

#### Targeted Execution (Override)
Run a specific task immediately, even if it is disabled (`run: false`) in the config:
```powershell
uv run .\backup.py "YourTaskName"
```

### 🔧 Configuration (`backup_config.yml`)

The script looks for `backup_config.yml` in the same directory.

```yaml
backup_settings:
  destination: "<DestinationPath>"           # Global backup root
  zip: true                               # Use 7z compression (true/false)
  timestamp_format: "%Y%m%d_%H%M%S"       # Custom date/time format for filenames
  seven_zip_path: "C:/Program Files/7-Zip/7z.exe" # Path to 7z executable

tasks:
  - name: "<TaskName>"                  # Unique task identifier
    source: "<SourcePath>"
    run: false                            # Set to false to skip during bulk runs
    
  - name: "<Task2Name>"
    source: "<Source2Path>"
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

## ⚙️ Getting Started

### Prerequisites
- **Python 3.12+**
- **7-Zip** (for `backup.py`)
- **uv** (Recommended for dependency management)

### Environment Setup
If you are setting up for the first time:

```powershell
# Initialize the project environment
uv init

# Install required dependencies
uv add PyYAML
```

### Manual Installation (without uv)
If you prefer standard pip:
```powershell
pip install PyYAML
python backup.py
```
