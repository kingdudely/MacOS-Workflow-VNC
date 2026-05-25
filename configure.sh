#!/usr/bin/env bash
set -euo pipefail

VNC_USER_PASSWORD="${1:?missing user password}"

echo "Ensuring vncuser exists..."

if ! id -u vncuser >/dev/null 2>&1; then
  sudo sysadminctl -addUser vncuser \
    -fullName "VNC User" \
    -password "$VNC_USER_PASSWORD"
fi

echo "Waiting for screen sharing service..."

until pgrep screensharingd >/dev/null 2>&1; do
  sleep 2
done

echo "Waiting for VNC port..."

until lsof -i :5900 >/dev/null 2>&1; do
  sleep 2
done

echo "Starting noVNC..."

cd /opt/novnc || git clone https://github.com/novnc/noVNC.git /opt/novnc
cd /opt/novnc

nohup ./utils/novnc_proxy \
  --vnc 127.0.0.1:5900 \
  --listen 6080 >/tmp/novnc.log 2>&1 &

echo "READY: http://localhost:6080"
