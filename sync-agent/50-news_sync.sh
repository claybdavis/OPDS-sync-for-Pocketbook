#!/bin/sh
##News auto-sync — bind-mount the patched netscript.sh dispatcher.
# Runs once at boot via pbjb's rcS. After this script runs, every wifi
# up/down event causes monitor.app to invoke our patched dispatcher, whose
# connect branch inlines a background news-sync.sh invocation. No daemon,
# no polling.
#
# pbjb naming: 50-news_sync.sh ↔ news_sync flag in rootsettings.cfg.
# Set news_sync=0 in rootsettings.cfg to disable.

SRC=/mnt/secure/etc/netscript.sh
DST=/ebrmain/cramfs/bin/netscript.sh

[ -f "$SRC" ] || exit 0

# Idempotent: skip if already bind-mounted.
if mount | grep -q " on $DST "; then
    exit 0
fi

mount --bind "$SRC" "$DST"
