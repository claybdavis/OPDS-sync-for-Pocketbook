# InkPad news-sync agent

Shell agent that mirrors a Calibre `news` OPDS feed into a PocketBook InkPad's `/mnt/ext1/News/` on every wifi-up.

> **Heads up — mirror-exactly deletion.** This agent treats your Calibre `news` library as the source of truth for `/mnt/ext1/News/`. Anything in `/News/` that isn't in the current OPDS feed gets deleted on every sync, including files you placed there manually. Move titles you want to keep elsewhere before installing. See §4.4 for the rationale.

Builds on prior MobileRead community work:
- **pbjb (root)** — ezdiy, [thread](https://www.mobileread.com/forums/showthread.php?t=348149) / [repo](https://github.com/ezdiy/pbjb).
- **Enabling OPDS on the InkPad 4** — Drummas, [thread](https://www.mobileread.com/forums/showthread.php?t=359271).
- **OPDS on recent PocketBooks (general)** — pitdicker, [thread](https://www.mobileread.com/forums/showthread.php?t=371671).

This repo assumes both: device is rooted with pbjb, and OPDS is enabled.

---

## 1. Tested device / firmware

- **PocketBook InkPad 4** (model PB743G, e-ink reader)
- **Firmware:** U6.8.4142, Linux 3.10.65 armv7l, glibc 2.23, libstdc++ 6.0.22

### Partition layout (paths the sync agent touches)

| Path | What |
|---|---|
| `/mnt/ext1/News/` | OPDS download destination, hardcoded in `news-sync.sh`. Populated by the same. |
| `/mnt/ext1/system/config/opds_catalogs` | List of OPDS catalogs in JSON. The sync agent reads the URL of the entry containing `library_id=news`; creds come embedded in that URL (see §6). |
| `/mnt/ext1/system/state/` | Log lives here. Survives reboots. |
| `/mnt/secure/` | pbjb's persistence partition (ext2). Provides `su`, dropbear, and the bind-mount target for the patched `netscript.sh`. |

---

## 2. Jailbreak (pbjb v8)

- Device is rooted with **ezdiy's pbjb v8** ([repo](https://github.com/ezdiy/pbjb), [support thread](https://www.mobileread.com/forums/showthread.php?t=348149)).
- SSH password: whatever you set during pbjb install (configurable in pbjb's settings menu on the device).
- **Disable the firewall** in **Settings → Rooted Device Settings**, otherwise WiFi clients can't reach the device (default firewall only allows `169.254.0.0/16` USB link-local).

---

## 3. SSH access

Two paths from a Mac to the device. Each path accepts both auth methods (key or sshpass).

### 3.1 Direct over the same Wi-Fi

`ssh inkpad` → the device's current Wi-Fi IP (visible at PBJB → System status). Add a `Host inkpad` entry to `~/.ssh/config` and update `HostName` when the lease changes.

Works when the Mac and InkPad land on the same access point. No cables. Preferred when it works.

### 3.2 Via Mac Internet Sharing

`ssh inkpad-hotspot` → typically `192.168.2.x` (InkPad's address on the Mac's Wi-Fi hotspot — macOS Internet Sharing's Wi-Fi mode uses this subnet).

Setup: System Settings → General → Sharing → Internet Sharing on. Mac becomes a hotspot; InkPad joins it. Stable while sharing is up. Use this when Wi-Fi separates the Mac and InkPad onto different APs and §3.1 stops working.

### 3.3 Authentication

- **Key auth:** drop your public key in `/mnt/ext1/.ssh/authorized_keys` on the device. The dropbear shipped by pbjb v8 (v2016.74) only accepts RSA / ssh-rsa keys, not ed25519. The vfat 0777 perms there don't bother dropbear v2016.74 in practice — pubkey just works once the file exists. Bootstrap on a fresh jailbreak:

  ```sh
  sshpass -p <your-pbjb-password> ssh inkpad \
      "mkdir -p /mnt/ext1/.ssh && cat >> /mnt/ext1/.ssh/authorized_keys" < ~/.ssh/id_rsa.pub
  ```

- **Password (sshpass):** the password you set in pbjb's settings. Used by `install.sh` / `test.sh` for first-install bootstrap before the key is in place:

  ```sh
  brew install hudochenkov/sshpass/sshpass            # tier-2 tap
  sshpass -p <your-pbjb-password> ssh inkpad <command>
  ```

---

## 4. The sync agent (`news-sync.sh`)

Mirrors the Calibre `news` OPDS catalog into `/mnt/ext1/News/`, then briefly flashes the library scanner UI on changes so the bookshelf re-renders. Filenames on disk are deterministic UUIDs derived from each feed entry's id (the on-device library shows proper titles from each EPUB's metadata). Mirror-exactly semantics — anything not in the current feed gets deleted.

### 4.1 Invocation

Takes no arguments. The download destination `/mnt/ext1/News/` is hardcoded.

### 4.2 Exit codes

| Code | Meaning |
|---|---|
| 0 | ok |
| 2 | no entry in `opds_catalogs` with a URL containing `library_id=news`, or the matched URL has no embedded `user:pass@` — add via OPDS UI as `https://user:pass@host/...?library_id=news` |
| 3 | empty feed body (raw response had zero bytes / first-page fetch failed) |
| 5 | parse error (incl. zero-entry feed — refuse-empty-feed safety) |

Each fetch retries twice on transient HTTP errors before counting as a failure. Mid-pagination network failure: log the page failure and `exit 0` with no downloads or mirror-delete for the run. The retry isn't on a timer — the next wifi-up event (i.e. the next flap/reconnect, or a manual `U_SyncNews.app` tap) re-fires the sync from page 1 and reconciles cleanly. Operators reading the log distinguish a real success (`+N -D in DEST`) from an aborted run by the presence of the `aborting run` line.

### 4.3 Files in `sync-agent/`

| File | Path on device | Purpose |
|---|---|---|
| `news-sync.sh` | `/mnt/ext1/system/bin/news-sync.sh` | The sync script |
| `netscript.sh` | `/mnt/secure/etc/netscript.sh` | Patched netscript.sh, bind-mounted over `/ebrmain/cramfs/bin/netscript.sh` — iterates the firmware's own `/ebrmain/share/netscript.d/*.sh` and inlines a background `news-sync.sh` on connect (with `-x` guard) |
| `50-news_sync.sh` | `/mnt/ext1/system/init.d/50-news_sync.sh` | One-shot bind-mount installer at boot (run by pbjb's rcS) |
| `U_SyncNews.app` | `/mnt/ext1/applications/U_SyncNews.app` | Manual launcher — sh script with `#!/mnt/secure/su /bin/sh` shebang; runs `news-sync.sh` |
| `install.sh` | runs from Mac | scp + jq-patch view.json + bind-mount setup + first sync trigger |
| `uninstall.sh` | runs from Mac | clean removal (incl. `umount` of overlay; unpatches view.json) |
| `test.sh` | runs from Mac | Mac-side dry run against `/tmp/news-sync-test/`; sed-rewrites paths in `news-sync.sh` into a temp copy |

### 4.4 Key design decisions (the non-obvious "why")

- **Mirror-exactly deletion; server is the source of truth.** Anything in `/News/` not in the current feed gets deleted, even mid-read. Catches manually-downloaded books that fall off the server. Dedup is disk-based: filenames are derived from each feed entry's id, so "have I already downloaded this?" is just a file existence check.
- **EPUB integrity gating.** Every downloaded file is run through `unzip -l` before it's allowed into `/News/`. Rejects captive-portal HTML returned as 200 OK, JSON error bodies, and mid-stream truncation (any of which fail to parse as a valid ZIP central directory). A rejected file is skipped for this run and retried next wifi-up.
- **Event-driven, not polled.** The trigger is a wifi-connect hook (`monitor.app` → `netscript.sh connect`). The firmware's `/ebrmain/cramfs/bin/netscript.sh` is read-only, so we bind-mount our patched copy over it at boot. No daemon, no cron.
- **No-config script.** The script reads the news catalog URL out of the device's `opds_catalogs` JSON (the entry whose URL contains `library_id=news`) and pulls user, pass, scheme, and host out of the URL itself. Renaming, re-adding, or rotating the catalog through the OPDS UI works without touching the script, and cosmetic URL drift (trailing slash, query-string reorder, scheme) doesn't break the lookup.
- **One-at-a-time, via `flock` on `/tmp/news-sync.lock`.** A second run started while the first is still going just exits quietly. The kernel releases the lock when the holding process exits, including `kill -9` and battery-out, so a killed sync won't block the next wifi-up.
- **Pagination failure aborts the whole run.** A mid-walk page fetch failure exits 0 with no downloads or mirror-delete. Acting on a partial entry set could mirror-delete ~140 valid EPUBs on un-fetched pages; the cleanest fix is to retry the whole walk on the next wifi-up.
- **Self-trimming log.** When `/mnt/ext1/system/state/news-sync.log` grows past 100 KB, the script trims it to the last 50 KB. The device has no logrotate or syslog daemon — without this the log would grow unbounded.
- **Disable knob.** Setting `news_sync=0` in `/mnt/ext1/system/config/rootsettings.cfg` stops pbjb's rcS from running `50-news_sync.sh` at boot, so the netscript.sh bind-mount never happens and wifi-up stops firing the sync. The manual `U_SyncNews.app` launcher keeps working — it invokes `news-sync.sh` directly, bypassing netscript.sh.
- **Visible library refresh after sync.** When entries were added or deleted, news-sync spawns a fresh `scanner.app` instance. The firmware's persistent scanner.app already indexes new files in `/News/` via epoll, but the bookshelf view doesn't always re-render until prompted. The new instance grabs the framebuffer, runs its scan, and is SIGTERM'd as soon as it logs `Scan finished` — small batches dismiss in under a second, larger batches take a few seconds. A 30s cap dismisses the UI if the line never appears. Gated on `NEW > 0 || DEL > 0` — wifi flaps with no actual content change shouldn't pop a UI over a book in progress.

### 4.5 Install flow

```sh
cd sync-agent
PASS=<your-pbjb-password> ./install.sh   # uses sshpass + jq, reuses one SSH connection, idempotent
```

Required Mac prereqs:
- `brew install hudochenkov/sshpass/sshpass`
- `brew install jq`
- InkPad reachable as `inkpad` per `~/.ssh/config`

Verify:
```sh
sshpass -p <your-pbjb-password> ssh inkpad 'tail -f /mnt/ext1/system/state/news-sync.log'
```

### 4.6 Local testing on Mac

Sanity-check `news-sync.sh` on the Mac before pushing to the device. The wrapper runs a temp copy with three paths sed-rewritten (DEST, LOG, opds_catalogs) — `news-sync.sh` itself is not modified.

Prereqs:
- `brew install flock`
- One-time catalogs copy (the device's sftp-server can't load libcrypto; `scp -O` forces the legacy rcp protocol that bypasses sftp):
  ```sh
  mkdir -p ~/.config/news-sync-test
  sshpass -p <your-pbjb-password> scp -O inkpad:/mnt/ext1/system/config/opds_catalogs \
      ~/.config/news-sync-test/opds_catalogs
  ```

Run:
```sh
cd sync-agent
./test.sh
```

Output streams to the terminal — the script's tty-detection skips the log redirect when stdout is a tty. Test root defaults to `/tmp/news-sync-test/`; override with `TEST_ROOT=...`. Catalogs path overridable with `CATALOGS_SRC=...`.

What this catches: catalog walk, EPUB integrity check (`unzip -l`), atomic rename, mirror-delete logic, log rotation.

Manual scenarios to run by hand:
- **Idempotency:** run twice; second run should be `+0 -0`.
- **Mirror-delete:** drop a junk `.epub` into `$TEST_ROOT/News/`, run again, confirm it gets removed.

What this does NOT catch:
- Actual wifi-up trigger (netscript.sh / 50-news_sync.sh).
- Cross-filesystem rename(2) atomicity on the device's `/mnt/ext1`.
- Busybox-vs-Mac applet quirks — Homebrew has no busybox formula and busybox doesn't build cleanly on macOS, so the wrapper runs against the Mac's BSD coreutils + libxml2 + Homebrew flock. For high-confidence verification, push to the device.

---

## 5. Reference URLs

### pbjb
- Project: https://github.com/ezdiy/pbjb
- v8 release: https://github.com/ezdiy/pbjb/releases/download/v8/pbjb-v8-16-g8f1fb88.zip
- Support thread: https://www.mobileread.com/forums/showthread.php?t=348149

### PocketBook OPDS (on-device)
- Catalog config file: `/mnt/ext1/system/config/opds_catalogs` (JSON)
- Credentials file: `/mnt/ext1/system/config/opds_credentials` (NULL-separated)

### Calibre OPDS endpoints (your server)
- News catalog template: `https://<user>:<pass>@<your-server>/opds/navcatalog/4f6e6577657374?library_id=news` (4f6e6577657374 is hex for "Onewest" → Newest sort)
- Books catalog template: `https://<your-server>/opds?library_id=books`
- OPDS auth: HTTP Basic

---

## 6. Operational gotchas

- **News catalog must be added with creds embedded in the URL.** PocketBook's OPDS reader needs `https://user:pass@host/...` to download individual books (it ignores the separate user/pass fields in the add-catalog dialog for that flow). The OPDS UI stores that URL verbatim in `opds_catalogs`, and news-sync reads it from there.
- **`scp` to/from the device requires `-O`.** The pbjb-bundled `sftp-server` is linked against `libcrypto.so.1.0.0` and the device only ships `libcrypto.so.3` — so the sftp subsystem can't load. `-O` forces scp's legacy rcp protocol, which streams through ssh directly and bypasses sftp-server. `install.sh` and `test.sh` both pass `-O`; any ad-hoc `scp` you run by hand needs it too.
- **`scanner.app` uses epoll, not inotify.** The firmware's persistent scanner.app picks up files dropped into `/News/` via epoll for indexing — but the bookshelf view doesn't always re-render until a fresh scanner.app instance is spawned (which is why news-sync does that at the end of a successful run; see §4.4). Don't reason about behavior from inotify intuitions.
- **`opds.app` has no CLI mode** (confirmed via strings + symbol dump). No headless invocation path.
- **The InkPad's WiFi flaps.** `ServerAliveInterval 30` in ssh_config helps. No `tmux` on the device — use `nohup` for long-running ops.
