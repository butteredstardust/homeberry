#!/usr/bin/env bash
#
# quarterly-update.sh — the deliberate update window, automated.
#
# Runs 01:00 on the first Saturday of Jan/Apr/Jul/Oct, ahead of that morning's
# normal backup (03:00), maintenance (04:00) and reboot (05:00).
#
#   1. take a full backup FIRST
#   2. apt full-upgrade, but ONLY if it removes nothing
#   3. re-pin every container image and the native Beszel Agent
#   4. health-check every service
#   5. roll back automatically if anything fails
#
# WHY THIS IS NOT WATCHTOWER, which the README still tells you not to install:
# Watchtower pulls continuously, unattended, with no backup, no health gate and
# no way back. The difference that matters is not "automatic vs manual" — it is
# whether a bad image can leave the house without DNS until someone notices.
# Every step below is reversible and the rollback runs without a human.
#
# Images are pinned BY DIGEST in docker-compose.yml. This script rewrites those
# pins; docker-compose.yml stays the single source of truth and every change is
# a readable diff. The previous file is kept for rollback.
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
COMPOSE="$STACK/docker-compose.yml"
PREV="$STACK/.docker-compose.prev.yml"
LOG="$DATA_ROOT/backup/quarterly-update.log"
BESZEL_AGENT_VERSION_FILE="$STACK/beszel-agent-version"
BESZEL_AGENT_PREV_VERSION_FILE="$STACK/.beszel-agent-version.prev"
BESZEL_AGENT_CHANGED=0

# Read out of .env, the single place the domain is configured. Used by the
# health check to verify a real TLS certificate is being served.
CADDY_DOMAIN="$(env_get CADDY_DOMAIN)"
: "${CADDY_DOMAIN:?could not read CADDY_DOMAIN from $STACK/.env}"

# service -> the floating tag that means "current stable" for that publisher.
# linuxserver, pihole and homebridge all use :latest as their stable channel;
# none publishes a dated stable tag we could track instead.
#
# Filebrowser (Quantum) publishes `stable`, `beta` and `dev`. `stable` is the
# v1.5.x line. `beta` is v2.x, which changes the database engine and the config
# schema — tracking it here would upgrade this box into a migration at 01:00 on
# a Saturday with nobody watching. Move it deliberately, not on this list.
CHANNELS=(
  "authelia|authelia/authelia:4.39"
  "pihole|pihole/pihole:latest"
  "plex|lscr.io/linuxserver/plex:latest"
  "transmission|lscr.io/linuxserver/transmission:latest"
  "homebridge|homebridge/homebridge:latest"
  "filebrowser|gtstef/filebrowser:stable"
  "microbin|danielszabo99/microbin:latest"
  "arcane|ghcr.io/getarcaneapp/manager:latest"
  "starbase80|jordanroher/starbase-80:latest"
  "dozzle|amir20/dozzle:latest"
  "diun|crazymax/diun:latest"
  # Both proxy services use this same pin. The rewrite is repository-wide, so
  # one channel entry deliberately updates both occurrences together.
  "socket-proxy|ghcr.io/tecnativa/docker-socket-proxy:0.3.0"
)

# ⚠ CADDY IS NOT IN THE LIST ABOVE, ON PURPOSE. It is the one service that is
# BUILT here (the official image has no DNS provider modules, and Caddy compiles
# plugins in), so there is no upstream digest to pin — the pin is the
# CADDY_VERSION build arg in docker-compose.yml. Step 3b below resolves the
# newest Caddy 2.x, rewrites that arg and rebuilds, which puts it under exactly
# the same backup / health-check / rollback gate as every pulled image.
#
# Only the 2.x line is tracked. A Caddy 3 would be a config-format migration,
# which is not a thing to discover at 01:00 on a Saturday with nobody watching —
# same reasoning as filebrowser's `beta` tag being excluded above.
CADDY_TAGS_URL="https://hub.docker.com/v2/repositories/library/caddy/tags?page_size=100&name=2."

say()  { printf '\n>>> %s\n' "$*"; }
warn() { printf ' !! %s\n' "$*"; }
log()  { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

cd "$STACK"

# --------------------------------------------------------------- health ------
# Returns non-zero if any service is not answering. Generous retries: Plex and
# Homebridge take a while to come up on a Pi after an image change.
health_ok() {
  local tries=30 i
  for (( i = 1; i <= tries; i++ )); do
    local ok=1
    docker exec pihole dig +short +norecurse +retry=0 @127.0.0.1 pi.hole >/dev/null 2>&1 || ok=0
    curl -sf -o /dev/null -m 10 http://127.0.0.1:32400/identity                          || ok=0
    curl -s  -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:9091/ | grep -qE '^(200|301|401)$' || ok=0
    curl -sf -o /dev/null -m 10 http://127.0.0.1:8581/                                   || ok=0
    curl -sf -o /dev/null -m 10 http://127.0.0.1:8082/health                             || ok=0
    curl -sf -o /dev/null -m 10 http://127.0.0.1:3552/api/health                         || ok=0
    # 401 is the healthy answer: MicroBin's index sits behind basic auth.
    curl -s  -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8083/ | grep -qE '^(200|401)$' || ok=0
    # starbase80 rebuilds with Vite before nginx binds, so it is the slowest
    # thing here to answer after an image change — the retry loop covers it.
    # ⚠ 8084, not 80. Caddy owns :80 as of 2026-08-26.
    curl -sf -o /dev/null -m 10 http://127.0.0.1:8084/                                   || ok=0
    curl -sf -o /dev/null -m 10 http://127.0.0.1:8085/                                   || ok=0
    curl -sf -o /dev/null -m 10 http://127.0.0.1:8086/                                   || ok=0
    # The portal is deliberately reachable without an existing session so a
    # user can log in and enrol TOTP. 200 is therefore the healthy unauthenticated
    # response; :8087 is the host break-glass port, not container :9091.
    curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8087/ | grep -q '^200$' || ok=0
    # The authz endpoint redirects a valid unauthenticated request to the
    # configured portal. Observed with v4.39.20: 302 (a request for an unknown
    # domain is 400, so include the real forwarded host in this probe).
    curl -s -o /dev/null -m 10 -w '%{http_code}' \
         -H 'X-Forwarded-Proto: https' -H "X-Forwarded-Host: files.${CADDY_DOMAIN}" \
         -H 'X-Forwarded-URI: /' -H 'X-Forwarded-Method: GET' \
         http://127.0.0.1:8087/api/authz/forward-auth | grep -q '^302$' || ok=0
    systemctl is-active --quiet beszel-agent.service                                     || ok=0
    # Prove the native agent is connected, not merely running, and that its
    # hourly SMART feed is still reaching the hub after a paired update.
    [[ "$(sqlite3 "$STACK/appdata/beszel/data.db" \
      "select count(*) from system_stats where julianday('now')-julianday(created) < 2.0/1440;" 2>/dev/null)" -gt 0 ]] || ok=0
    [[ "$(sqlite3 "$STACK/appdata/beszel/data.db" \
      "select count(*) from smart_devices where name='$DATA_DISK' and state != '' and length(attributes)>2 and julianday('now')-julianday(updated) < 2.0/24;" 2>/dev/null)" -gt 0 ]] || ok=0
    # Caddy, end to end. --resolve pins the name to this box rather than trusting
    # DNS, but the TLS handshake and certificate are verified for real (no -k),
    # so this one line proves the proxy is up, the routing works, AND the
    # Let's Encrypt certificate is currently valid. A silently-failed renewal
    # fails HERE and rolls the quarterly update back.
    curl -sf -o /dev/null -m 15 \
         --resolve "home.${CADDY_DOMAIN}:443:127.0.0.1" \
         "https://home.${CADDY_DOMAIN}/"                                                 || ok=0
    (( ok == 1 )) && return 0
    sleep 10
  done
  return 1
}

rollback() {
  warn "ROLLING BACK to the previous images and native agent"
  log "ROLLBACK triggered"
  cp -a "$PREV" "$COMPOSE"
  if [[ -f "$BESZEL_AGENT_PREV_VERSION_FILE" ]]; then
    cp -a "$BESZEL_AGENT_PREV_VERSION_FILE" "$BESZEL_AGENT_VERSION_FILE"
  fi
  if (( BESZEL_AGENT_CHANGED == 1 )) && [[ -x /opt/beszel-agent/beszel-agent.prev ]]; then
    cp -a /opt/beszel-agent/beszel-agent.prev /opt/beszel-agent/beszel-agent
    [[ -f /opt/beszel-agent/VERSION.prev ]] \
      && cp -a /opt/beszel-agent/VERSION.prev /opt/beszel-agent/VERSION
    systemctl restart beszel-agent.service
  fi
  # --build, because the restored file may carry a different CADDY_VERSION than
  # the image currently built. Without it the rollback would restore the old
  # compose file and keep running the NEW Caddy binary — a half-rolled-back
  # state that is worse than either end.
  docker compose up -d --build
  if health_ok; then
    warn "Rollback succeeded — you are back on the previous images. Investigate before retrying."
    log "rollback OK"
  else
    warn "ROLLBACK ALSO FAILED. Manual intervention required."
    log "ROLLBACK FAILED - manual intervention required"
  fi
}

# ============================================================== 1. BACKUP =====
say "Full backup before touching anything"
"$STACK/scripts/backup-appdata.sh" full

# ================================================================= 2. OS =====
say "OS packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# The weekly job already runs `--with-new-pkgs upgrade`. The only thing left for
# full-upgrade to do is resolve conflicts BY REMOVING packages — which is
# exactly the decision no unattended job should make. So: simulate first, and if
# it wants to remove anything, skip and leave it for a human.
if ! APT_SIMULATION="$(apt-get -s full-upgrade 2>&1)"; then
  warn "full-upgrade simulation FAILED — aborting before package changes:"
  printf '%s\n' "$APT_SIMULATION" >&2
  log "full-upgrade simulation FAILED - no package changes attempted"
  exit 1
fi
REMOVALS="$(grep '^Remv' <<<"$APT_SIMULATION" || true)"
if [[ -n "$REMOVALS" ]]; then
  warn "full-upgrade wants to REMOVE packages — skipping it, review by hand:"
  printf '%s\n' "$REMOVALS"
  log "full-upgrade SKIPPED, wants removals: $(echo "$REMOVALS" | wc -l) package(s)"
  apt-get -y -o Dpkg::Options::=--force-confdef \
             -o Dpkg::Options::=--force-confold --with-new-pkgs upgrade
else
  apt-get -y -o Dpkg::Options::=--force-confdef \
             -o Dpkg::Options::=--force-confold full-upgrade
fi
apt-get -y autoremove --purge
apt-get clean

# ============================================================= 3. IMAGES =====
say "Resolving current stable image digests"
cp -a "$COMPOSE" "$PREV"
cp -a "$BESZEL_AGENT_VERSION_FILE" "$BESZEL_AGENT_PREV_VERSION_FILE"

CHANGED=0
for entry in "${CHANNELS[@]}"; do
  # Preserve each image's own channel tag. Filebrowser tracks `stable`, not
  # `latest` — the tags are not synonyms for this publisher and `beta` is a
  # different major version.
  svc="${entry%%|*}"; ref="${entry#*|}"; repo="${ref%:*}"; tag="${ref##*:}"

  docker pull -q "$ref" >/dev/null 2>&1 || { warn "  $svc: pull failed, keeping current pin"; continue; }
  digest="$(docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' \
            | awk -v r="$ref" '$1 == r {print $2; exit}')"

  if [[ -z "$digest" || "$digest" == "<none>" ]]; then
    warn "  $svc: could not resolve a digest, keeping current pin"
    continue
  fi

  current="$(grep -oE "^[[:space:]]*image:[[:space:]]*${repo}[^[:space:]]*" "$COMPOSE" || true)"
  # A repository may intentionally appear more than once (both socket proxies
  # use the same image). It is current only when EVERY occurrence has the
  # resolved digest; this also repairs partial/manual edits on the next run.
  if [[ -n "$current" ]] && ! grep -Fqv "$digest" <<<"$current"; then
    say "  $svc: already current"
    continue
  fi

  # Rewrite every occurrence in place, leaving comments and formatting intact.
  sed -i -E "s|^([[:space:]]*image:[[:space:]]*)${repo}[^[:space:]]*|\1${repo}:${tag}@${digest}|" "$COMPOSE"
  say "  $svc: re-pinned to ${digest:0:19}..."
  log "$svc updated to $digest"
  CHANGED=1
done

# ============================================================== 3b. CADDY =====
# Built, not pulled, so it needs its own step. Failure here is always
# non-fatal: keep the working pin and let the rest of the update proceed.
say "Resolving current Caddy 2.x release"
CADDY_CURRENT="$(sed -nE 's/^[[:space:]]*CADDY_VERSION:[[:space:]]*([^[:space:]]+).*/\1/p' "$COMPOSE" | head -1)"

# sort -V puts 2.11.4 after 2.9.1; a plain sort would not, and would happily
# "upgrade" this box backwards.
CADDY_LATEST="$(curl -fsS -m 30 "$CADDY_TAGS_URL" 2>/dev/null \
  | tr ',' '\n' | grep -oE '"name":"2\.[0-9]+\.[0-9]+"' \
  | cut -d'"' -f4 | sort -V | tail -1 || true)"

if [[ -z "$CADDY_LATEST" ]]; then
  warn "  caddy: could not reach the tag list, keeping $CADDY_CURRENT"
elif [[ "$CADDY_LATEST" == "$CADDY_CURRENT" ]]; then
  say "  caddy: already current ($CADDY_CURRENT)"
else
  # Both the build arg and the local image tag carry the version, and they must
  # agree or compose rebuilds on every single run.
  sed -i -E "s/^([[:space:]]*CADDY_VERSION:[[:space:]]*).*/\1${CADDY_LATEST}/" "$COMPOSE"
  sed -i -E "s|^([[:space:]]*image:[[:space:]]*pi-stack/caddy:).*|\1${CADDY_LATEST}|" "$COMPOSE"
  say "  caddy: $CADDY_CURRENT -> $CADDY_LATEST"
  log "caddy updated $CADDY_CURRENT -> $CADDY_LATEST"
  CHANGED=1
fi

# ================================================ 3c. NATIVE BESZEL AGENT =====
# The agent is a host binary (for smartctl), not a container. Resolve the exact
# version tag and hub digest as one operation so one can never update without
# the other.
say "Resolving current Beszel hub + agent release"
BESZEL_AGENT_CURRENT="$(tr -d '[:space:]' < "$BESZEL_AGENT_VERSION_FILE")"
BESZEL_AGENT_LATEST="$(curl -fsS -m 30 https://get.beszel.dev/latest-version 2>/dev/null \
  | tr -d '[:space:]v' || true)"

if [[ ! "$BESZEL_AGENT_LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "  beszel: could not resolve a valid release, keeping $BESZEL_AGENT_CURRENT"
else
  BESZEL_HUB_REF="henrygd/beszel:$BESZEL_AGENT_LATEST"
  if ! docker pull -q "$BESZEL_HUB_REF" >/dev/null 2>&1; then
    warn "  beszel: exact hub pull failed, keeping hub and agent at $BESZEL_AGENT_CURRENT"
  else
    BESZEL_HUB_DIGEST="$(docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' \
      | awk -v r="$BESZEL_HUB_REF" '$1 == r {print $2; exit}')"
    BESZEL_HUB_CURRENT="$(grep -oE '^[[:space:]]*image:[[:space:]]*henrygd/beszel:[^[:space:]]*' "$COMPOSE" | head -1)"
    if [[ -z "$BESZEL_HUB_DIGEST" || "$BESZEL_HUB_DIGEST" == "<none>" ]]; then
      warn "  beszel: exact hub digest unavailable, keeping hub and agent at $BESZEL_AGENT_CURRENT"
    elif [[ "$BESZEL_AGENT_LATEST" == "$BESZEL_AGENT_CURRENT" && "$BESZEL_HUB_CURRENT" == *"$BESZEL_HUB_DIGEST"* ]]; then
      say "  beszel hub + agent: already current ($BESZEL_AGENT_CURRENT)"
    else
      sed -i -E "s|^([[:space:]]*image:[[:space:]]*)henrygd/beszel:[^[:space:]]*|\1${BESZEL_HUB_REF}@${BESZEL_HUB_DIGEST}|" "$COMPOSE"
      printf '%s\n' "$BESZEL_AGENT_LATEST" > "$BESZEL_AGENT_VERSION_FILE"
      say "  beszel hub + agent: $BESZEL_AGENT_CURRENT -> $BESZEL_AGENT_LATEST"
      log "beszel hub + agent selected $BESZEL_AGENT_CURRENT -> $BESZEL_AGENT_LATEST"
      CHANGED=1
    fi
  fi
fi

if (( CHANGED == 0 )); then
  say "All managed components already current; verifying services after the OS update"
  if ! health_ok; then
    warn "Health check FAILED after the OS update. Package changes cannot be rolled back automatically."
    log "OS-only update FAILED health check - manual intervention required"
    rm -f "$PREV" "$BESZEL_AGENT_PREV_VERSION_FILE"
    exit 1
  fi
  log "OS-only update OK, all services healthy"
  rm -f "$PREV" "$BESZEL_AGENT_PREV_VERSION_FILE"
  exit 0
fi

# ====================================================== 4. APPLY + VERIFY =====
say "Applying"
# --build is what actually recompiles Caddy. It is a Go build inside a container
# on a Pi 4 — allow a couple of minutes, and note it downloads the Go module
# cache fresh each time because the builder stage is not layer-cached across a
# version bump.
if ! docker compose up -d --build; then
  warn "compose up failed"
  rollback
  exit 1
fi

BESZEL_AGENT_TARGET="$(tr -d '[:space:]' < "$BESZEL_AGENT_VERSION_FILE")"
BESZEL_AGENT_INSTALLED="$(cat /opt/beszel-agent/VERSION 2>/dev/null || true)"
if [[ "$BESZEL_AGENT_TARGET" != "$BESZEL_AGENT_INSTALLED" ]]; then
  # Mark the transaction before invoking the installer. If it replaces the
  # binary and then fails, rollback must still restore the saved predecessor.
  BESZEL_AGENT_CHANGED=1
  if ! "$STACK/scripts/install-beszel-agent.sh" "$BESZEL_AGENT_TARGET"; then
    warn "Beszel Agent install failed"
    rollback
    exit 1
  fi
  if ! systemctl restart beszel-agent.service; then
    warn "Beszel Agent restart failed"
    rollback
    exit 1
  fi
fi

say "Health check (up to 5 minutes)"
if health_ok; then
  say "All services healthy on the new versions."
  log "update OK, all services healthy"
  docker image prune -f >/dev/null 2>&1 || true
  rm -f "$PREV" "$BESZEL_AGENT_PREV_VERSION_FILE" \
    /opt/beszel-agent/beszel-agent.prev /opt/beszel-agent/VERSION.prev
else
  warn "Health check FAILED on the new images."
  rollback
  exit 1
fi

say "Quarterly update complete"
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
