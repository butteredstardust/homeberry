#!/usr/bin/env bash
#
# fix-permissions.sh — make every writer on the data drive agree about ownership.
#
# THE BUG THIS FIXES: Transmission's web UI failing to delete files, "fixed"
# periodically with a recursive chmod 777.
#
# It was never permission drift. On the pre-2026 box Transmission ran as the
# packaged `debian-transmission` user, uid 115 / gid 123. That user does not
# exist on this system, and today's Transmission runs as pi (1000) via
# PUID/PGID. Deleting a file requires write+execute on its PARENT DIRECTORY, not
# on the file itself — so any leftover 115:123 directory that was not
# world-writable was undeletable, and 777 was the sledgehammer that made it go
# away until the next one appeared.
#
# So the permanent fix is ownership, not modes. Every writer on this drive is
# now uid 1000:
#     transmission   PUID/PGID 1000     (docker-compose.yml)
#     filebrowser    PUID/PGID 1000     (docker-compose.yml)
#     samba          valid users = pi   (/etc/samba/smb.conf)
#     plex           read-only mount
# Once nothing is owned by a ghost uid, 777 stops being necessary anywhere.
#
# Modes are normalised to match Samba's existing create mask 0664 / directory
# mask 0775, so a file looks the same whichever service created it:
#     directories  2775   setgid: new entries inherit group pi, so a future
#                         service with a different primary group still lands in
#                         the right group instead of re-creating this mess
#     files        0664   group-writable, NOT world-writable
#
# Safe to run live — changing metadata does not disturb active downloads — and
# idempotent, so re-run it any time something looks off.
#
# DELIBERATELY NOT TOUCHED:
#     backup/       root:root on purpose; the backup job runs as root
#     lost+found/   belongs to the filesystem, not to us
#     transcoder/   stale; Plex transcodes to tmpfs now (see README)
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

OWNER="1000:1000"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
mountpoint -q "$DATA_ROOT" || { echo "$DATA_ROOT is not mounted — refusing to run." >&2; exit 1; }

# Driven by MEDIA_SUBFOLDERS in .env, not a hardcoded list, so adding a share is
# an .env edit rather than a code edit. Created if missing: this script is what
# makes the folder layout exist on a fresh drive.
IFS=',' read -r -a _subfolders <<< "$(env_get MEDIA_SUBFOLDERS)"
[[ ${#_subfolders[@]} -gt 0 && -n "${_subfolders[0]}" ]] \
  || _subfolders=(music torrent-complete torrent-inprogress ftp)

TARGETS=()
for _name in "${_subfolders[@]}"; do
  _name="${_name#"${_name%%[![:space:]]*}"}"   # trim leading space
  _name="${_name%"${_name##*[![:space:]]}"}"   # trim trailing space
  [[ -n "$_name" ]] || continue
  # Reject anything that could escape $DATA_ROOT. This runs as root and chowns
  # recursively, so a stray `../` in .env would be a very bad afternoon.
  case "$_name" in
    */*|.|..|/*) echo "Refusing invalid MEDIA_SUBFOLDERS entry: '$_name'" >&2; exit 1 ;;
  esac
  mkdir -p -- "$DATA_ROOT/$_name"
  TARGETS+=("$DATA_ROOT/$_name")
done

say() { printf '\n>>> %s\n' "$*"; }

# Report before acting, so a surprise shows up in the log rather than silently
# being "corrected".
say "Paths not owned by $OWNER right now"
found=0
for t in "${TARGETS[@]}"; do
  [[ -d "$t" ]] || continue
  n=$(find "$t" -xdev ! -uid 1000 -printf . 2>/dev/null | wc -c)
  (( n > 0 )) && { printf '    %-40s %s entries\n' "${t#$DATA_ROOT/}" "$n"; found=$((found + n)); }
done
(( found == 0 )) && echo "    none — ownership is already clean"

say "Normalising"
for t in "${TARGETS[@]}"; do
  if [[ ! -d "$t" ]]; then
    printf '    %-40s absent, skipped\n' "${t#$DATA_ROOT/}"
    continue
  fi
  chown -R "$OWNER" "$t"
  # setgid on directories; plain 0664 on files. Media files carry no meaningful
  # exec bit — the ones that have it inherited it from a blanket 777.
  find "$t" -xdev -type d -exec chmod 2775 {} +
  find "$t" -xdev -type f -exec chmod 0664 {} +
  printf '    %-40s ok\n' "${t#$DATA_ROOT/}"
done

# The mount point itself: group-writable + setgid, not 777.
chown "$OWNER" $DATA_ROOT
chmod 2775 $DATA_ROOT

say "Result"
for t in "${TARGETS[@]}" $DATA_ROOT; do
  [[ -e "$t" ]] && stat -c '    %A %U:%G  %n' "$t"
done

say "Remaining non-1000 paths on the drive (expected: backup/, lost+found/, transcoder/)"
find $DATA_ROOT -xdev ! -uid 1000 -printf '    %u:%g %m %p\n' 2>/dev/null | head -20 || true
