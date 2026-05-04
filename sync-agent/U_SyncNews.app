#!/mnt/secure/su /bin/sh
# Manual launcher — tap the "Sync News" entry in the Apps tab to run the
# sync. news-sync.sh's TTY-detect block redirects its own stdout/stderr to
# the rotated log when invoked without a terminal, so the launcher just
# execs straight in.

exec /mnt/ext1/system/bin/news-sync.sh
