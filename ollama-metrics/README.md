# 📊 ollama-metrics

A live terminal dashboard for a local **Ollama** server: request rates, latency
percentiles, token throughput, per-model activity and GPU state.

Ollama ships **no Prometheus endpoint** (`GET /metrics` returns 404), so all
history here is reconstructed by parsing the server's own systemd journal, then
combined with live `/api/ps` and `nvidia-smi` readings.

## ✨ What it shows

- **Requests** — total, error rate, req/min, p50 / p95 / p99 / max latency, a
  breakdown by endpoint, and the top client IPs (useful when the server is
  reachable over a LAN or Tailscale).
- **Tokens** — generation and prompt-eval throughput (avg / p50 / p95 tok/s)
  plus total tokens in and out.
- **Models** — inferences, average generation speed, load count and average
  load time, per model.
- **Activity graphs** — the window plotted over time: a full-height chart of
  the series you pick with `g` (req/min, p95 latency, gen tok/s, tokens out,
  errors), with a sparkline and peak for every series underneath. One column
  is one time bucket, sized to the terminal.
- **Live state** — resident models with VRAM use and keep-alive countdown, and
  per-GPU memory / utilisation / temperature / power.
- **Pressure signals** — VRAM evictions and server restarts in the window.

## 🚀 Usage

```bash
cd ollama-metrics

./ollama_metrics.py                  # live dashboard (default 24h of history)
./ollama_metrics.py --window 7d      # summarise a week
./ollama_metrics.py --once           # one plain-text report, then exit
./ollama_metrics.py --json | jq .    # machine-readable snapshot
```

Keys: `q` quit · `r` refresh now · `w` cycle window (1h → 24h → 7d) ·
`g` cycle the graphed series · `p` pause.

### Options

| Flag | Default | Meaning |
|---|---|---|
| `--window` | `24h` | History depth (`30m`, `1h`, `7d`, …) |
| `--interval` | `2.0` | Dashboard refresh seconds |
| `--host` | `$OLLAMA_HOST` or `http://localhost:11434` | Ollama base URL |
| `--once` | off | Print one plain-text report and exit |
| `--json` | off | Print the snapshot as JSON and exit |
| `--no-gpu` | off | Skip `nvidia-smi` |
| `--ascii` | off | Draw graphs with ASCII instead of block characters |

When stdout is not a terminal the tool automatically falls back to the
plain-text report, so `./ollama_metrics.py > report.txt` does the right thing.

## 📋 Requirements

- Python **3.12+**, standard library only — nothing to install.
- Read access to the service journal. Your user must be in the `adm` or
  `systemd-journal` group; the script exits with a clear message otherwise.
- `nvidia-smi` is optional — GPU rows are simply omitted if it is missing.

## 🔍 How it works

| Metric | Source |
|---|---|
| Status, latency, endpoint, client IP | `[GIN]` access log lines |
| Token counts and tok/s | `slot print_timing:` lines |
| Model names | `msg="template selection"` lines |
| Load duration | `msg="llama-server started in N seconds"` |
| Evictions / restarts | scheduler and startup log lines |
| Resident models, VRAM, keep-alive | `GET /api/ps` |
| Installed models, disk use | `GET /api/tags` |

History is backfilled once at startup, then followed with `journalctl -f` on a
background thread, so refresh ticks stay cheap no matter how long the window is.

### Caveats

- Ollama logs each model load twice, ~30ms apart; loads closer together than
  two seconds are collapsed into one.
- Timings are attributed to the most recently selected model. With
  `OLLAMA_MAX_LOADED_MODELS` above 1, two resident runners cannot be told
  apart, so per-model attribution is best-effort during concurrent use.
- Activity logged before the first model-selection line lands under `unknown`.
- The dashboard's own polling of `/api/ps` and `/api/tags` shows up in the
  request counts.

## 🗂️ Layout

| File | Role |
|---|---|
| `ollama_metrics.py` | Entry point: CLI, wiring, main loop |
| `collectors.py` | Journal backfill / follow, API and GPU probes |
| `parsers.py` | Log regexes and event types |
| `metrics.py` | Rolling event store and aggregation |
| `dashboard.py` | curses and plain-text rendering |

`parsers.py` and `metrics.py` have no curses or subprocess dependencies, so they
can be exercised directly against captured log text.
