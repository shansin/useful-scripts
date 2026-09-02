#!/usr/bin/env python3
"""
Regexes and event types for reading Ollama's systemd journal output.

Ollama exposes no Prometheus endpoint (GET /metrics is a 404), so every
historical metric here is reconstructed from log lines. Each parser turns one
journal line into one event, or None.
"""

import re
from dataclasses import dataclass
from datetime import datetime

# Journal envelope written by `journalctl -o short-iso`:
#   2026-08-07T09:55:05-07:00 bigrig-linux ollama[5667]: <message>
# The journal timestamp is used for every event. It is the only clock shared by
# all line types -- the `slot print_timing:` lines are raw llama-server stdout
# and carry no timestamp of their own.
JOURNAL_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2}|Z))\s+"
    r"(?P<host>\S+)\s+(?P<unit>[^\s:]+):\s(?P<msg>.*)$"
)

# Gin access log. Anchored on the literal bracketed tag: a bare `GIN` also
# occurs inside the OLLAMA_ORIGINS value of the startup config line.
GIN_RE = re.compile(
    r"\[GIN\]\s+\d{4}/\d{2}/\d{2}\s+-\s+\d{2}:\d{2}:\d{2}\s*"
    r"\|\s*(?P<status>\d{3})\s*"
    r"\|\s*(?P<latency>\S+)\s*"
    r"\|\s*(?P<ip>\S+)\s*"
    r"\|\s*(?P<method>[A-Z]+)\s+\"(?P<path>[^\"]*)\""
)

# llama-server per-request timings. The `total time` variant has no
# per-token/per-second parenthetical, so those groups must stay optional.
TIMING_RE = re.compile(
    r"slot print_timing:\s+id\s+(?P<slot>\d+)\s*\|\s*task\s+(?P<task>\d+)\s*\|\s*"
    r"(?P<kind>prompt eval|eval|total)\s+time\s*=\s*(?P<ms>[\d.]+)\s*ms\s*/\s*"
    r"(?P<tokens>\d+)\s+tokens"
    r"(?:\s*\(\s*[\d.]+\s+ms per token,\s*(?P<tps>[\d.]+)\s+tokens per second\))?"
)

MODEL_SELECT_RE = re.compile(r'msg="template selection"\s+model=(?P<model>\S+)')
LOAD_RE = re.compile(r'msg="llama-server started in (?P<secs>[\d.]+) seconds"')
EVICT_RE = re.compile(r'msg="[^"]*evicting"')
RESTART_RE = re.compile(r'msg="server config"')
LEVEL_RE = re.compile(r"level=(?P<level>ERROR|WARN)")

# Go duration units, longest-first so `ms` wins over `m` and `s`.
_DURATION_RE = re.compile(r"([\d.]+)(ns|µs|us|ms|h|m|s)")
_DURATION_SECONDS = {
    "ns": 1e-9,
    "µs": 1e-6,
    "us": 1e-6,
    "ms": 1e-3,
    "s": 1.0,
    "m": 60.0,
    "h": 3600.0,
}


@dataclass
class Request:
    ts: datetime
    status: int
    latency: float  # seconds
    ip: str
    method: str
    path: str


@dataclass
class Timing:
    ts: datetime
    kind: str  # "prompt eval" | "eval" | "total"
    tokens: int
    seconds: float
    tps: float | None
    model: str | None = None  # filled in by the store, see MetricsStore.add


@dataclass
class ModelLoad:
    ts: datetime
    seconds: float
    model: str | None = None


@dataclass
class ModelSelect:
    ts: datetime
    model: str


@dataclass
class Marker:
    """An event we only ever count: evictions, errors, restarts."""

    ts: datetime
    kind: str  # "evict" | "error" | "restart"


def parse_go_duration(text: str) -> float | None:
    """Convert a Go duration string ('30.347µs', '1m30s') to seconds."""
    parts = _DURATION_RE.findall(text)
    if not parts:
        return None
    total = 0.0
    for value, unit in parts:
        try:
            total += float(value) * _DURATION_SECONDS[unit]
        except ValueError:
            return None
    return total


def strip_model_name(raw: str) -> str:
    """'registry.ollama.ai/library/qwen3.6:35b-192k' -> 'qwen3.6:35b-192k'."""
    name = raw.strip().strip('"')
    for prefix in ("registry.ollama.ai/library/", "registry.ollama.ai/"):
        if name.startswith(prefix):
            name = name[len(prefix) :]
            break
    return name.rsplit("/", 1)[-1] if "/" in name else name


def parse_line(line: str):
    """Parse one journal line into an event, or None if it carries no metric."""
    envelope = JOURNAL_RE.match(line)
    if not envelope:
        return None
    try:
        ts = datetime.fromisoformat(envelope.group("ts"))
    except ValueError:
        return None
    msg = envelope.group("msg")

    gin = GIN_RE.search(msg)
    if gin:
        latency = parse_go_duration(gin.group("latency"))
        if latency is None:
            return None
        return Request(
            ts=ts,
            status=int(gin.group("status")),
            latency=latency,
            ip=gin.group("ip"),
            method=gin.group("method"),
            path=gin.group("path"),
        )

    timing = TIMING_RE.search(msg)
    if timing:
        tps = timing.group("tps")
        return Timing(
            ts=ts,
            kind=timing.group("kind"),
            tokens=int(timing.group("tokens")),
            seconds=float(timing.group("ms")) / 1000.0,
            tps=float(tps) if tps else None,
        )

    select = MODEL_SELECT_RE.search(msg)
    if select:
        return ModelSelect(ts=ts, model=strip_model_name(select.group("model")))

    load = LOAD_RE.search(msg)
    if load:
        return ModelLoad(ts=ts, seconds=float(load.group("secs")))

    if EVICT_RE.search(msg):
        return Marker(ts=ts, kind="evict")
    if RESTART_RE.search(msg):
        return Marker(ts=ts, kind="restart")

    level = LEVEL_RE.search(msg)
    if level and level.group("level") == "ERROR":
        return Marker(ts=ts, kind="error")

    return None
