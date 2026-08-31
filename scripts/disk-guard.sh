#!/usr/bin/env bash
#
# disk-guard.sh — daily check that the two things which silently kill this box
# are still healthy: free space, and the HDD itself.
#
#   * $DATA_ROOT filling up stops Transmission writes, stops Plex writes, and
#     makes backup-appdata.sh abort — quietly, because it exits before doing
#     damage. You would not notice until you needed a restore.
#   * $DATA_DISK is the ONLY restore path. No SD image exists, the migration
#     bundles were destroyed. If it is failing you want weeks of warning, not
#     an I/O error.
#
# HOW YOU FIND OUT: this exits non-zero, so the unit shows up in
#
#     systemctl --failed
#
# and nowhere else. You declined push notifications, so nothing pings your
# phone — this is a thing you have to look at. `systemctl status pi-disk-guard`
# shows the last report in full.
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
DATA_DEV="$(env_get DATA_DEV)";   DATA_DEV="${DATA_DEV:-$DATA_DEV}"
DATA_DISK="${DATA_DEV%%[0-9]*}"
# -----------------------------------------------------------------------------

ROOT_PCT_MAX=90        # SD card: appdata, docker images, journal
DATA_PCT_MAX=95        # HDD: media + the only backups
TAILSCALE_ROUTE="$(env_get LAN_SUBNET)"; TAILSCALE_ROUTE="${TAILSCALE_ROUTE:-192.168.0.0/24}"
TAILSCALE_KEY_WARN_DAYS=30

problems=0
note() { echo " !! $*"; problems=$((problems + 1)); }

echo "=== free space ==="
df -h / "$DATA_ROOT" | grep -vE 'tmpfs|udev'
echo

check_pct() {
  local path="$1" max="$2" pct
  pct=$(df -P "$path" | awk 'NR==2{print $5}' | tr -d '%')
  if (( pct >= max )); then
    note "$path is ${pct}% full (threshold ${max}%)."
    case "$path" in
      $DATA_ROOT)
        echo "    Backups abort below ~3.5 GB free. Biggest directories:"
        du -h -d1 $DATA_ROOT 2>/dev/null | sort -rh | head -5 | sed 's/^/      /'
        ;;
      /)
        echo "    Try: docker image prune -a  /  journalctl --vacuum-size=100M"
        ;;
    esac
  else
    echo "OK  $path at ${pct}% (threshold ${max}%)"
  fi
}

if mountpoint -q $DATA_ROOT; then
  check_pct $DATA_ROOT "$DATA_PCT_MAX"
else
  note "$DATA_ROOT is NOT MOUNTED. No backups can run and Plex has no media."
fi
check_pct / "$ROOT_PCT_MAX"

echo
echo "=== HDD health ($DATA_DISK) ==="
if ! command -v smartctl >/dev/null; then
  echo "smartmontools not installed — skipping (apt install smartmontools)"
elif [[ ! -b $DATA_DISK ]]; then
  note "$DATA_DISK does not exist."
else
  # USB-SATA bridges usually need an explicit device type; some pass SMART
  # through natively. Try plain first, then -d sat.
  smart_out="$(smartctl -H -A $DATA_DISK 2>&1 || true)"
  if grep -qi 'unknown usb bridge\|Unsupported\|Please specify device type' <<<"$smart_out"; then
    smart_out="$(smartctl -H -A -d sat $DATA_DISK 2>&1 || true)"
  fi

  if grep -qi 'SMART.*overall-health.*PASSED\|SMART Health Status: OK' <<<"$smart_out"; then
    echo "OK  SMART overall-health: PASSED"
  elif grep -qi 'FAILED' <<<"$smart_out"; then
    note "SMART overall-health reports FAILED — replace this drive now."
    echo "$smart_out" | head -20
  else
    echo "SMART not readable through this USB bridge:"
    echo "$smart_out" | head -5 | sed 's/^/    /'
  fi

  # These four are the ones that actually predict failure. Non-zero and rising
  # over successive runs is the signal; a static non-zero count is not a crisis.
  echo
  grep -E 'Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error' <<<"$smart_out" \
    | awk '{printf "    %-28s raw=%s\n", $2, $NF}' || echo "    (attributes unavailable)"
fi

echo
echo "=== power and thermal ==="
# Under-voltage is the single most under-diagnosed cause of Pi corruption: a
# marginal PSU or a thin USB cable browns out under load, and the symptom is a
# corrupted SD card or a random freeze weeks later, with nothing in the logs.
# The firmware records it and nothing surfaces it, so surface it here.
#
# get_throttled is a bitmask. Bits 0-3 are happening RIGHT NOW; bits 16-19 mean
# "has happened since boot" — and this box reboots weekly, so a sticky bit means
# it happened in the last seven days, which is still worth acting on.
if ! command -v vcgencmd >/dev/null; then
  echo "vcgencmd unavailable — skipping"
else
  raw="$(vcgencmd get_throttled 2>/dev/null || echo 'throttled=0x0')"
  bits=$(( ${raw#throttled=} ))

  (( bits & 0x1 ))     && note "UNDER-VOLTAGE RIGHT NOW. Replace the PSU/cable before it corrupts the SD card."
  (( bits & 0x10000 )) && note "Under-voltage has occurred since boot (within the last week). The PSU or cable is marginal."
  (( bits & 0x4 ))     && note "CPU is being throttled right now — check airflow and the heatsink."
  (( bits & 0x8 ))     && note "Soft temperature limit active right now (>=60C sustained under load)."
  (( bits & 0x40000 )) && echo "    note: thermal throttling occurred since boot"
  (( bits & 0x20000 )) && echo "    note: ARM frequency was capped since boot"
  (( bits == 0 ))      && echo "OK  no under-voltage or throttling since boot (throttled=0x0)"

  temp="$(vcgencmd measure_temp 2>/dev/null | tr -dc '0-9.')"
  if [[ -n "$temp" ]]; then
    # Pi 4 soft-throttles at 80C and hard-throttles at 85C. Warn with headroom.
    if awk -v t="$temp" 'BEGIN{exit !(t >= 75)}'; then
      note "SoC temperature is ${temp}C — approaching the 80C throttle point."
    else
      echo "OK  SoC temperature ${temp}C (throttles at 80C)"
    fi
  fi
fi

echo
echo "=== memory and swap ==="
# zram is already configured by Raspberry Pi OS (2 GB, zstd, priority 100), with
# /var/swap attached via loop as a writeback device. Do NOT install zram-tools
# on top of it — see the README. What matters here is whether zram has started
# writing back to the SD card, because that is real flash wear.
free -h | sed 's/^/    /'
if [[ -r /sys/block/zram0/bd_stat ]]; then
  bd_writes=$(awk '{print $2}' /sys/block/zram0/bd_stat)
  if (( bd_writes > 0 )); then
    echo "    zram has written back $(( bd_writes * 4 / 1024 )) MB to /var/swap on the SD card"
    echo "    (memory pressure is reaching flash — worth investigating what grew)"
  else
    echo "    zram writeback to SD: none"
  fi
fi

echo
echo "=== TLS certificate ==="
# WHY THIS LIVES HERE: no ACME account email is registered with Let's Encrypt
# (the owner's choice, 2026-08-26), so LE has no way to warn about a certificate
# that has quietly stopped renewing. Caddy renews at 2/3 of the lifetime — about
# 30 days out on a 90-day cert — and logs failures to a journal that is
# Storage=volatile on this host, i.e. gone at the next reboot. So a renewal that
# started failing on Monday is invisible by Saturday. This is the only thing
# that would catch it before browsers start refusing to load the dashboard.
#
# Read straight off the live listener rather than out of appdata/caddy/data:
# that tests what clients actually get, including the case where renewal worked
# but Caddy is still serving the old certificate.
CERT_WARN_DAYS=21     # comfortably inside Caddy's ~30-day renewal window, so
                      # this only fires once renewal has genuinely failed
CADDY_DOMAIN="$(sed -nE 's/^[[:space:]]*CADDY_DOMAIN:[[:space:]]*([^[:space:]]+).*/\1/p' \
                /opt/pi-stack/docker-compose.yml 2>/dev/null | head -1)"

if [[ -z "$CADDY_DOMAIN" ]]; then
  echo "no CADDY_DOMAIN in docker-compose.yml — skipping"
elif ! command -v openssl >/dev/null; then
  echo "openssl not installed — skipping"
else
  # -servername is mandatory: Caddy routes on SNI and serves the wildcard
  # certificate only when asked for a name under it. Without it you get an
  # internal fallback certificate and a false alarm every single day.
  end_date="$(echo | timeout 15 openssl s_client -connect 127.0.0.1:443 \
                -servername "home.${CADDY_DOMAIN}" 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"

  if [[ -z "$end_date" ]]; then
    note "Could not read a TLS certificate from :443. Caddy may be down — check: docker logs caddy"
  else
    # GNU date. This runs on the Pi, never on the Mac, where BSD date would
    # need -j -f and a format string instead.
    end_epoch=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
    days_left=$(( (end_epoch - $(date +%s)) / 86400 ))
    issuer="$(echo | timeout 15 openssl s_client -connect 127.0.0.1:443 \
                -servername "home.${CADDY_DOMAIN}" 2>/dev/null \
              | openssl x509 -noout -issuer 2>/dev/null | sed 's/.*CN *= *//' || true)"

    if (( end_epoch == 0 )); then
      note "Could not parse the certificate expiry date ('$end_date')."
    elif [[ "$issuer" == *"Caddy Local Authority"* ]]; then
      # Caddy falls back to its own internal CA when ACME fails, so the site
      # still "works" — with a certificate no browser trusts. Silent by design.
      note "Serving Caddy's INTERNAL certificate, not Let's Encrypt — DNS-01 is failing."
      echo "    Check the DuckDNS token in .env, then: docker logs caddy | grep -i acme"
    elif (( days_left < CERT_WARN_DAYS )); then
      note "TLS certificate expires in ${days_left} days and has not renewed."
      echo "    Caddy renews ~30 days out, so this means renewal is FAILING."
      echo "    Check: docker logs caddy 2>&1 | grep -i 'acme\\|challenge\\|duckdns'"
    else
      echo "OK  *.${CADDY_DOMAIN} valid for ${days_left} more days (issuer: ${issuer:-unknown})"
    fi
  fi
fi

echo
echo "=== ext4 check age ==="
# Informational. ext4 only self-checks on mount count or interval and `defaults`
# sets neither, so nothing here checks itself — that is what pi-fsck-datadrive
# (first Sat of Feb/Aug) is for. Last full check: 2026-08-23, clean.
tune2fs -l "$DATA_DEV" 2>/dev/null | grep -E 'Last checked|Mount count|Maximum mount' | sed 's/^/    /' || true

echo
echo "=== Tailscale ==="
ts_problems_before="$problems"
if ! systemctl is-active --quiet tailscaled; then
  note "tailscaled is not active — remote access and tailnet DNS are unavailable."
elif ! command -v tailscale >/dev/null; then
  note "tailscale CLI is missing even though tailscaled is active."
elif ! command -v jq >/dev/null; then
  note "jq is missing — cannot validate Tailscale status JSON."
else
  ts_json="$(tailscale status --json 2>/dev/null || true)"
  if [[ -z "$ts_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$ts_json"; then
    note "tailscale status did not return valid JSON."
  else
    jq -e '.BackendState == "Running" and .Self.Online == true' >/dev/null <<<"$ts_json" \
      || note "the Pi is not active/online in its tailnet."
    jq -e --arg route "$TAILSCALE_ROUTE" '.Self.PrimaryRoutes // [] | index($route) != null' \
      >/dev/null <<<"$ts_json" \
      || note "Tailscale subnet route $TAILSCALE_ROUTE is not a PrimaryRoute."
    lock_errors="$(jq -r '[.Self, (.Peer // {} | .[])] | map(select((.TailnetLockError // "") != "")) | length' <<<"$ts_json")"
    if (( lock_errors > 0 )); then
      note "$lock_errors Tailscale node(s) report a tailnet lock error."
    fi

    now_epoch="$(date +%s)"
    while IFS=$'\t' read -r peer expiry; do
      [[ -n "$expiry" && "$expiry" != "0001-01-01T00:00:00Z" ]] || continue
      expiry_epoch="$(date -d "$expiry" +%s 2>/dev/null || echo 0)"
      if (( expiry_epoch == 0 )); then
        note "could not parse Tailscale key expiry for $peer ($expiry)."
      elif (( expiry_epoch <= now_epoch )); then
        note "Tailscale key for $peer has expired."
      elif (( expiry_epoch - now_epoch < TAILSCALE_KEY_WARN_DAYS * 86400 )); then
        days=$(( (expiry_epoch - now_epoch) / 86400 ))
        note "Tailscale key for $peer expires in $days days ($expiry)."
      fi
    done < <(jq -r '.Peer // {} | .[] | [(.HostName // .DNSName // "unknown"), (.KeyExpiry // "")] | @tsv' <<<"$ts_json")

    if jq -e '.BackendState == "Running" and .Self.Online == true' >/dev/null <<<"$ts_json" \
       && jq -e --arg route "$TAILSCALE_ROUTE" '.Self.PrimaryRoutes // [] | index($route) != null' >/dev/null <<<"$ts_json" \
       && (( lock_errors == 0 )) && (( problems == ts_problems_before )); then
      echo "OK  Tailscale online; $TAILSCALE_ROUTE is primary; no tailnet lock errors"
    fi
  fi
fi

echo
if (( problems > 0 )); then
  echo "$(date -Is) disk-guard: $problems problem(s) — see above"
  exit 1
fi
echo "$(date -Is) disk-guard ok"
