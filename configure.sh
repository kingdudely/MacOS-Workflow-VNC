#!/usr/bin/env bash
set -euo pipefail

# Usage:
# ./configure.sh VNC_USER_PASSWORD VNC_PASSWORD

VNC_USER_PASSWORD="${1:?missing VNC user password}"
VNC_PASSWORD="${2:?missing VNC password}"

# Disable Spotlight indexing
sudo mdutil -i off -a || true

# Create user if it does not exist
if ! id -u vncuser >/dev/null 2>&1; then
  sudo dscl . -create /Users/vncuser
  sudo dscl . -create /Users/vncuser UserShell /bin/bash
  sudo dscl . -create /Users/vncuser RealName "VNC User"
  sudo dscl . -create /Users/vncuser UniqueID 1001
  sudo dscl . -create /Users/vncuser PrimaryGroupID 80
  sudo dscl . -create /Users/vncuser NFSHomeDirectory /Users/vncuser
  sudo dscl . -passwd /Users/vncuser "$VNC_USER_PASSWORD"
  sudo createhomedir -c -u vncuser >/dev/null
else
  sudo dscl . -passwd /Users/vncuser "$VNC_USER_PASSWORD"
fi

# Enable VNC / Apple Remote Desktop
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -allowAccessFor -allUsers -privs -all

sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -clientopts -setvnclegacy -vnclegacy yes

# Set legacy VNC password (max 8 chars, Apple legacy format)
printf '%s\n' "$VNC_PASSWORD" \
| perl -we '
BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA" }
$_ = <>;
chomp;
s/^(.{8}).*/$1/;
@p = unpack "C*", $_;
foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) }
print "\n";
' \
| sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null

fix_tcc_screen_permissions() {
  local db="$1"
  local cmd="$2"  # "sudo sqlite3" or "sqlite3"

  if [[ ! -f "$db" ]]; then
    echo "TCC DB not found: $db"
    return 0
  fi

  echo "Patching TCC DB: $db"

  # CI-safe identities (based on GitHub macOS runner-images config)
  local clients=(
    "/usr/local/opt/runner/provisioner/provisioner"
    "/opt/hca/hosted-compute-agent"
    "com.apple.screensharing.agent"
    "com.apple.screensharing"
  )

  for client in "${clients[@]}"; do
    echo "Granting ScreenCapture to: $client"

    $cmd "$db" "
      INSERT OR IGNORE INTO access VALUES (
        'kTCCServiceScreenCapture',
        '$client',
        1,
        2,
        4,
        1,
        NULL,
        NULL,
        NULL,
        'UNUSED',
        NULL,
        0,
        strftime('%s','now')
      );
    " 2>/dev/null || true
  done

  echo "Granting Accessibility (required for VNC control)..."

  for client in "${clients[@]}"; do
    $cmd "$db" "
      INSERT OR IGNORE INTO access VALUES (
        'kTCCServiceAccessibility',
        '$client',
        1,
        2,
        4,
        1,
        NULL,
        NULL,
        NULL,
        'UNUSED',
        NULL,
        0,
        strftime('%s','now')
      );
    " 2>/dev/null || true
  done

  echo "TCC patch complete for: $db"
}

SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

fix_tcc_screen_permissions "$SYSTEM_TCC" "sudo sqlite3"
fix_tcc_screen_permissions "$USER_TCC"   "sqlite3"

sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -restart -agent -console

sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate

# Install noVNC + websockify so Cloudflare can publish an HTTP URL
brew update
brew install python3 git

git clone https://github.com/novnc/noVNC.git
cd noVNC

# Start websockify/noVNC bridge
# noVNC serves web UI on 6080 and proxies websocket traffic to local VNC 5900.
nohup ./utils/novnc_proxy --vnc 127.0.0.1:5900 --listen 6080 &

# Wait for noVNC web UI
until nc -z -G 1 localhost 6080 &>/dev/null; do
  sleep 1
done
