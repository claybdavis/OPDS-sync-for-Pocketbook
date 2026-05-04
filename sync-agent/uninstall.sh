#!/bin/sh
# uninstall.sh — remove the news-sync agent from InkPad.
# Removes installed scripts, unmounts the netscript.sh overlay, and
# unregisters the launcher entry from view.json. Leaves /mnt/ext1/News/
# contents alone.

set -eu

HOST=${HOST:-inkpad}
# pbjb's SSH password. Run as:  PASS=<your-pbjb-password> ./uninstall.sh
PASS=${PASS:?Set PASS=<your pbjb SSH password>}

SSH="sshpass -p $PASS ssh -o ControlMaster=auto -o ControlPath=/tmp/inkpad-ssh-%C -o ControlPersist=60 -o StrictHostKeyChecking=accept-new $HOST"

echo "→ Unmounting netscript.sh overlay"
$SSH '
    if mount | grep -q " /ebrmain/cramfs/bin/netscript.sh "; then
        umount /ebrmain/cramfs/bin/netscript.sh 2>/dev/null || true
    fi
'

echo "→ Removing files"
$SSH '
    rm -f /mnt/secure/etc/netscript.sh
    rm -f /mnt/ext1/system/bin/news-sync.sh
    rm -f /mnt/ext1/system/init.d/50-news_sync.sh
    rm -f /mnt/ext1/applications/U_SyncNews.app
'

echo "→ Unpatching view.json"
TMP_IN=$(mktemp)
TMP_OUT=$(mktemp)
$SSH "cat /mnt/ext1/system/config/desktop/view.json" > "$TMP_IN"

if ! jq -e '.view.groups[0].apps' "$TMP_IN" >/dev/null 2>&1; then
    echo "Warning: view.json missing .view.groups[0].apps — skipping unpatch (file unchanged)" >&2
    rm -f "$TMP_IN" "$TMP_OUT"
else
    jq 'del(.applications.U_SyncNews)
        | .view.groups[0].apps |= map(select(. != "U_SyncNews"))
       ' "$TMP_IN" > "$TMP_OUT"
    # Atomic write: stream into view.json.tmp, then mv. A flaky WiFi mid-write
    # would otherwise leave view.json truncated and brick the launcher.
    $SSH "cat > /mnt/ext1/system/config/desktop/view.json.tmp \
          && mv /mnt/ext1/system/config/desktop/view.json.tmp \
                /mnt/ext1/system/config/desktop/view.json" < "$TMP_OUT"
    rm -f "$TMP_IN" "$TMP_OUT"
fi

cat <<EOF

Uninstalled. News/ kept.
EOF
