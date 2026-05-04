#!/bin/sh -v
# Patched netscript.sh — bind-mounted over /ebrmain/cramfs/bin/netscript.sh
# by 50-news_sync.sh at boot.
#
# Preserves the firmware's behaviour of iterating /ebrmain/share/netscript.d/
# (the original was on the read-only cramfs and only knew about that dir),
# and adds a single explicit hand-off to news-sync.sh on connect.

action=$1
echo $0 $action
if [ "$action" = connect ]; then
    for n in /ebrmain/share/netscript.d/*.sh; do
        [ -f "$n" ] || continue
        $n connect
    done
    # news-sync hand-off. Background so we don't block monitor.app's wifi-up
    # path; news-sync.sh's single-instance lock serialises overlapping runs.
    # The -x guard lets the patched netscript.sh degrade gracefully when
    # news-sync.sh isn't on disk (post-uninstall before reboot, test envs).
    [ -x /mnt/ext1/system/bin/news-sync.sh ] && \
        nohup /mnt/ext1/system/bin/news-sync.sh \
            >> /mnt/ext1/system/state/news-sync.log 2>&1 &
fi
