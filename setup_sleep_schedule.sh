#!/usr/bin/env bash
set -euo pipefail

# Setup script: Auto-sleep at midnight, wake at 6am via RTC alarm
# Run with:
#   sudo bash setup_sleep_schedule.sh          # install
#   sudo bash setup_sleep_schedule.sh --undo   # remove everything

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo bash $0)"
    exit 1
fi

undo() {
    echo "=== Undoing sleep schedule setup ==="

    echo "--- Stopping and disabling scheduled-sleep timer ---"
    systemctl disable --now scheduled-sleep.timer 2>/dev/null || true

    echo "--- Removing scheduled-sleep service and timer ---"
    rm -f /etc/systemd/system/scheduled-sleep.{service,timer}

    echo "--- Reloading systemd ---"
    systemctl daemon-reload

    echo "--- Clearing any pending RTC wake alarm ---"
    rtcwake -m disable 2>/dev/null || true

    echo ""
    echo "Undo complete! Sleep schedule has been removed."
    exit 0
}

if [[ "${1:-}" == "--undo" || "${1:-}" == "-u" ]]; then
    undo
fi

echo "=== Creating scheduled-sleep service ==="
cat > /etc/systemd/system/scheduled-sleep.service <<'EOF'
[Unit]
Description=Suspend to RAM and wake at 6am

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rtcwake -m disable >/dev/null 2>&1 || true; rtcwake -m mem -l -t $(date -d "6:00" +%%s)'
EOF

echo "=== Creating scheduled-sleep timer (midnight daily) ==="
cat > /etc/systemd/system/scheduled-sleep.timer <<'EOF'
[Unit]
Description=Trigger suspend at midnight daily

[Timer]
OnCalendar=*-*-* 00:00:00
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
echo "  - Machine will suspend at midnight and wake at 6am daily via RTC alarm"
echo "  - To undo: sudo bash $0 --undo"
