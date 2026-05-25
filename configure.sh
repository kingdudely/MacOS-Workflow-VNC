#!/usr/bin/env bash
set -euo pipefail

# ========= Inputs =========
VNC_USER="vncuser"
VNC_USER_PW="${VNC_USER_PASSWORD:-${1:-}}"
VNC_PASS="${VNC_PASSWORD:-${2:-}}"

# ========= Debug =========
echo "[DEBUG] VNC_USER_PASSWORD length: ${#VNC_USER_PW}"
echo "[DEBUG] VNC_PASSWORD length: ${#VNC_PASS}"

# ========= Validation =========
if [[ -z "${VNC_USER_PW}" || -z "${VNC_PASS}" ]]; then
  echo "[ERROR] Missing required passwords" >&2
  exit 1
fi

# ========= Disable Spotlight =========
sudo mdutil -i off -a || true

# ========= Create / update user =========
echo "[INFO] Ensuring user: ${VNC_USER}"
if ! id -u "${VNC_USER}" >/dev/null 2>&1; then
  sudo sysadminctl -addUser "${VNC_USER}" -password "${VNC_USER_PW}" -admin || true
else
  sudo sysadminctl -resetPasswordFor "${VNC_USER}" -newPassword "${VNC_USER_PW}" || true
fi

sudo sysadminctl -secureTokenStatus "${VNC_USER}" || true

# ========= Enable Apple Remote Management =========
KICK="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

sudo "$KICK" -configure -allowAccessFor -allUsers -privs -all
sudo "$KICK" -configure -clientopts -setvnclegacy -vnclegacy yes

# ========= Set VNC password (legacy Apple format, max 8 chars) =========
printf '%s\n' "$VNC_PASS" | perl -we '
BEGIN {
  @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA";
}
$_ = <>;
chomp;
s/^(.{8}).*/$1/;
@p = unpack "C*", $_;
foreach (@k) {
  printf "%02X", $_ ^ (shift @p || 0);
}
print "\n";
' | sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null

# ========= Restart ARD/VNC services =========
sudo "$KICK" -restart -agent -console
sudo "$KICK" -activate

# ========= Reset TCC permissions =========
sudo tccutil reset ScreenCapture || true
sudo tccutil reset SystemPolicyNetworkVolumes || true

# ========= Install dependencies =========
brew update
brew install python3 git

# ========= Install noVNC =========
if [[ ! -d noVNC ]]; then
  git clone https://github.com/novnc/noVNC.git
fi

cd noVNC

# ========= Start noVNC (VNC -> WebSocket bridge) =========
echo "[INFO] Starting noVNC on :6080"
nohup ./utils/novnc_proxy --vnc 127.0.0.1:5900 --listen 6080 &

# Wait for noVNC
until nc -z localhost 6080 >/dev/null 2>&1; do
  sleep 1
done

echo "[INFO] noVNC running on http://localhost:6080"
