#!/bin/sh
# Mirror Calibre 'news' OPDS catalog -> /mnt/ext1/News/ on each wifi-up.
# See ../README.md (§4) for invocation, exit codes, behavior.

set -u

resolve_url() {
    case "$1" in
        ""|http://*|https://*) echo "$1" ;;
        //*) echo "https:$1" ;;
        /*) echo "$URL_BASE$1" ;;
        *)  echo "$URL_BASE/$1" ;;
    esac
}

# Single-instance lock: connect events + manual button could fire concurrently.
exec 9>/tmp/news-sync.lock
flock -n 9 || exit 0

DEST=/mnt/ext1/News
LOG=/mnt/ext1/system/state/news-sync.log

# Cap log size: trim to 50 KB once it grows past 100 KB. Bounds disk usage on
# the device, where /mnt/ext1/system/state has no rotation infrastructure.
mkdir -p "$(dirname "$LOG")"
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 102400 ]; then
    tail -c 51200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
# Skip the redirect if either stdout or stderr is a tty — manual diagnostic
# runs see output. A redirect on only one of the two still implies the
# operator wants to see something interactively.
if ! [ -t 1 ] && ! [ -t 2 ]; then
    exec >> "$LOG" 2>&1
fi

# Pull the news catalog URL from opds_catalogs. The OPDS UI writes a JSON
# entry per catalog with user:pass embedded in the URL field — exactly the
# form curl needs. Match on `library_id=news` substring (Calibre's stable
# library identifier) so renaming or re-adding the catalog through the
# OPDS UI works without touching this script.
URL=$(grep -oE 'https?://[^"]*library_id=news[^"]*' /mnt/ext1/system/config/opds_catalogs | head -1)

if [ -z "$URL" ]; then
    echo "news-sync: no catalog matching library_id=news in /mnt/ext1/system/config/opds_catalogs — add via OPDS UI as https://user:pass@host/...?library_id=news" >&2
    exit 2
fi

# Split: pull user:pass out for curl -u, strip them from the URL so CATALOG
# and URL_BASE stay clean (subsequent next-page URLs and any error log lines
# don't carry creds).
CREDS=$(printf '%s' "$URL" | sed -n 's|^https*://\([^/@]*\)@.*|\1|p')
CATALOG=$(printf '%s' "$URL" | sed 's|^\(https*://\)[^/@]*@|\1|')
URL_BASE=$(printf '%s' "$CATALOG" | sed 's|^\([^/]*//[^/]*\).*|\1|')

if [ -z "$CREDS" ]; then
    echo "news-sync: news catalog URL has no embedded user:pass — re-add via OPDS UI as https://user:pass@host/..." >&2
    exit 2
fi

mkdir -p "$DEST"

T=$(mktemp -d /tmp/news-sync.XXXXXX)
trap 'rm -rf "$T"; rm -f "$DEST/.staging.epub"' EXIT INT TERM

# Calibre's OPDS server branches on User-Agent — PocketBook's libopds_data.so
# sends `PocketBook` via FeedLoader::SetCustomUserAgent. Match that.
UA="PocketBook"

NEXT="$CATALOG"
P=0
: > "$T/feed.txt"

while [ -n "$NEXT" ]; do
    P=$((P + 1))
    F="$T/p$P.xml"

    # 300s per-attempt timeout handles slow Pi-side regen; --retry resets the
    # max-time counter, so worst-case wallclock is 3 × 300s + 2 × 5s ≈ 910s.
    if ! curl -fsSL --max-time 300 --retry 2 --retry-delay 5 -A "$UA" -u "$CREDS" "$NEXT" > "$F"; then
        # Page-1 failure: no entries at all, treat as feed fetch error.
        # Mid-pagination failure: abort the whole run cleanly. Acting on a
        # partial entry set could mirror-delete ~140 valid EPUBs from
        # un-fetched pages; the next wifi-up retries from page 1.
        if [ "$P" = 1 ]; then
            echo "news-sync: feed fetch failed: $NEXT" >&2
            exit 3
        fi
        echo "news-sync: page $P fetch failed — aborting run, will retry next wifi-up" >&2
        exit 0
    fi

    N=$(xmllint --xpath 'count(//*[local-name()="entry"])' "$F" 2>/dev/null || echo 0)
    i=1
    while [ "$i" -le "$N" ]; do
        ID=$(xmllint --xpath \
            "string((//*[local-name()='entry'])[$i]/*[local-name()='id']/text())" \
            "$F" 2>/dev/null)
        HREF=$(xmllint --xpath \
            "string((//*[local-name()='entry'])[$i]/*[local-name()='link' \
              and contains(@rel,'opds-spec.org/acquisition') \
              and contains(@type,'epub')]/@href)" \
            "$F" 2>/dev/null)
        if [ -n "$ID" ] && [ -n "$HREF" ]; then
            printf '%s|%s\n' "$ID" "$HREF" >> "$T/feed.txt"
        fi
        i=$((i + 1))
    done

    # Refuse-empty-feed: bail right after page 1 if it parsed zero entries.
    if [ "$P" = 1 ] && [ ! -s "$T/feed.txt" ]; then
        echo "news-sync: feed parsed zero entries — refusing to mirror $DEST" >&2
        exit 5
    fi

    NEXT=$(xmllint --xpath \
        "string(//*[local-name()='feed']/*[local-name()='link' and @rel='next']/@href)" \
        "$F" 2>/dev/null)
    NEXT=$(resolve_url "$NEXT")
done

NEW=0
# Stage in $DEST (not /tmp) so the final mv is a same-FS rename(2) — atomic,
# and avoids the 128 MB tmpfs cap (some EPUBs hit ~130 MB).
EXPECTED="$T/expected.txt"
: > "$EXPECTED"
STAGING="$DEST/.staging.epub"

while IFS='|' read -r ID HREF; do
    NAME=$(printf '%s' "$ID" | sed 's|^urn:uuid:||; s|[^A-Za-z0-9._-]|_|g').epub

    if [ -f "$DEST/$NAME" ]; then
        printf '%s\n' "$NAME" >> "$EXPECTED"
        continue
    fi

    URL=$(resolve_url "$HREF")

    if ! curl -fsSL --max-time 300 --retry 2 --retry-delay 5 -A "$UA" \
            --output "$STAGING" \
            -u "$CREDS" "$URL"; then
        echo "news-sync: download failed: $URL" >&2
        rm -f "$STAGING"
        continue
    fi

    # Zero-byte body: 200 OK + empty payload. Treat as transient.
    if [ ! -s "$STAGING" ]; then
        echo "news-sync: empty download: $URL" >&2
        rm -f "$STAGING"
        continue
    fi

    if ! unzip -l "$STAGING" >/dev/null 2>&1; then
        echo "news-sync: invalid or truncated download: $URL" >&2
        rm -f "$STAGING"
        continue
    fi

    # Atomic rename into place. Same FS, so mv is a rename(2) — no partial
    # state visible to the library scanner.
    if ! mv "$STAGING" "$DEST/$NAME"; then
        echo "news-sync: rename failed: $STAGING -> $DEST/$NAME" >&2
        rm -f "$STAGING"
        continue
    fi

    printf '%s\n' "$NAME" >> "$EXPECTED"
    NEW=$((NEW + 1))
done < "$T/feed.txt"

DEL=0
# Skip mirror-delete when no entries reconciled this run. EXPECTED can only
# be empty here if every entry was a fresh download and every download
# failed (the zero-entry-feed case is refused upstream) — leave DEST alone
# rather than wipe a working set on a transient failure. Also avoids the
# `grep -vFxf <empty>` quirk where -v inverts "matches nothing" to mean
# "matches everything."
if [ -s "$EXPECTED" ]; then
    sort -u -o "$EXPECTED" "$EXPECTED"
    ls "$DEST" | grep -v '^\.' | grep -vFxf "$EXPECTED" > "$T/delete.txt"
    while IFS= read -r NAME; do
        rm -f "$DEST/$NAME" 2>/dev/null
        DEL=$((DEL + 1))
    done < "$T/delete.txt"
fi

echo "news-sync: $(date): +$NEW -$DEL in $DEST"

# Visible library refresh. The firmware's persistent scanner.app picks up
# new files via epoll silently — a second instance grabs the framebuffer so
# the user sees the device redraw the bookshelf. Poll for scanner's own
# "Scan finished" log line, then SIGTERM to dismiss the UI. 30s cap in case
# the line never appears (crash, unknown code path); busybox sleep is
# integer-only so polling is 1-second granularity. Gated on actual changes
# so a wifi flap with +0 -0 doesn't pop a UI over a book in progress. -x
# guard lets Mac test.sh skip cleanly.
if [ "$NEW" -gt 0 ] || [ "$DEL" -gt 0 ]; then
    if [ -x /ebrmain/bin/scanner.app ]; then
        SCANLOG=$(mktemp /tmp/news-sync.scan.XXXXXX)
        /ebrmain/bin/scanner.app >"$SCANLOG" 2>&1 &
        SPID=$!
        i=0
        while [ "$i" -lt 30 ]; do
            if grep -q "Scan finished" "$SCANLOG" 2>/dev/null; then
                break
            fi
            sleep 1
            i=$((i + 1))
        done
        kill -TERM "$SPID" 2>/dev/null
        cat "$SCANLOG" >> "$LOG"
        rm -f "$SCANLOG"
    fi
fi
