#!/usr/bin/env python3
"""
Rolling event store and aggregation over parsed journal events.

Events go in chronologically via add(); snapshot() aggregates whatever falls
inside the requested window. No curses or subprocess use here, so this module
can be exercised straight from a REPL against captured log text.
"""

from collections import Counter, deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from parsers import Marker, ModelLoad, ModelSelect, Request, Timing

# Each model load logs "llama-server started in N seconds" twice, ~30ms apart,
# from two different waiters. Collapse loads closer together than this.
LOAD_DEDUP_SECONDS = 2.0

# A load is attributed to the model named by the next "template selection"
# line, which follows it by about a second.
LOAD_ATTRIBUTION_SECONDS = 60.0

# Columns in the time series when the caller does not pick a width.
DEFAULT_BUCKETS = 60


def percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile. `values` need not be sorted."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, min(len(ordered), int(-(-pct * len(ordered) // 100))))
    return ordered[rank - 1]


@dataclass
class ModelStats:
    name: str
    inferences: int = 0
    gen_tps: list[float] = field(default_factory=list)
    tokens_out: int = 0
    tokens_in: int = 0
    loads: int = 0
    load_seconds: list[float] = field(default_factory=list)


class MetricsStore:
    """Holds events for up to `retention`, aggregating on demand."""

    def __init__(self, retention: timedelta):
        self.retention = retention
        self.requests: deque[Request] = deque()
        self.timings: deque[Timing] = deque()
        self.loads: deque[ModelLoad] = deque()
        self.markers: deque[Marker] = deque()
        self._current_model: str | None = None
        self._last_load_ts: datetime | None = None
        self._pending_loads: list[ModelLoad] = []

    def add(self, event) -> None:
        if isinstance(event, Request):
            self.requests.append(event)
        elif isinstance(event, Timing):
            # Attribute to the most recently selected model. With
            # OLLAMA_MAX_LOADED_MODELS=2 this is best-effort: two resident
            # runners cannot be told apart, since OLLAMA_NUM_PARALLEL=1 pins
            # every slot id to 0.
            event.model = self._current_model
            self.timings.append(event)
        elif isinstance(event, ModelSelect):
            self._current_model = event.model
            self._flush_pending_loads(event.model, event.ts)
        elif isinstance(event, ModelLoad):
            if (
                self._last_load_ts is not None
                and (event.ts - self._last_load_ts).total_seconds() < LOAD_DEDUP_SECONDS
            ):
                return  # duplicate of the load we already recorded
            self._last_load_ts = event.ts
            self._pending_loads.append(event)
        elif isinstance(event, Marker):
            self.markers.append(event)

    def _flush_pending_loads(self, model: str | None, now: datetime) -> None:
        still_pending = []
        for load in self._pending_loads:
            if (now - load.ts).total_seconds() <= LOAD_ATTRIBUTION_SECONDS:
                load.model = model
                self.loads.append(load)
            else:
                still_pending.append(load)
        self._pending_loads = still_pending

    def finalize(self) -> None:
        """Record loads that never saw a following model-selection line."""
        for load in self._pending_loads:
            self.loads.append(load)
        self._pending_loads = []

    def prune(self, now: datetime) -> None:
        cutoff = now - self.retention
        for series in (self.requests, self.timings, self.loads, self.markers):
            while series and series[0].ts < cutoff:
                series.popleft()

    def snapshot(
        self,
        window: timedelta,
        now: datetime | None = None,
        buckets: int = DEFAULT_BUCKETS,
    ) -> dict:
        now = now or datetime.now().astimezone()
        cutoff = now - window
        requests = [r for r in self.requests if r.ts >= cutoff]
        timings = [t for t in self.timings if t.ts >= cutoff]
        loads = [l for l in self.loads if l.ts >= cutoff]
        markers = [m for m in self.markers if m.ts >= cutoff]

        return {
            "window_seconds": window.total_seconds(),
            "generated_at": now.isoformat(),
            "requests": self._request_stats(requests, window),
            "tokens": self._token_stats(timings),
            "models": self._model_stats(timings, loads),
            "events": Counter(m.kind for m in markers),
            "series": self._series(requests, timings, markers, window, now, buckets),
        }

    @staticmethod
    def _series(
        requests: list[Request],
        timings: list[Timing],
        markers: list[Marker],
        window: timedelta,
        now: datetime,
        buckets: int,
    ) -> dict:
        """Bucket the window into `buckets` equal slices, oldest first.

        Every series is the same length, so the dashboard can stack them on a
        shared time axis without re-deriving where each column starts.
        """
        buckets = max(1, min(int(buckets), 400))
        span = window.total_seconds() / buckets
        start = (now - window).timestamp()

        def index_of(ts: datetime) -> int:
            offset = int((ts.timestamp() - start) / span) if span else 0
            return max(0, min(buckets - 1, offset))

        counts = [0] * buckets
        errors = [0] * buckets
        latencies: list[list[float]] = [[] for _ in range(buckets)]
        gen_tps: list[list[float]] = [[] for _ in range(buckets)]
        tokens_out = [0] * buckets

        for req in requests:
            i = index_of(req.ts)
            counts[i] += 1
            latencies[i].append(req.latency)
            if req.status >= 400:
                errors[i] += 1

        for timing in timings:
            if timing.kind != "eval":
                continue
            i = index_of(timing.ts)
            tokens_out[i] += timing.tokens
            if timing.tps:
                gen_tps[i].append(timing.tps)

        failures = [0] * buckets
        for marker in markers:
            if marker.kind in ("error", "evict"):
                failures[index_of(marker.ts)] += 1

        per_minute = span / 60.0 if span else 1.0
        return {
            "buckets": buckets,
            "bucket_seconds": span,
            "requests_per_min": [c / per_minute if per_minute else 0.0 for c in counts],
            "latency_p95": [percentile(l, 95) for l in latencies],
            "gen_tps": [sum(v) / len(v) if v else 0.0 for v in gen_tps],
            "tokens_out": [float(t) for t in tokens_out],
            "errors": [float(e + f) for e, f in zip(errors, failures)],
        }

    @staticmethod
    def _request_stats(requests: list[Request], window: timedelta) -> dict:
        latencies = [r.latency for r in requests]
        errors = [r for r in requests if r.status >= 400]

        by_endpoint = {}
        for req in requests:
            by_endpoint.setdefault((req.method, req.path), []).append(req.latency)
        endpoints = sorted(
            (
                {
                    "method": method,
                    "path": path,
                    "count": len(lat),
                    "p95": percentile(lat, 95),
                }
                for (method, path), lat in by_endpoint.items()
            ),
            key=lambda e: e["count"],
            reverse=True,
        )

        minutes = window.total_seconds() / 60.0
        return {
            "total": len(requests),
            "errors": len(errors),
            "error_rate": len(errors) / len(requests) if requests else 0.0,
            "per_minute": len(requests) / minutes if minutes else 0.0,
            "p50": percentile(latencies, 50),
            "p95": percentile(latencies, 95),
            "p99": percentile(latencies, 99),
            "max": max(latencies, default=0.0),
            "endpoints": endpoints,
            "clients": Counter(r.ip for r in requests).most_common(),
            "statuses": dict(sorted(Counter(r.status for r in requests).items())),
        }

    @staticmethod
    def _token_stats(timings: list[Timing]) -> dict:
        gen = [t for t in timings if t.kind == "eval"]
        prompt = [t for t in timings if t.kind == "prompt eval"]
        gen_tps = [t.tps for t in gen if t.tps]
        prompt_tps = [t.tps for t in prompt if t.tps]
        return {
            "inferences": len(gen),
            "tokens_out": sum(t.tokens for t in gen),
            "tokens_in": sum(t.tokens for t in prompt),
            "gen_tps_avg": sum(gen_tps) / len(gen_tps) if gen_tps else 0.0,
            "gen_tps_p50": percentile(gen_tps, 50),
            "gen_tps_p95": percentile(gen_tps, 95),
            "prompt_tps_avg": sum(prompt_tps) / len(prompt_tps) if prompt_tps else 0.0,
            "generation_seconds": sum(t.seconds for t in gen),
        }

    @staticmethod
    def _model_stats(timings: list[Timing], loads: list[ModelLoad]) -> list[dict]:
        stats: dict[str, ModelStats] = {}

        def bucket(name: str | None) -> ModelStats:
            key = name or "unknown"
            return stats.setdefault(key, ModelStats(name=key))

        for timing in timings:
            entry = bucket(timing.model)
            if timing.kind == "eval":
                entry.inferences += 1
                entry.tokens_out += timing.tokens
                if timing.tps:
                    entry.gen_tps.append(timing.tps)
            elif timing.kind == "prompt eval":
                entry.tokens_in += timing.tokens

        for load in loads:
            entry = bucket(load.model)
            entry.loads += 1
            entry.load_seconds.append(load.seconds)

        rows = [
            {
                "name": s.name,
                "inferences": s.inferences,
                "tokens_out": s.tokens_out,
                "tokens_in": s.tokens_in,
                "gen_tps": sum(s.gen_tps) / len(s.gen_tps) if s.gen_tps else 0.0,
                "loads": s.loads,
                "avg_load_seconds": (
                    sum(s.load_seconds) / len(s.load_seconds) if s.load_seconds else 0.0
                ),
            }
            for s in stats.values()
        ]
        rows.sort(key=lambda r: (r["inferences"], r["loads"]), reverse=True)
        return rows
