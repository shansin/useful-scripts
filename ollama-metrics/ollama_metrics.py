#!/usr/bin/env python3
"""
Live metrics dashboard for the local Ollama server.

Ollama serves no Prometheus endpoint, so request rates, latency percentiles and
token throughput are reconstructed by parsing its systemd journal, and combined
with live /api/ps and nvidia-smi readings.

Usage:
    ./ollama_metrics.py                 # live dashboard
    ./ollama_metrics.py --once          # one plain-text report
    ./ollama_metrics.py --json          # machine-readable snapshot
"""

import argparse
import curses
import json
import locale
import os
import socket
import sys
import time
from datetime import datetime, timedelta

import collectors
import dashboard
import metrics
from metrics import MetricsStore

WINDOW_CYCLE = ["1h", "24h", "7d"]
LIBRARY_REFRESH_SECONDS = 60.0


def parse_window(text: str) -> timedelta:
    """Accept 30m / 1h / 7d style windows."""
    text = text.strip().lower()
    units = {"m": 60, "h": 3600, "d": 86400}
    if text and text[-1] in units and text[:-1].replace(".", "", 1).isdigit():
        return timedelta(seconds=float(text[:-1]) * units[text[-1]])
    raise argparse.ArgumentTypeError(f"invalid window {text!r} (try 30m, 24h, 7d)")


def default_host() -> str:
    host = os.environ.get("OLLAMA_HOST", "http://localhost:11434").strip()
    if not host.startswith(("http://", "https://")):
        host = f"http://{host}"
    # OLLAMA_HOST is often a bind address like 0.0.0.0, which is not dialable.
    return host.replace("//0.0.0.0", "//localhost")


class Application:
    """Owns the store, the journal follower and the cached live probes."""

    def __init__(self, args):
        self.host = args.host.rstrip("/")
        self.window = args.window
        self.use_gpu = not args.no_gpu
        self.hostname = socket.gethostname()
        self.store = MetricsStore(retention=self.window)
        self.follower: collectors.JournalFollower | None = None
        self.graph_index = 0
        self.graph_buckets = metrics.DEFAULT_BUCKETS
        self._library = {"count": 0, "disk": 0}
        self._library_checked = 0.0

    def load_history(self) -> None:
        self.store = MetricsStore(retention=self.window)
        collectors.backfill(self.store, self.window)

    def follow(self) -> None:
        self.follower = collectors.JournalFollower()
        self.follower.start()

    def set_window(self, window: timedelta) -> None:
        """Growing the window needs a re-read; shrinking just filters."""
        needs_reload = window > self.store.retention
        self.window = window
        if needs_reload:
            self.load_history()
        else:
            self.store.retention = window

    def collect(self) -> dict:
        now = datetime.now().astimezone()
        if self.follower:
            self.follower.drain(self.store)
        self.store.prune(now)

        if time.monotonic() - self._library_checked > LIBRARY_REFRESH_SECONDS:
            self._library = collectors.probe_library(self.host)
            self._library_checked = time.monotonic()

        return {
            "host": self.host,
            "hostname": self.hostname,
            "server": collectors.probe_server(self.host),
            "service": collectors.probe_service(),
            "gpus": collectors.probe_gpus() if self.use_gpu else [],
            "library": self._library,
            "graph_index": self.graph_index,
            "snapshot": self.store.snapshot(
                self.window, now=now, buckets=self.graph_buckets
            ),
        }

    def close(self) -> None:
        if self.follower:
            self.follower.stop()


def run_dashboard(screen, app: Application, interval: float) -> None:
    curses.curs_set(0)
    dashboard.init_colors()
    screen.timeout(int(interval * 1000))

    paused = False
    app.graph_buckets = _bucket_count(screen)
    state = app.collect()
    window_index = _closest_window_index(app.window)

    while True:
        dashboard.render_curses(screen, state, paused)
        key = screen.getch()

        if key in (ord("q"), ord("Q"), 27):
            return
        if key in (ord("p"), ord("P")):
            paused = not paused
            continue
        if key in (ord("g"), ord("G")):
            app.graph_index = (app.graph_index + 1) % len(dashboard.GRAPHS)
            state["graph_index"] = app.graph_index
            continue
        if key == curses.KEY_RESIZE:
            app.graph_buckets = _bucket_count(screen)
        if key in (ord("w"), ord("W")):
            window_index = (window_index + 1) % len(WINDOW_CYCLE)
            screen.erase()
            screen.addstr(0, 0, f"Loading {WINDOW_CYCLE[window_index]} of history...")
            screen.refresh()
            app.set_window(parse_window(WINDOW_CYCLE[window_index]))
        elif key not in (ord("r"), ord("R"), curses.KEY_RESIZE, -1):
            continue

        if not paused or key != -1:
            state = app.collect()


def _bucket_count(screen) -> int:
    """One bucket per plotted column, so charts never interpolate."""
    _, width = screen.getmaxyx()
    return dashboard.plot_width(width - 1)


def _closest_window_index(window: timedelta) -> int:
    """Start the `w` cycle at whichever preset the current window matches."""
    for index, label in enumerate(WINDOW_CYCLE):
        if parse_window(label) == window:
            return index
    return len(WINDOW_CYCLE) - 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Live API metrics for the local Ollama server.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--window", type=parse_window, default="24h",
                        help="history depth to summarise (30m, 24h, 7d)")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="dashboard refresh seconds")
    parser.add_argument("--host", default=default_host(), help="Ollama base URL")
    parser.add_argument("--once", action="store_true",
                        help="print one plain-text report and exit")
    parser.add_argument("--json", action="store_true",
                        help="print the snapshot as JSON and exit")
    parser.add_argument("--no-gpu", action="store_true", help="skip nvidia-smi")
    parser.add_argument("--ascii", action="store_true",
                        help="draw graphs with ASCII instead of block characters")
    args = parser.parse_args()

    # curses needs the locale set before it will emit wide characters, and a
    # non-UTF-8 terminal cannot render the block glyphs at all.
    locale.setlocale(locale.LC_ALL, "")
    encoding = locale.getpreferredencoding(False) or ""
    dashboard.set_charset(not args.ascii and "utf" in encoding.lower())

    if isinstance(args.window, str):  # argparse default bypasses the type hook
        args.window = parse_window(args.window)

    usable, reason = collectors.journal_available()
    if not usable:
        print(f"error: cannot read the {collectors.SERVICE} journal: {reason}",
              file=sys.stderr)
        print("hint: your user must be in the 'adm' or 'systemd-journal' group.",
              file=sys.stderr)
        return 1

    app = Application(args)
    app.load_history()

    try:
        if args.json:
            state = app.collect()
            state["snapshot"]["events"] = dict(state["snapshot"]["events"])
            print(json.dumps(state, indent=2, default=str))
            return 0

        # Fall back to plain text when stdout is not a terminal, so the tool
        # stays pipeable into a file or a pager.
        if args.once or not sys.stdout.isatty():
            print(dashboard.render_plain(app.collect()))
            return 0

        app.follow()
        curses.wrapper(run_dashboard, app, args.interval)
        return 0
    except KeyboardInterrupt:
        return 130
    finally:
        app.close()


if __name__ == "__main__":
    sys.exit(main())
