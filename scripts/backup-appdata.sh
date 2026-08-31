#!/usr/bin/env bash
#
# backup-appdata.sh — snapshot container state to the HDD.
#
# You chose SD-card appdata, so this is the thing standing between a dead SD
# card and rebuilding Homebridge pairings by hand.
#
#     backup-appdata.sh core    nightly 03:30, keeps 7 (~70 MB each)
#     backup-appdata.sh full    weekly  Sat 03:00, keeps 1 (~2.4 GB each)
#
# WHY TWO TIERS: a full snapshot is 2.4 GB and 2.4 GB of that is Plex's
# Metadata/ directory — downloaded posters and artwork. The HDD had 18 GB free
# when this was written, so 7 nightly fulls (16.8 GB) would have filled the
# drive inside a week and taken Plex and Transmission down with it.
#
# What `core` deliberately drops, and what it costs you:
#   Plex Metadata/  — artwork only. Plex re-downloads it from the library DB
#                     over a few hours. Watch state, ratings and library
#                     definitions live in Plug-in Support/Databases, which IS
#                     in every core snapshot.
# Nothing unrecoverable is excluded from `core`.
#
set -euo pipefail

STACK="${STACK:-/opt/pi-stack}"

# --- site configuration ------------------------------------------------------
# Read individual keys out of .env rather than sourcing it. Sourcing would put
# every service password into this script's environment and into that of every
# command it runs, for no benefit — these scripts need paths, not credentials.
env_get() {
  [[ -r "$STACK/.env" ]] || return 0
  sed -nE "s/^[[:space:]]*$1=[\"']?([^\"'#]*[^\"' #])[\"']?[[:space:]]*(#.*)?$/\1/p" \
    "$STACK/.env" | tail -1
}
DATA_ROOT="$(env_get DATA_ROOT)"; DATA_ROOT="${DATA_ROOT:-$DATA_ROOT}"
DATA_DEV="$(env_get DATA_DEV)";   DATA_DEV="${DATA_DEV:-/dev/sda1}"
DATA_DISK="${DATA_DEV%%[0-9]*}"
# -----------------------------------------------------------------------------
DEST="$DATA_ROOT/backup/appdata"
TIER="${1:-core}"
STAMP="$(date +%Y%m%d-%H%M)"

PLEX="appdata/plex/Library/Application Support/Plex Media Server"

case "$TIER" in
  core) KEEP=7 ;;
  full) KEEP=1 ;;
  *)    echo "usage: backup-appdata.sh [core|full]" >&2; exit 1 ;;
esac

# On Saturday the full (03:00) and core (03:30) runs are only 30 minutes apart,
# and a full takes ~5 minutes — but if one ever overruns, two concurrent runs
# would stop and start the same containers underneath each other. Serialise.
exec 9>/run/lock/pi-stack-backup.lock
flock 9

ARCHIVE="$DEST/appdata-${TIER}-${STAMP}.tar.gz"

mountpoint -q $DATA_ROOT || { echo "HDD not mounted — aborting backup." >&2; exit 1; }
mkdir -p "$DEST"

# Refuse to run the drive to 100%. A failed backup is an inconvenience; a full
# data drive stops Transmission and Plex writes dead.
FREE_MB=$(df -Pm "$DEST" | awk 'NR==2{print $4}')
NEED_MB=$([[ "$TIER" == full ]] && echo 3500 || echo 500)
if (( FREE_MB < NEED_MB )); then
  echo "Only ${FREE_MB} MB free on $DATA_ROOT, need ~${NEED_MB} MB for a '$TIER' backup." >&2
  echo "Free space on the data drive, then re-run." >&2
  exit 1
fi

# Pause services with non-database state that benefits from a clean snapshot.
# Filebrowser and Diun use non-SQLite single-file stores, so they must also be
# quiesced rather than copied mid-write. Pi-hole deliberately stays up so LAN
# DNS is never interrupted. SQLite files are copied below through SQLite's
# online backup API, including Plex, so a failed stop cannot tear those files.
cd "$STACK"
PAUSED_SERVICES=(plex transmission homebridge filebrowser diun)
RUNNING_SERVICES=()
for service in "${PAUSED_SERVICES[@]}"; do
  running="$(docker inspect -f '{{.State.Running}}' "$service" 2>/dev/null)" \
    || { echo "Could not inspect $service; refusing to alter service state." >&2; exit 1; }
  [[ "$running" == true ]] && RUNNING_SERVICES+=("$service")
done

# Register cleanup before the first operation that can fail after services are
# touched. Restart only containers that were running when this backup began;
# an operator-stopped service must stay stopped.
SQLITE_STAGE=""
STOP_ATTEMPTED=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$SQLITE_STAGE" ]] && ! rm -rf -- "$SQLITE_STAGE"; then
    echo "Failed to remove SQLite staging directory: $SQLITE_STAGE" >&2
    rc=1
  fi
  if (( STOP_ATTEMPTED == 1 )) && (( ${#RUNNING_SERVICES[@]} > 0 )); then
    if ! docker compose -f "$STACK/docker-compose.yml" start "${RUNNING_SERVICES[@]}" >/dev/null 2>&1; then
      echo "Failed to restart one or more services after backup." >&2
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

SQLITE_STAGE="$(mktemp -d -p /var/tmp pi-stack-sqlite.XXXXXX)"
if (( ${#RUNNING_SERVICES[@]} > 0 )); then
  STOP_ATTEMPTED=1
  if ! docker compose stop "${RUNNING_SERVICES[@]}" >/dev/null 2>&1; then
    echo "Failed to stop all backup writers; aborting snapshot." >&2
    exit 1
  fi
fi

# NOTE: GNU tar requires --exclude BEFORE the path operands, or it warns
# "has no effect" and exits non-zero. Do not reorder these.
EXCLUDES=(
  --exclude="$PLEX/Cache"
  --exclude="$PLEX/Logs"
  --exclude="$PLEX/Crash Reports"
  --exclude='appdata/pihole/etc/gravity.db'       # 94 MB, rebuilt by `pihole -g`
  --exclude='appdata/pihole/etc/gravity_old.db'
  --exclude='appdata/pihole/etc/macvendor.db'
  --exclude='appdata/pihole/etc/pihole-FTL.db*'     # query history only; not configuration
  --exclude='appdata/homebridge/node_modules'     # reinstalled from package.json
)
[[ "$TIER" == core ]] && EXCLUDES+=( --exclude="$PLEX/Metadata" )

# Never copy a live SQLite database byte-for-byte. `.backup` is SQLite's
# supported online snapshot API: it takes a consistent read transaction while
# allowing the service to keep running. The staged tree is added after the main
# appdata tree at the same archive paths. The staged root deliberately has a
# different name: tar exclusions are global, so naming it `appdata` would also
# exclude the replacement copies. A transform maps it back inside the archive.
SQLITE_DATABASES=(
  'appdata/arcane/arcane.db'
  'appdata/beszel/auxiliary.db'
  'appdata/beszel/data.db'
  'appdata/microbin/database.sqlite'
  "appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.dlna.db"
  "appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db"
  "appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
)

for rel in "${SQLITE_DATABASES[@]}"; do
  src="$STACK/$rel"
  [[ -f "$src" ]] || { echo "Required SQLite database missing: $src" >&2; exit 1; }
  dst="$SQLITE_STAGE/sqlite-appdata/${rel#appdata/}"
  mkdir -p "$(dirname "$dst")"
  sqlite3 "$src" ".backup '$dst'"
  chown --reference="$src" "$dst"
  chmod --reference="$src" "$dst"
  touch --reference="$src" "$dst"
  # Never pair the consistent staged DB with live WAL/SHM sidecars from the
  # source tree; replaying those during restore could undo the consistency.
  EXCLUDES+=( --exclude="$rel" --exclude="$rel-wal" --exclude="$rel-shm" )
done

if ! tar -czf "$ARCHIVE" "${EXCLUDES[@]}" \
    --transform='s,^sqlite-appdata,appdata,' \
    -C "$STACK" appdata -C "$SQLITE_STAGE" sqlite-appdata; then
  rm -f -- "$ARCHIVE"
  echo "tar failed; removed incomplete archive." >&2
  exit 1
fi

# Verify before retention. A corrupt new archive must never evict a known-good
# one. gzip -t reads the complete stream and catches truncation/CRC failures.
if ! gzip -t "$ARCHIVE"; then
  rm -f -- "$ARCHIVE"
  echo "Backup verification failed; removed corrupt archive." >&2
  exit 1
fi

# Retention is per-tier: a core snapshot must never evict a full one.
find "$DEST" -name "appdata-${TIER}-*.tar.gz" -type f -printf '%T@ %p\n' \
  | sort -rn | tail -n "+$((KEEP + 1))" | cut -d' ' -f2- | xargs -r rm -f

echo "$(date -Is) $TIER backup ok: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)) — $(df -h "$DEST" | awk 'NR==2{print $4}') free"
