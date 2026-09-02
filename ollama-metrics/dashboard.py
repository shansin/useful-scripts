#!/usr/bin/env python3
"""
Rendering. build_rows() produces (style, text) pairs that both the curses
dashboard and the plain-text --once report draw, so the two never drift apart.
"""

import curses
from datetime import datetime

STYLES = {
    "title": (curses.A_BOLD, 4),
    "section": (curses.A_BOLD, 6),
    "body": (curses.A_NORMAL, 0),
    "dim": (curses.A_DIM, 0),
    "good": (curses.A_NORMAL, 2),
    "warn": (curses.A_NORMAL, 3),
    "bad": (curses.A_BOLD, 1),
}


def fmt_bytes(value: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(value) < 1024 or unit == "TB":
            return f"{value:.0f} {unit}" if unit in ("B", "KB") else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def fmt_count(value: float) -> str:
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}K"
    return f"{value:.0f}"


def fmt_seconds(value: float) -> str:
    if value < 0.001:
        return f"{value * 1_000_000:.0f}us"
    if value < 1:
        return f"{value * 1000:.0f}ms"
    if value < 60:
        return f"{value:.1f}s"
    if value < 3600:
        return f"{int(value // 60)}m{int(value % 60):02d}s"
    return f"{int(value // 3600)}h{int((value % 3600) // 60):02d}m"


def fmt_uptime(seconds: float | None) -> str:
    if seconds is None or seconds < 0:
        return "?"
    days, rest = divmod(int(seconds), 86400)
    hours, minutes = divmod(rest // 60, 60)
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def fmt_window(seconds: float) -> str:
    # Report a day as "24h" so the label matches what the `w` key cycles through.
    if seconds >= 172800:
        return f"{int(seconds // 86400)}d"
    if seconds >= 3600:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 60)}m"


def bar(fraction: float, width: int) -> str:
    filled = max(0, min(width, round(fraction * width)))
    return "#" * filled + "-" * (width - filled)


# Which series the "Activity" section plots, in the order the `g` key cycles.
# (key into snapshot["series"], label, value formatter, style)
GRAPHS = [
    ("requests_per_min", "req/min", lambda v: f"{v:.1f}", "body"),
    ("latency_p95", "p95 latency", fmt_seconds, "warn"),
    ("gen_tps", "gen tok/s", lambda v: f"{v:.0f}", "good"),
    ("tokens_out", "tokens out", fmt_count, "good"),
    ("errors", "errors", lambda v: f"{v:.0f}", "bad"),
]

CHART_HEIGHT = 6
_LABEL_WIDTH = 13

# Set from the locale at startup; box-drawing characters are unusable on a
# terminal that cannot encode them.
_UNICODE = True
_BLOCKS = " ▁▂▃▄▅▆▇█"


def set_charset(unicode_ok: bool) -> None:
    global _UNICODE
    _UNICODE = unicode_ok


def sparkline(values: list[float], width: int, peak: float | None = None) -> str:
    """One-row plot of the last `width` values, scaled to their own peak."""
    values = _fit(values, width)
    top = peak if peak is not None else max(values, default=0.0)
    if top <= 0:
        return ("·" if _UNICODE else ".") * len(values)
    # Anything non-zero gets at least the shortest visible mark, so a lone
    # request in a quiet window does not vanish into the baseline.
    if not _UNICODE:
        return "".join(
            " " if v <= 0 else " .:*#"[max(1, min(4, round(v / top * 4)))]
            for v in values
        )
    return "".join(
        _BLOCKS[0] if v <= 0 else _BLOCKS[max(1, min(8, round(v / top * 8)))]
        for v in values
    )


def column_chart(values: list[float], width: int, height: int) -> list[str]:
    """Vertical bar chart, `height` rows tall, topmost row first."""
    values = _fit(values, width)
    top = max(values, default=0.0)
    if top <= 0:
        return [" " * len(values) for _ in range(height)]

    rows = []
    for row in range(height):
        # Eighths of a cell that must be filled for this row to show anything.
        floor_eighths = (height - row - 1) * 8
        line = []
        for value in values:
            eighths = max(1, round(value / top * height * 8)) if value > 0 else 0
            remaining = eighths - floor_eighths
            if remaining <= 0:
                line.append(" ")
            elif remaining >= 8:
                line.append("█" if _UNICODE else "#")
            else:
                line.append(_BLOCKS[remaining] if _UNICODE else "#")
        rows.append("".join(line))
    return rows


def plot_width(width: int) -> int:
    """Columns available to a chart on a terminal `width` wide.

    Callers size the time series to match, so a bucket is exactly one column.
    """
    return max(20, _clamp_width(width) - _LABEL_WIDTH - 3)


def _clamp_width(width: int) -> int:
    return max(60, min(width, 120))


def _fit(values: list[float], width: int) -> list[float]:
    """Resample a series onto exactly `width` columns.

    The dashboard sizes its buckets to the terminal, so this is normally a
    no-op; it matters for the fixed-width plain-text report and for the
    narrower sparklines. Downsampling takes the max of each group rather than
    the mean, so a single spike survives instead of being averaged away.
    """
    width = max(1, width)
    count = len(values)
    if not count:
        return [0.0] * width
    if count == width:
        return list(values)
    if count > width:
        return [
            max(values[count * i // width : max(count * (i + 1) // width,
                                                count * i // width + 1)])
            for i in range(width)
        ]
    return [values[i * count // width] for i in range(width)]


def _section(title: str, width: int) -> tuple[str, str]:
    return ("section", f"-- {title} " + "-" * max(0, width - len(title) - 5))


def build_rows(state: dict, width: int) -> list[tuple[str, str]]:
    """Assemble the whole report as (style, text) rows."""
    width = _clamp_width(width)
    snapshot = state["snapshot"]
    window_label = fmt_window(snapshot["window_seconds"])
    rows: list[tuple[str, str]] = []

    rows.extend(_header(state, width))
    rows.append(_section(f"Requests ({window_label})", width))
    rows.extend(_requests(snapshot, width))
    if snapshot.get("series"):
        rows.append(_section(f"Activity ({window_label})", width))
        rows.extend(_graphs(snapshot, width, state.get("graph_index", 0)))
    rows.append(_section(f"Tokens ({window_label})", width))
    rows.extend(_tokens(snapshot))
    rows.append(_section(f"Models ({window_label})", width))
    rows.extend(_models(snapshot, width))
    return rows


def _header(state: dict, width: int) -> list[tuple[str, str]]:
    server = state["server"]
    service = state["service"]
    library = state["library"]
    clock = datetime.now().strftime("%H:%M:%S")

    version = server["version"] or "?"
    title = f"OLLAMA  {state['hostname']}  v{version}  up {fmt_uptime(service['uptime'])}"
    rows = [("title", f"{title}{clock:>{max(1, width - len(title))}}")]

    if not server["reachable"]:
        rows.append(("bad", f"  Server unreachable at {state['host']} "
                            f"(systemd state: {service['state']})"))
    elif server["loaded"]:
        for model in server["loaded"]:
            expiry = (
                f"expires in {fmt_uptime(model['expires_in'])}"
                if model["expires_in"] and model["expires_in"] > 0
                else "idle"
            )
            rows.append(
                ("good", f"  Loaded  {model['name'][:28]:<28} "
                         f"{fmt_bytes(model['size_vram']):>9} VRAM   {expiry}")
            )
    else:
        rows.append(("dim", "  Loaded  no model resident (server idle)"))

    for gpu in state["gpus"]:
        total = gpu["memory_total"] or 1
        used_fraction = gpu["memory_used"] / total
        rows.append(
            (
                "body",
                f"  GPU{gpu['index']} {gpu['name'][:12]:<12} "
                f"{gpu['memory_used'] / 1024:5.1f}/{total / 1024:4.1f} GB "
                f"[{bar(used_fraction, 10)}] "
                f"{gpu['utilization']:3.0f}%  {gpu['temperature']:.0f}C  {gpu['power']:.0f}W",
            )
        )

    if library["count"]:
        rows.append(
            ("dim", f"  Library {library['count']} models installed, "
                    f"{fmt_bytes(library['disk'])} on disk")
        )
    return rows


def _requests(snapshot: dict, width: int) -> list[tuple[str, str]]:
    stats = snapshot["requests"]
    events = snapshot["events"]
    if not stats["total"]:
        return [("dim", "  No requests in this window")]

    error_style = "bad" if stats["error_rate"] > 0.05 else "body"
    rows = [
        (
            error_style,
            f"  Total {stats['total']:<7} "
            f"Errors {stats['errors']} ({stats['error_rate'] * 100:.1f}%)   "
            f"{stats['per_minute']:.2f} req/min   "
            f"Evictions {events.get('evict', 0)}   Restarts {events.get('restart', 0)}",
        ),
        (
            "body",
            f"  Latency  p50 {fmt_seconds(stats['p50']):<8} "
            f"p95 {fmt_seconds(stats['p95']):<8} "
            f"p99 {fmt_seconds(stats['p99']):<8} "
            f"max {fmt_seconds(stats['max'])}",
        ),
    ]

    busiest = stats["endpoints"][0]["count"] if stats["endpoints"] else 1
    bar_width = max(6, min(18, width - 58))
    for endpoint in stats["endpoints"][:5]:
        label = f"{endpoint['method']} {endpoint['path']}"
        rows.append(
            (
                "dim",
                f"    {label[:30]:<30} {bar(endpoint['count'] / busiest, bar_width)} "
                f"{endpoint['count']:>5}  p95 {fmt_seconds(endpoint['p95'])}",
            )
        )

    clients = "  ".join(f"{ip} ({n})" for ip, n in stats["clients"][:3])
    rows.append(("dim", f"  Clients  {clients}"[: width - 1]))
    return rows


def _graphs(snapshot: dict, width: int, graph_index: int) -> list[tuple[str, str]]:
    """A tall chart of the selected series, then one sparkline for each series."""
    series = snapshot["series"]
    columns = plot_width(width)
    key, label, formatter, style = GRAPHS[graph_index % len(GRAPHS)]
    values = series.get(key, [])
    peak = max(values, default=0.0)

    axis = "│" if _UNICODE else "|"
    corner = "└" if _UNICODE else "+"
    rule = "─" if _UNICODE else "-"

    rows: list[tuple[str, str]] = []
    for row, line in enumerate(column_chart(values, columns, CHART_HEIGHT)):
        # Label the top row with the peak and the bottom with the floor, which
        # is all the y-axis a chart this short can carry honestly.
        if row == 0:
            gutter = f"{formatter(peak):>{_LABEL_WIDTH - 2}} "
        elif row == CHART_HEIGHT - 1:
            gutter = f"{'0':>{_LABEL_WIDTH - 2}} "
        else:
            gutter = " " * (_LABEL_WIDTH - 1)
        rows.append((style, f" {gutter}{axis}{line}"))

    span = fmt_window(snapshot["window_seconds"])
    bucket = fmt_seconds(series["bucket_seconds"])
    rows.append(("dim", f" {' ' * (_LABEL_WIDTH - 1)}{corner}{rule * columns}"))
    footer = f"{span} ago"
    rows.append(
        (
            "dim",
            f" {' ' * _LABEL_WIDTH}{footer}"
            f"{f'{bucket}/col':^{max(1, columns - len(footer) - 3)}}now",
        )
    )
    rows.append(("dim", f"  [{label}]  g cycles series"))

    # Gutter plus the "<peak> peak" suffix costs 28 columns.
    spark_width = max(20, _clamp_width(width) - 28)
    for skey, slabel, sformatter, sstyle in GRAPHS:
        svalues = series.get(skey, [])
        speak = max(svalues, default=0.0)
        marker = ">" if skey == key else " "
        rows.append(
            (
                sstyle if speak else "dim",
                f" {marker}{slabel:>{_LABEL_WIDTH - 2}} "
                f"{sparkline(svalues, spark_width)} "
                f"{sformatter(speak) if speak else '-':>8} peak",
            )
        )
    return rows


def _tokens(snapshot: dict) -> list[tuple[str, str]]:
    tokens = snapshot["tokens"]
    if not tokens["inferences"]:
        return [("dim", "  No inference activity in this window")]
    return [
        (
            "body",
            f"  Generation   {tokens['gen_tps_avg']:7.1f} tok/s avg   "
            f"p50 {tokens['gen_tps_p50']:.0f}   p95 {tokens['gen_tps_p95']:.0f}   "
            f"{tokens['inferences']} inferences",
        ),
        (
            "body",
            f"  Prompt eval  {tokens['prompt_tps_avg']:7.1f} tok/s avg   "
            f"in {fmt_count(tokens['tokens_in'])} tok / "
            f"out {fmt_count(tokens['tokens_out'])} tok",
        ),
    ]


def _models(snapshot: dict, width: int) -> list[tuple[str, str]]:
    models = [m for m in snapshot["models"] if m["inferences"] or m["loads"]]
    if not models:
        return [("dim", "  No model activity in this window")]

    # The output-token column is the first thing dropped on a narrow terminal.
    roomy = width >= 92
    name_width = 26 if roomy else 22

    rows = []
    for model in models[:5]:
        tokens_out = f"{fmt_count(model['tokens_out']):>6} out  " if roomy else ""
        rows.append(
            (
                "body",
                f"  {model['name'][:name_width]:<{name_width}} "
                f"{model['inferences']:>4} infs  "
                f"{model['gen_tps']:6.1f} t/s  "
                f"{tokens_out}"
                f"{model['loads']:>3} loads  avg {model['avg_load_seconds']:.1f}s",
            )
        )
    if any(m["name"] == "unknown" for m in models):
        rows.append(("dim", "  (unknown = activity before the first model-selection log line)"))
    return rows


def render_plain(state: dict, width: int = 100) -> str:
    return "\n".join(text for _, text in build_rows(state, width))


def render_curses(screen, state: dict, paused: bool) -> None:
    screen.erase()
    height, width = screen.getmaxyx()
    rows = build_rows(state, width - 1)

    for y, (style, text) in enumerate(rows):
        if y >= height - 1:
            break
        attr, color = STYLES.get(style, STYLES["body"])
        if curses.has_colors() and color:
            attr |= curses.color_pair(color)
        try:
            screen.addnstr(y, 0, text, width - 1, attr)
        except curses.error:
            pass

    footer = ("  q quit   r refresh   w window   g graph   p "
              + ("resume" if paused else "pause"))
    if paused:
        footer += "   [PAUSED]"
    try:
        screen.addnstr(height - 1, 0, footer.ljust(width - 1), width - 1, curses.A_REVERSE)
    except curses.error:
        pass
    screen.noutrefresh()
    curses.doupdate()


def init_colors() -> None:
    if not curses.has_colors():
        return
    curses.start_color()
    curses.use_default_colors()
    for index, color in enumerate(
        (curses.COLOR_RED, curses.COLOR_GREEN, curses.COLOR_YELLOW,
         curses.COLOR_CYAN, curses.COLOR_MAGENTA, curses.COLOR_BLUE),
        start=1,
    ):
        curses.init_pair(index, color, -1)
