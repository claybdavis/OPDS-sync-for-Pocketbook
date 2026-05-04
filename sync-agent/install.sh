#!/bin/sh
# install.sh — push news-sync agent to InkPad and patch view.json.
# Idempotent: safe to re-run.
#
# Prereqs (Mac):
#   brew install hudochenkov/sshpass/sshpass
#   brew install jq
#
# Device prereqs:
#   pbjb installed (provides /mnt/secure/{su,bin/...}, dropbear listening)
#   InkPad reachable as `inkpad` per ~/.ssh/config

set -eu

HOST=${HOST:-inkpad}
# pbjb's SSH password (configurable in pbjb's settings menu on the device).
# Run as:  PASS=<your-pbjb-password> ./install.sh
PASS=${PASS:?Set PASS=<your pbjb SSH password>}

if ! command -v sshpass >/dev/null 2>&1; then
    echo "Error: sshpass not installed (brew install hudochenkov/sshpass/sshpass)" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not installed (brew install jq)" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SSH="sshpass -p $PASS ssh -o ControlMaster=auto -o ControlPath=/tmp/inkpad-ssh-%C -o ControlPersist=60 -o StrictHostKeyChecking=accept-new $HOST"
SCP="sshpass -p $PASS scp -O -o ControlMaster=auto -o ControlPath=/tmp/inkpad-ssh-%C -o ControlPersist=60 -o StrictHostKeyChecking=accept-new"

echo "→ Creating directories"
$SSH "mkdir -p /mnt/ext1/system/bin /mnt/ext1/system/init.d /mnt/ext1/applications /mnt/secure/etc"

echo "→ Copying scripts"
$SCP "$SCRIPT_DIR/news-sync.sh"     "$HOST:/mnt/ext1/system/bin/news-sync.sh"
$SCP "$SCRIPT_DIR/50-news_sync.sh"  "$HOST:/mnt/ext1/system/init.d/50-news_sync.sh"
$SCP "$SCRIPT_DIR/netscript.sh"     "$HOST:/mnt/secure/etc/netscript.sh"
$SCP "$SCRIPT_DIR/U_SyncNews.app"   "$HOST:/mnt/ext1/applications/U_SyncNews.app"
$SSH "chmod +x \
    /mnt/ext1/system/bin/news-sync.sh \
    /mnt/ext1/system/init.d/50-news_sync.sh \
    /mnt/secure/etc/netscript.sh \
    /mnt/ext1/applications/U_SyncNews.app"

echo "→ Patching view.json (idempotent)"
TMP_IN=$(mktemp)
TMP_OUT=$(mktemp)
$SSH "cat /mnt/ext1/system/config/desktop/view.json" > "$TMP_IN"

# Pre-check structure: a firmware update / factory reset could change the
# shape, and jq would fail with a confusing message after the fact.
if ! jq -e '.view.groups[0].apps' "$TMP_IN" >/dev/null 2>&1; then
    echo "Error: view.json missing .view.groups[0].apps — aborting (file unchanged)" >&2
    rm -f "$TMP_IN" "$TMP_OUT"
    exit 1
fi

jq '.applications.U_SyncNews = {
        path: "applications/U_SyncNews.app",
        title: "Sync News"
    }
    | .view.groups[0].apps |= (. + ["U_SyncNews"] | unique)
   ' "$TMP_IN" > "$TMP_OUT"

# Atomic write: stream into view.json.tmp, then mv. A flaky WiFi mid-`cat >`
# would otherwise leave view.json truncated and brick the launcher.
$SSH "cat > /mnt/ext1/system/config/desktop/view.json.tmp \
      && mv /mnt/ext1/system/config/desktop/view.json.tmp \
            /mnt/ext1/system/config/desktop/view.json" < "$TMP_OUT"
rm -f "$TMP_IN" "$TMP_OUT"

echo "→ Installing netscript.sh bind-mount overlay"
$SSH "/mnt/ext1/system/init.d/50-news_sync.sh"

echo "→ Triggering first sync (background)"
$SSH "nohup /mnt/ext1/system/bin/news-sync.sh >> /mnt/ext1/system/state/news-sync.log 2>&1 </dev/null &"

cat <<EOF

Installed. Reboot once to verify wifi-up triggers end-to-end.
Logs:    /mnt/ext1/system/state/news-sync.log
Disable: add news_sync=0 to /mnt/ext1/system/config/rootsettings.cfg
EOF
