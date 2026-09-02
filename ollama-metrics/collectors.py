#!/usr/bin/env python3
"""
Data sources: the systemd journal (history) and live API / GPU probes.

Re-parsing days of journal on every refresh would be far too slow, so history
is backfilled once and then followed with `journalctl -f`, whose output a
daemon thread pushes onto a queue for the render loop to drain.
"""

import json
import queue
import shutil
import subprocess
import threading
import urllib.error
import urllib.request
from datetime import datetime, timedelta

from parsers import parse_line

SERVICE = "ollama"
HTTP_TIMEOUT = 2.0


def journal_available() -> tuple[bool, str]:
    """Check we can actually read this unit's journal (needs adm/systemd-journal)."""
    if not shutil.which("journalctl"):
        return False, "journalctl not found"
    try:
        result = subprocess.run(
            ["journalctl", "-u", SERVICE, "-n", "1", "--no-pager"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)
    if result.returncode != 0:
        return False, (result.stderr or "").strip() or "journalctl failed"
    if not result.stdout.strip():
        return False, f"no journal entries for {SERVICE}.service"
    return True, ""


def backfill(store, window: timedelta) -> int:
    """Load history for `window` into `store`. Returns the event count."""
    since = f"{int(window.total_seconds())} seconds ago"
    proc = subprocess.Popen(
        ["journalctl", "-u", SERVICE, "--since", since, "-o", "short-iso", "--no-pager"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        errors="replace",
    )
    count = 0
    with proc:
        for line in proc.stdout:
            event = parse_line(line.rstrip("\n"))
            if event is not None:
                store.add(event)
                count += 1
    store.finalize()
    return count


class JournalFollower:
    """Streams new journal events onto a queue via `journalctl -f`."""

    def __init__(self):
        self.events: queue.Queue = queue.Queue()
        self._proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    def start(self) -> None:
        self._proc = subprocess.Popen(
            ["journalctl", "-u", SERVICE, "-f", "-n", "0", "-o", "short-iso"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
        )
        self._thread = threading.Thread(target=self._pump, daemon=True)
        self._thread.start()

    def _pump(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        for line in self._proc.stdout:
            if self._stop.is_set():
                break
            event = parse_line(line.rstrip("\n"))
            if event is not None:
                self.events.put(event)

    def drain(self, store) -> int:
        """Move everything queued so far into the store."""
        count = 0
        while True:
            try:
                store.add(self.events.get_nowait())
            except queue.Empty:
                break
            count += 1
        return count

    def stop(self) -> None:
        self._stop.set()
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._proc.kill()


def _get_json(host: str, path: str):
    try:
        with urllib.request.urlopen(f"{host}{path}", timeout=HTTP_TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return None


def probe_server(host: str) -> dict:
    """Live server state: version, loaded models, keep-alive expiry."""
    version = _get_json(host, "/api/version")
    if version is None:
        return {"reachable": False, "version": None, "loaded": []}

    running = _get_json(host, "/api/ps") or {}
    loaded = []
    for model in running.get("models", []):
        expires_in = None
        raw_expiry = model.get("expires_at")
        if raw_expiry:
            try:
                expires_in = (
                    datetime.fromisoformat(raw_expiry) - datetime.now().astimezone()
                ).total_seconds()
            except ValueError:
                expires_in = None
        loaded.append(
            {
                "name": model.get("name") or model.get("model") or "?",
                "size": model.get("size", 0),
                "size_vram": model.get("size_vram", 0),
                "context": (model.get("details") or {}).get("context_length"),
                "expires_in": expires_in,
            }
        )
    return {"reachable": True, "version": version.get("version"), "loaded": loaded}


def probe_library(host: str) -> dict:
    """Installed model inventory. Cheap, but cached by the caller anyway."""
    tags = _get_json(host, "/api/tags")
    if tags is None:
        return {"count": 0, "disk": 0}
    models = tags.get("models", [])
    return {"count": len(models), "disk": sum(m.get("size", 0) for m in models)}


def probe_gpus() -> list[dict]:
    if not shutil.which("nvidia-smi"):
        return []
    fields = (
        "index,name,memory.used,memory.total,utilization.gpu,"
        "temperature.gpu,power.draw"
    )
    try:
        result = subprocess.run(
            ["nvidia-smi", f"--query-gpu={fields}", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []

    gpus = []
    for line in result.stdout.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 7:
            continue

        def number(text: str) -> float:
            try:
                return float(text)
            except ValueError:
                return 0.0

        gpus.append(
            {
                "index": parts[0],
                "name": parts[1].replace("NVIDIA GeForce ", ""),
                "memory_used": number(parts[2]),
                "memory_total": number(parts[3]),
                "utilization": number(parts[4]),
                "temperature": number(parts[5]),
                "power": number(parts[6]),
            }
        )
    return gpus


def probe_service() -> dict:
    """systemd state and uptime, so a dead service is reported as dead."""
    try:
        result = subprocess.run(
            ["systemctl", "show", SERVICE, "-p", "ActiveState", "-p", "ActiveEnterTimestamp"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return {"state": "unknown", "uptime": None}

    values = {}
    for line in result.stdout.strip().splitlines():
        key, _, value = line.partition("=")
        values[key] = value

    uptime = None
    stamp = values.get("ActiveEnterTimestamp", "").strip()
    if stamp:
        for fmt in ("%a %Y-%m-%d %H:%M:%S %Z", "%a %Y-%m-%d %H:%M:%S"):
            try:
                started = datetime.strptime(stamp, fmt)
                uptime = (datetime.now() - started.replace(tzinfo=None)).total_seconds()
                break
            except ValueError:
                continue
    return {"state": values.get("ActiveState", "unknown"), "uptime": uptime}
