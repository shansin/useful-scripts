#!/usr/bin/env bash
set -euo pipefail

# Setup script: Auto-sleep at SLEEP_TIME, wake at WAKE_TIME via RTC alarm
# Run with:
#   sudo bash setup_sleep_schedule.sh <sleep_time> <wake_time>   # install/replace
#   sudo bash setup_sleep_schedule.sh --undo                     # remove everything
#
# Times must be in HH:MM (24h) format, e.g. 00:00 and 06:00
# Re-running with new times replaces the existing schedule (idempotent).

usage() {
    cat <<EOF
Usage:
  sudo bash $0 <sleep_time> <wake_time>
  sudo bash $0 --undo

Arguments:
  sleep_time   Time to suspend, HH:MM 24h format (e.g. 00:00)
  wake_time    Time to wake via RTC, HH:MM 24h format (e.g. 06:00)

Examples:
  sudo bash $0 00:00 06:00
  sudo bash $0 23:30 07:15
  sudo bash $0 --undo
EOF
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo bash $0)"
    exit 1
fi

remove_schedule() {
    systemctl disable --now scheduled-sleep.timer 2>/dev/null || true
    rm -f /etc/systemd/system/scheduled-sleep.service
    rm -f /etc/systemd/system/scheduled-sleep.timer
    systemctl daemon-reload
    rtcwake -m disable 2>/dev/null || true
}

if [[ "${1:-}" == "--undo" || "${1:-}" == "-u" ]]; then
    echo "=== Undoing sleep schedule setup ==="
    remove_schedule
    echo ""
    echo "Undo complete! Sleep schedule has been removed."
    exit 0
fi

if [[ $# -ne 2 ]]; then
    usage
fi

SLEEP_TIME="$1"
WAKE_TIME="$2"

# Validate HH:MM format
time_re='^([01][0-9]|2[0-3]):[0-5][0-9]$'
if [[ ! "$SLEEP_TIME" =~ $time_re ]]; then
    echo "Error: sleep_time '$SLEEP_TIME' is not valid HH:MM (24h)"
    exit 1
fi
if [[ ! "$WAKE_TIME" =~ $time_re ]]; then
    echo "Error: wake_time '$WAKE_TIME' is not valid HH:MM (24h)"
    exit 1
fi

echo "=== Removing any existing schedule ==="
remove_schedule

echo "=== Creating scheduled-sleep service (wake at $WAKE_TIME) ==="
cat > /etc/systemd/system/scheduled-sleep.service <<EOF
[Unit]
Description=Suspend to RAM and wake at $WAKE_TIME

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rtcwake -m disable >/dev/null 2>&1 || true; target=\$(date -d "$WAKE_TIME" +%%s); now=\$(date +%%s); if [ "\$target" -le "\$now" ]; then target=\$(date -d "$WAKE_TIME tomorrow" +%%s); fi; rtcwake -m mem -u -t \$target'
EOF

echo "=== Creating scheduled-sleep timer (sleep at $SLEEP_TIME daily) ==="
cat > /etc/systemd/system/scheduled-sleep.timer <<EOF
[Unit]
Description=Trigger suspend at $SLEEP_TIME daily

[Timer]
OnCalendar=*-*-* $SLEEP_TIME:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

echo "=== Reloading systemd ==="
systemctl daemon-reload

echo "=== Enabling scheduled-sleep timer ==="
systemctl enable --now scheduled-sleep.timer

echo ""
echo "=== Verification ==="
echo ""
echo "--- Timer status ---"
systemctl list-timers scheduled-sleep.timer --no-pager
echo ""
echo "Setup complete!"
echo "  - Machine will suspend at $SLEEP_TIME and wake at $WAKE_TIME daily via RTC alarm"
echo "  - To change schedule: re-run with new times"
echo "  - To undo: sudo bash $0 --undo"
