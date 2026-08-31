#!/usr/bin/env bash
#
# fsck-datadrive.sh — take $DATA_ROOT offline, check and REPAIR it, put it back.
#
# Runs unattended every 6 months (Feb/Aug) and can be started by hand any time:
#     sudo systemctl start pi-fsck-datadrive.service --no-block
#
# The drive had not been checked since Dec 2022 after ~1584 mounts, because
# Debian ships ext4 with `Maximum mount count: -1` and `Check interval: 0` —
# so nothing ever checks it on its own. This is the deliberate replacement for
# that, on a schedule you control rather than at a surprise boot.
#
# WHY IT MAY REPAIR: this repairs automatically, which is a deliberate trade.
# A repair pass can move corrupted files to lost+found, and a media drive this
# size is typically not backed up in full anywhere. The escalation below
# is the conservative version of that instruction: preen first, which only makes
# changes that are unambiguously safe, and escalate to `-y` only for the
# specific exit code that means "found something preen will not touch".
#
# SAFETY PROPERTIES, in rough order of how badly each would end:
#   * NEVER runs e2fsck against a mounted filesystem. It verifies the unmount
#     twice, by two different methods, and aborts if either says otherwise.
#     e2fsck on a live rw filesystem destroys it.
#   * NEVER lazy-unmounts (`umount -l`). A lazy unmount detaches the tree while
#     writes are still in flight — which would then be exactly the case above.
#     If the unmount fails, this job gives up and puts everything back.
#   * ALWAYS remounts and restarts the containers, via a trap, no matter how it
#     exits — including a failed check.
#   * NO systemd timeout (see the unit). Killing e2fsck part-way through a
#     repair is one of the few ways to turn a fixable filesystem into a lost one.
#
# Logs to the SD card, NOT to $DATA_ROOT/backup — that is on the filesystem
# being unmounted and checked.
#
# `set -e` is deliberately absent: this script's whole job is inspecting exit
# codes that are expected to be non-zero.
set -uo pipefail

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
DATA_DRIVE_UUID="$(env_get DATA_DRIVE_UUID)"

MNT="$DATA_ROOT"
# Resolve the device from the MOUNT, not from DATA_DEV. /dev/sdX is assigned in
# USB enumeration order: plug in a second disk, or reboot with one attached, and
# yesterday's /dev/sda1 is today's /dev/sdb1. This script runs `e2fsck -fy`
# unattended, so pointing it at the wrong device by name is not a recoverable
# mistake — it is the SD card getting "repaired".
DEV="$(readlink -f "$(findmnt -rn -o SOURCE --target "$MNT" 2>/dev/null)" 2>/dev/null || true)"
if [[ -z "$DEV" || ! -b "$DEV" ]]; then
  echo "$(date -Is) REFUSING: nothing mounted at $MNT — cannot identify the target device" >&2
  exit 1
fi

# Cross-check against the UUID in .env. The mount could itself be wrong (a stale
# fstab entry, a disk swapped while powered off); the UUID travels with the
# filesystem, so it is the only identifier worth trusting here.
ACTUAL_UUID="$(blkid -s UUID -o value "$DEV" 2>/dev/null || true)"
if [[ -n "$DATA_DRIVE_UUID" && "$ACTUAL_UUID" != "$DATA_DRIVE_UUID" ]]; then
  echo "$(date -Is) REFUSING: $MNT is backed by $DEV (UUID $ACTUAL_UUID)," >&2
  echo "  but .env says DATA_DRIVE_UUID=$DATA_DRIVE_UUID. Not touching it." >&2
  exit 1
fi
if [[ -z "$DATA_DRIVE_UUID" ]]; then
  echo "$(date -Is) REFUSING: DATA_DRIVE_UUID is unset in $STACK/.env." >&2
  echo "  A repairing fsck will not run against a device it cannot verify." >&2
  exit 1
fi
DATA_DISK="$(lsblk -no PKNAME "$DEV" 2>/dev/null | head -1)"
DATA_DISK="${DATA_DISK:+/dev/$DATA_DISK}"
# -----------------------------------------------------------------------------
LOG="/var/log/pi-fsck.log"
SERVICES=(plex transmission)   # pihole and homebridge do not touch this mount,
                               # so LAN DNS and HomeKit stay up throughout

# Samba serves $DATA_ROOT and smbd keeps its cwd inside the share for as long
# as a client is connected — which is enough to make umount fail with "target is
# busy" even after the containers are stopped. Found the hard way on the first
# run. Any Finder window with the share mounted will disconnect for the duration
# and reconnect afterwards; macOS handles that, though an in-flight copy to the
# share will not survive it.
NATIVE_UNITS=(smbd nmbd)

exec > >(tee -a "$LOG") 2>&1
echo
echo "================================================================"
echo "$(date -Is) fsck-datadrive starting"

say()  { printf '\n>>> %s\n' "$*"; }
warn() { printf ' !! %s\n' "$*"; }

# --- do not collide with the backup, which writes to this very filesystem -----
exec 9>/run/lock/pi-stack-backup.lock
if ! flock -w 1800 9; then
  warn "A backup has held the lock for 30 minutes. Aborting, will retry next window."
  exit 1
fi
if systemctl is-active --quiet pi-quarterly-update.service; then
  warn "Quarterly update in progress. Aborting, will retry next window."
  exit 1
fi

cd "$STACK" || exit 1

# --- everything below must be undone on any exit path -------------------------
restored=0
restore() {
  (( restored )) && return
  restored=1
  say "Restoring service"
  if ! mountpoint -q "$MNT"; then
    mount "$MNT" || warn "MOUNT FAILED — $DATA_ROOT is offline. Plex and Transmission will start with no media."
  fi
  mountpoint -q "$MNT" && df -h "$MNT" | tail -1
  docker compose start "${SERVICES[@]}" || warn "Could not restart: ${SERVICES[*]}"
  systemctl start "${NATIVE_UNITS[@]}" || warn "Could not restart: ${NATIVE_UNITS[*]}"
  echo "$(date -Is) fsck-datadrive finished"
}
trap restore EXIT

say "Stopping ${SERVICES[*]} (Pi-hole and Homebridge stay up — no DNS outage)"
docker compose stop "${SERVICES[@]}" || { warn "Could not stop containers; not touching the filesystem."; exit 1; }

say "Stopping ${NATIVE_UNITS[*]} (the Samba share goes away for the duration)"
systemctl stop "${NATIVE_UNITS[@]}" || warn "Could not stop ${NATIVE_UNITS[*]}; umount will probably fail."

say "Unmounting $MNT"
sync
# smbd's children can linger for a second or two after the unit reports stopped,
# so retry rather than giving up on the first "target is busy".
umounted=0
for attempt in 1 2 3 4 5; do
  if umount "$MNT" 2>/dev/null; then umounted=1; break; fi
  sleep 3
done

if (( ! umounted )); then
  warn "umount failed after 5 attempts — something still holds the mount:"
  fuser -vm "$MNT" 2>&1 | head -20
  warn "Refusing to check a mounted filesystem. Nothing was changed."
  exit 1
fi

# Two independent confirmations. If either still sees it mounted, stop.
# This is the check that stands between a routine maintenance job and a
# destroyed filesystem holding every byte of media you own, so it is worth
# being repetitive about.
if mountpoint -q "$MNT" || findmnt -rn --source "$DEV" >/dev/null 2>&1; then
  warn "$DEV still appears mounted after umount reported success. Aborting."
  exit 1
fi
say "Confirmed unmounted"

# --- the check ----------------------------------------------------------------
# -f forces a full check even if the superblock says clean (the whole point of a
#    scheduled verification; without it, preen exits immediately on a clean flag)
# -p preens: fix only what is unambiguously safe, no questions
# -C 0 emits progress to stdout, which lands in the log
say "e2fsck -fp (preen — safe fixes only)"
e2fsck -fp -C 0 "$DEV"
code=$?

# e2fsck exit codes are a bitmask: 1=errors corrected, 2=corrected+reboot
# advised, 4=errors LEFT UNCORRECTED, 8=operational error, 16=usage, 32=cancelled.
if (( code & 4 )); then
  warn "Preen found problems it will not fix on its own (exit $code)."
  say "Escalating to e2fsck -fy (answer yes to every repair)"
  e2fsck -fy -C 0 "$DEV"
  code=$?
  ESCALATED=1
else
  ESCALATED=0
fi

echo
case $code in
  0)  say "RESULT: clean. No errors found, nothing changed." ;;
  1)  say "RESULT: errors found and CORRECTED." ;;
  2)  say "RESULT: errors CORRECTED; a reboot is advised (Saturday 05:00 will do it)." ;;
  4)  warn "RESULT: errors REMAIN UNCORRECTED even after -y. This needs a human."
      warn "Do not ignore this. The drive is mounting again below, but treat its"
      warn "contents as suspect and get a copy of anything you care about." ;;
  8)  warn "RESULT: e2fsck operational error (exit 8) — could not check the device." ;;
  16) warn "RESULT: e2fsck usage error (exit 16) — this script is wrong, not the disk." ;;
  32) warn "RESULT: cancelled." ;;
  *)  warn "RESULT: unexpected e2fsck exit code $code." ;;
esac

if (( ESCALATED )) || (( code & 3 )); then
  warn "Repairs were made. CHECK $DATA_ROOT/lost+found — recovered fragments"
  warn "land there, and files that vanish from Plex or Transmission are why."
fi

say "Post-check filesystem state"
tune2fs -l "$DEV" | grep -E 'Filesystem state|Last checked|FS Error count|First error|Last error' || true

# restore() runs here via the trap, then this exit code stands.
(( code & 4 )) && exit 1
(( code >= 8 ))  && exit 1
exit 0
