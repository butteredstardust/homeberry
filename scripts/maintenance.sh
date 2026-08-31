#!/usr/bin/env bash
#
# maintenance.sh — weekly housekeeping. Installed by provision.sh as a timer.
#
# Saturday schedule, deliberately staggered so nothing overlaps:
#     03:00  full backup      (backup-appdata.sh full)
#     03:30  core backup      (backup-appdata.sh core, runs nightly anyway)
#     04:00  THIS SCRIPT      apt upgrade + clean out cruft
#     05:00  reboot           (pi-reboot.timer)
#
# The backups run BEFORE the upgrade on purpose: if a package update breaks
# something, the snapshot you roll back to predates it.
#
# This is NOT `rpi-update`. It upgrades from the stable archive only, which is
# the whole point — the previous build died from unattended firmware roulette.
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

say() { printf '\n>>> %s\n' "$*"; }

wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 10; waited=$((waited + 10))
    (( waited >= 600 )) && { echo "apt still locked after 10 min; aborting maintenance." >&2; return 1; }
  done
  return 0
}

say "Disk before"
df -h / "$DATA_ROOT" | grep -v tmpfs

# ------------------------------------------------------------------- apt -----
say "apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
wait_for_apt
apt-get update -qq
# `--with-new-pkgs upgrade`, which is the middle ground between the two obvious
# choices and the only correct one here:
#
#   upgrade              never removes packages, but also refuses anything that
#                        pulls in a NEW package. Kernel meta-packages always do
#                        (linux-image-rpi-v8 -> linux-image-6.18.39-rpi-v8), so
#                        plain `upgrade` holds the kernel back FOREVER. That is
#                        precisely the failure mode this whole rebuild existed
#                        to escape — do not "simplify" this back.
#   full-upgrade         installs the kernel, but may REMOVE packages to resolve
#                        conflicts. Not a decision to make unattended at 4am.
#   --with-new-pkgs      installs new dependencies, never removes anything.
#                        This is also what unattended-upgrades does by default.
apt-get -y -o Dpkg::Options::=--force-confdef \
           -o Dpkg::Options::=--force-confold \
           --with-new-pkgs upgrade

say "Removing orphaned packages and cached .debs"
apt-get -y autoremove --purge
apt-get -y autoclean
apt-get clean

# ---------------------------------------------------------------- docker -----
# Dangling images and dead containers only. NOT `image prune -a`: that would
# delete the previous version of a pinned image, which is exactly what you roll
# back to when a deliberate update goes wrong. Volumes are never pruned — this
# stack uses bind mounts, so anything volume-shaped is unexpected and worth
# looking at by hand rather than deleting at 4am.
if command -v docker >/dev/null; then
  say "Pruning dangling Docker images and stopped containers"
  docker container prune -f
  docker image prune -f
  docker builder prune -f 2>/dev/null || true
fi

# ----------------------------------------------------------------- logs ------
say "Trimming the journal to 14 days / 200M"
journalctl --vacuum-time=14d --vacuum-size=200M

# ----------------------------------------------------------------- state -----
say "Stack health"
docker compose -f "$STACK/docker-compose.yml" ps --format 'table {{.Service}}\t{{.Status}}' || true

if [[ -f /var/run/reboot-required ]]; then
  say "A package update wants a reboot — pi-reboot.timer handles that at 05:00."
fi

say "Disk after"
df -h / "$DATA_ROOT" | grep -v tmpfs

echo
echo "$(date -Is) maintenance ok"
