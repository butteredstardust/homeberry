#!/usr/bin/env bash
#
# restore-test.sh — prove the newest core backup can actually be extracted.
#
# This intentionally uses /var/tmp. /tmp is RAM-backed on this Pi and is too
# small for a realistic restore. Nothing is written into the live stack.
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
DATA_ROOT="$(env_get DATA_ROOT)"; DATA_ROOT="${DATA_ROOT:-/mnt/rpidata}"
DATA_DEV="$(env_get DATA_DEV)";   DATA_DEV="${DATA_DEV:-/dev/sda1}"
DATA_DISK="${DATA_DEV%%[0-9]*}"
# -----------------------------------------------------------------------------

BACKUP_DIR="$DATA_ROOT/backup/appdata"
RESTORE_DIR="$(mktemp -d -p /var/tmp pi-stack-restore-test.XXXXXX)"
trap 'rm -rf -- "$RESTORE_DIR"' EXIT

archive="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'appdata-core-*.tar.gz' \
  -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"

[[ -n "$archive" ]] || { echo "No core backup found in $BACKUP_DIR" >&2; exit 1; }
echo "Testing restore from $archive"
tar -xzf "$archive" -C "$RESTORE_DIR"

require_file() {
  [[ -s "$RESTORE_DIR/$1" ]] || { echo "Missing or empty after restore: $1" >&2; exit 1; }
}
require_dir() {
  local path="$RESTORE_DIR/$1"
  [[ -d "$path" ]] && find "$path" -mindepth 1 -print -quit | grep -q . \
    || { echo "Missing or empty after restore: $1" >&2; exit 1; }
}

require_dir 'appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases'
require_dir 'appdata/homebridge/persist'
require_file 'appdata/transmission/settings.json'
require_file 'appdata/pihole/etc/pihole.toml'
require_file 'appdata/beszel-agent/fingerprint'
require_file '.env'

[[ "$(stat -c '%a' "$RESTORE_DIR/.env")" == 600 ]] \
  || { echo "Wrong .env mode after restore (expected 600)" >&2; exit 1; }

[[ "$(stat -c '%U:%G' "$RESTORE_DIR/appdata/beszel-agent")" == "beszel:beszel" ]] \
  || { echo "Wrong Beszel agent ownership after restore" >&2; exit 1; }

# The files can exist and still be useless. Exercise SQLite's reader against
# every database that backup-appdata.sh snapshots through the online API.
SQLITE_DATABASES=(
  'appdata/arcane/arcane.db'
  'appdata/beszel/auxiliary.db'
  'appdata/beszel/data.db'
  'appdata/microbin/database.sqlite'
  'appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.dlna.db'
  'appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db'
  'appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db'
)
for rel in "${SQLITE_DATABASES[@]}"; do
  require_file "$rel"
  if [[ "$rel" == appdata/plex/* ]]; then
    # Plex registers a custom `collating` tokenizer. Stock sqlite3 cannot run
    # quick_check without that extension, but it can still validate the file
    # header and read the schema cookie.
    sqlite3 "$RESTORE_DIR/$rel" 'PRAGMA schema_version;' | grep -qE '^[0-9]+$' \
      || { echo "SQLite schema read failed after restore: $rel" >&2; exit 1; }
  else
    [[ "$(sqlite3 "$RESTORE_DIR/$rel" 'PRAGMA quick_check;')" == "ok" ]] \
      || { echo "SQLite quick_check failed after restore: $rel" >&2; exit 1; }
  fi
done

echo "$(date -Is) restore test ok: $(basename "$archive")"
