#!/usr/bin/env bash
#
# pull-backups.sh — runs ON THE MAC. Copies the nightly `core` appdata snapshot
# off the Pi so the HDD stops being a single point of failure.
#
# Why this exists: without it the Pi's own USB disk is the ONLY restore path,
# and a single ageing disk is not a backup.
#
# `core` only ("barebones") — tens of MB a night. That excludes Plex's Metadata/
# directory, which is gigabytes of re-downloadable artwork. Everything
# unrecoverable — Homebridge pairings, Plex watch state, Transmission torrents,
# Pi-hole config — is in here.
#
# The Mac PULLS rather than the Pi pushing, deliberately: the Pi then needs no
# credentials for this machine, so a compromised Pi cannot reach back.
#
# Install (once):
#     see com.example.pi-backup-pull.plist.tmpl in this directory
#
# Run by hand any time:
#     ./pull-backups.sh
#
set -euo pipefail

PI="${PI_HOST:-pi}"                    # ~/.ssh/config alias
SRC="${PI_DATA_ROOT:-/mnt/rpidata}/backup/appdata"
DEST="${PI_BACKUP_DEST:-$HOME/pi-backups}"
KEEP=14                                # the Pi keeps 7; keeping 14 here means
                                       # this copy outlives the Pi's rotation

mkdir -p "$DEST"

# BatchMode: never hang on a passphrase or host-key prompt when launchd runs
# this with no terminal attached. If the key needs a passphrase, this fails
# loudly in the log instead of blocking forever.
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15"

if ! ssh $SSH_OPTS "$PI" true 2>/dev/null; then
  echo "$(date "+%Y-%m-%dT%H:%M:%S%z") cannot reach $PI over ssh (asleep, off the network, or key needs a passphrase)"
  exit 1
fi

echo "$(date "+%Y-%m-%dT%H:%M:%S%z") pulling core snapshots from $PI:$SRC"

# No --delete: the Pi rotates at 7, and the whole point is to keep copies the
# Pi no longer has. Local pruning is handled below, on our own terms.
# Plain -a only: macOS ships openrsync, not GNU rsync, so --info=stats1 and
# friends are not available here. The summary at the end of this script does
# the reporting instead.
rsync -a -e "ssh $SSH_OPTS" \
      --include='appdata-core-*.tar.gz' --exclude='*' \
      "$PI:$SRC/" "$DEST/"

# Verify the newest archive is actually readable rather than a truncated
# transfer. A backup you have never tested is a rumour.
newest="$(ls -t "$DEST"/appdata-core-*.tar.gz 2>/dev/null | head -1 || true)"
if [[ -z "$newest" ]]; then
  echo "$(date "+%Y-%m-%dT%H:%M:%S%z") NOTHING PULLED — no core snapshots found on the Pi."
  exit 1
fi
if gzip -t "$newest" 2>/dev/null; then
  echo "$(date "+%Y-%m-%dT%H:%M:%S%z") verified $(basename "$newest") ($(du -h "$newest" | cut -f1))"
else
  echo "$(date "+%Y-%m-%dT%H:%M:%S%z") CORRUPT: $newest failed gzip -t — removing it, will re-pull next run"
  rm -f "$newest"
  exit 1
fi

# Prune oldest beyond KEEP.
ls -t "$DEST"/appdata-core-*.tar.gz 2>/dev/null | tail -n "+$((KEEP + 1))" | while read -r f; do
  echo "$(date "+%Y-%m-%dT%H:%M:%S%z") pruning $(basename "$f")"
  rm -f "$f"
done

echo "$(date "+%Y-%m-%dT%H:%M:%S%z") done — $(ls -1 "$DEST"/appdata-core-*.tar.gz 2>/dev/null | wc -l | tr -d ' ') copies, $(du -sh "$DEST" | cut -f1) total"
