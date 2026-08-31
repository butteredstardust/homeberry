#!/usr/bin/env bash
#
# container-watchdog.sh — restart containers that are running but wedged.
#
# Runs every 5 minutes. `restart: unless-stopped` only reacts when a process
# EXITS; it does nothing about a container that is up, holding its port open,
# and answering nothing. That is the failure this covers, and only that.
#
# Deliberate limits, so this can never become the thing that breaks the house:
#
#   * Two consecutive unhealthy checks (~10 min) before acting. Docker's own
#     healthcheck already retries 3x, so a container has failed for a while
#     before it gets here.
#   * At most MAX_RESTARTS_24H restarts per container per day. Past that it
#     stops trying and says so — a container that needs restarting four times
#     a day has a problem restarting does not fix, and a restart loop on
#     Pi-hole would take LAN DNS down repeatedly.
#   * Never touches a container that is stopped. Stopped means either the
#     backup script paused it or a human stopped it; both are none of this
#     script's business.
#   * Never runs during a backup or the quarterly update.
#
# It restarts. It does not pull, rebuild, or edit compose. Same reasoning as
# the Watchtower note in docker-compose.yml.
#
set -euo pipefail

STACK="${STACK:-/opt/pi-stack}"
STATE="/var/lib/pi-stack/watchdog"
# Derived from docker-compose.yml rather than hand-maintained, so a newly-added
# service is inside the watchdog the moment it is deployed. A hardcoded list
# only has to be forgotten once to leave a service silently unwatched.
#
# `.container_name // .key` because the loop below inspects containers, and this
# stack names most of them explicitly; services that don't get compose's derived
# name. A service with no healthcheck is handled ("nothing to judge"), so
# sweeping in every service costs nothing.
#
# The static list is the fallback for when the compose file is unreadable or
# jq is absent — better a stale list than no watchdog at all.
mapfile -t CONTAINERS < <(
  docker compose -f "$STACK/docker-compose.yml" config --format json 2>/dev/null \
    | jq -r '.services | to_entries[] | .value.container_name // .key' 2>/dev/null
)
if (( ${#CONTAINERS[@]} == 0 )); then
  echo "WARNING: could not read services from docker-compose.yml — using fallback list" >&2
  CONTAINERS=(
    pihole plex transmission homebridge filebrowser arcane
    caddy dozzle diun beszel microbin starbase80
  )
fi
STRIKES=2               # consecutive unhealthy checks before restarting
MAX_RESTARTS_24H=3

mkdir -p "$STATE"

# Do not fight the backup, which stops some of these on purpose. Same
# lock backup-appdata.sh takes; -n means "if a backup is running, just leave".
exec 9>/run/lock/pi-stack-backup.lock
flock -n 9 || { echo "backup in progress — skipping this check"; exit 0; }

if systemctl is-active --quiet pi-quarterly-update.service; then
  echo "quarterly update in progress — skipping this check"
  exit 0
fi

# Restart budget: one timestamp per line, pruned to the last 24h on read.
restarts_last_24h() {
  local f="$STATE/$1.restarts" now
  [[ -f "$f" ]] || { echo 0; return; }
  now=$(date +%s)
  awk -v now="$now" '$1 > now - 86400' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  wc -l < "$f"
}

for c in "${CONTAINERS[@]}"; do
  strike_file="$STATE/$c.strikes"

  running="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo missing)"
  if [[ "$running" != "true" ]]; then
    echo "$c: not running ($running) — leaving it alone"
    rm -f "$strike_file"
    continue
  fi

  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c")"

  case "$health" in
    healthy|starting)
      # `starting` is the start_period grace window — explicitly not a strike.
      [[ -f "$strike_file" ]] && echo "$c: recovered ($health)"
      rm -f "$strike_file"
      continue
      ;;
    none)
      echo "$c: no healthcheck defined — nothing to judge"
      continue
      ;;
  esac

  n=$(( $(cat "$strike_file" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$strike_file"
  echo "$c: UNHEALTHY (strike $n/$STRIKES)"
  (( n < STRIKES )) && continue

  used=$(restarts_last_24h "$c")
  if (( used >= MAX_RESTARTS_24H )); then
    echo "$c: already restarted $used times in 24h — NOT restarting again."
    echo "$c: this needs a human. Start with: docker logs --tail 100 $c"
    continue
  fi

  echo "$c: restarting (${used}/${MAX_RESTARTS_24H} restarts used in the last 24h)"
  date +%s >> "$STATE/$c.restarts"
  rm -f "$strike_file"
  docker restart "$c" || echo "$c: restart command FAILED"
done
