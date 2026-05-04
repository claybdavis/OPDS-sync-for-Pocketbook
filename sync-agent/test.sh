#!/bin/sh
# Mac-side dry-run of news-sync.sh against a scratch dir.
# See ../README.md (§4.6) for setup and usage.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$SCRIPT_DIR/news-sync.sh"

TEST_ROOT="${TEST_ROOT:-/tmp/news-sync-test}"
CATALOGS_SRC="${CATALOGS_SRC:-$HOME/.config/news-sync-test/opds_catalogs}"

if ! command -v flock >/dev/null 2>&1; then
    echo "test.sh: flock not on PATH — run: brew install flock" >&2
    exit 1
fi

if [ ! -f "$CATALOGS_SRC" ]; then
    echo "test.sh: $CATALOGS_SRC not found. One-time setup:" >&2
    echo "  mkdir -p ~/.config/news-sync-test" >&2
    echo "  sshpass -p <your-pbjb-password> scp -O inkpad:/mnt/ext1/system/config/opds_catalogs ~/.config/news-sync-test/opds_catalogs" >&2
    exit 1
fi

mkdir -p "$TEST_ROOT/News" "$TEST_ROOT/state" "$TEST_ROOT/config"
cp "$CATALOGS_SRC" "$TEST_ROOT/config/opds_catalogs"

TMPSCRIPT="$TEST_ROOT/news-sync.sh"
sed \
    -e "s|^DEST=/mnt/ext1/News$|DEST=$TEST_ROOT/News|" \
    -e "s|^LOG=/mnt/ext1/system/state/news-sync.log$|LOG=$TEST_ROOT/state/news-sync.log|" \
    -e "s|/mnt/ext1/system/config/opds_catalogs|$TEST_ROOT/config/opds_catalogs|g" \
    "$SRC" > "$TMPSCRIPT"
chmod +x "$TMPSCRIPT"

echo "→ Test root: $TEST_ROOT"
echo "→ Running rewritten news-sync.sh"
sh "$TMPSCRIPT"
