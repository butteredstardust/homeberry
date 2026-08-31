#!/usr/bin/env bash
#
# provision.sh — turn a fresh 64-bit Raspberry Pi OS LITE image (Bookworm 12
#                or Trixie 13) into the host for pi-stack.
#
# RUN ON THE NEW PI:
#     sudo bash /opt/pi-stack/provision.sh [phase]
#
# Phases (default: all) — each is idempotent and re-runnable alone:
#     base drive perms docker native firewall samba dns stack backup
#     maintenance quarterly watchdog heal beszelagent diskguard fsck
#
set -euo pipefail

STACK="${STACK:-/opt/pi-stack}"
PHASE="${1:-all}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

say()  { printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m !! %s\033[0m\n' "$*"; }
run()  { [[ "$PHASE" == "all" || "$PHASE" == "$1" ]]; }

# On a fresh image, unattended-upgrades fires shortly after first boot and holds
# the dpkg lock for several minutes. Without this, every apt-get below dies with
# "Could not get lock /var/lib/dpkg/lock-frontend".
wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    (( waited == 0 )) && warn "Waiting for another apt/dpkg process to finish..."
    sleep 10; waited=$((waited + 10))
    if (( waited >= 900 )); then
      warn "Still locked after 15 minutes. Investigate: ps aux | grep -E 'apt|dpkg'"
      return 1
    fi
  done
  (( waited > 0 )) && say "apt lock released after ${waited}s"
  return 0
}
apt_install() { wait_for_apt; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

if [[ "$(dpkg --print-architecture)" != "arm64" ]]; then
  warn "Architecture is $(dpkg --print-architecture), expected arm64."
  warn "The point of this rebuild is escaping the 32-bit userland. Re-image."
  read -rp "Continue anyway? [y/N] " a; [[ "$a" == [yY] ]] || exit 1
fi

[[ -f "$STACK/.env" ]] || { echo "Missing $STACK/.env — copy .env.example and fill it in." >&2; exit 1; }
set -a; . "$STACK/.env"; set +a

# Site configuration, all from .env. Defaults exist only where a wrong value is
# harmless; LAN_IP and CADDY_DOMAIN have none, because a placeholder that boots
# is worse than one that stops.
: "${LAN_IP:?set LAN_IP in $STACK/.env}"
: "${CADDY_DOMAIN:?set CADDY_DOMAIN in $STACK/.env}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-raspberrypi}"
LOCAL_DNS_NAME="${LOCAL_DNS_NAME:-home.internal}"
DATA_ROOT="${DATA_ROOT:-/mnt/rpidata}"
DATA_DEV="${DATA_DEV:-/dev/sda1}"
DATA_SHARE_NAME="$(basename "$DATA_ROOT")"
# systemd names a mount unit after the escaped path: /mnt/data becomes
# mnt-data.mount.
# Derive it rather than hardcoding, or every After=/Requires= below silently
# refers to a unit that does not exist and the ordering quietly does nothing.
DATA_MOUNT_UNIT="$(systemd-escape -p --suffix=mount "$DATA_ROOT")"

# ================================================================== BASE =====
if run base; then
  say "Base system"
  hostnamectl set-hostname "$LOCAL_HOSTNAME"
  timedatectl set-timezone "${TZ:-Etc/UTC}"

  wait_for_apt
  apt-get update
  apt_install apparmor ca-certificates curl git jq rsync sqlite3 unattended-upgrades vim

  # Security patches, applied unattended. This is the sane replacement for the
  # old weekly `rpi-update -y` cron: stable archive only, no firmware roulette.
  dpkg-reconfigure -f noninteractive unattended-upgrades

  say "Hardening SSH (key-only)"
  install -d /etc/ssh/sshd_config.d
  install -o root -g root -m 644 "$STACK/config/ssh-hardening.conf" \
          /etc/ssh/sshd_config.d/10-hardening.conf
  # Refuse to lock ourselves out: only apply if a key is actually present.
  if [[ -s /home/pi/.ssh/authorized_keys ]]; then
    systemctl reload ssh
  else
    warn "No authorized_keys for pi — leaving password auth ENABLED."
    warn "Run 'ssh-copy-id pi@${LAN_IP}' from your workstation, then: sudo systemctl reload ssh"
    rm -f /etc/ssh/sshd_config.d/10-hardening.conf
  fi

  # --- memory cgroup controller ------------------------------------------
  # The Pi firmware passes `cgroup_disable=memory` on the kernel command line,
  # so without this every `mem_limit:` in docker-compose.yml is discarded
  # SILENTLY — `docker inspect` just reports Memory=0. Appending at the END of
  # the line is what makes it work: the kernel runs the cgroup_enable handler
  # after the firmware's disable.
  #
  # ⚠ cmdline.txt must remain ONE line. An embedded newline makes the Pi
  # unbootable, and there is no serial console — recovery means putting the SD
  # card in another machine (the partition is FAT32, so any machine will do).
  # Hence: back up first, refuse outright if the file is already multi-line,
  # and write with printf rather than appending with >> which would add \n.
  CMDLINE=/boot/firmware/cmdline.txt
  if [[ ! -f "$CMDLINE" ]]; then
    warn "$CMDLINE not found — skipping memory cgroup setup"
  elif grep -q 'cgroup_enable=memory' "$CMDLINE"; then
    say "Memory cgroup already enabled in cmdline.txt"
  elif [[ "$(wc -l < "$CMDLINE")" -gt 1 ]]; then
    warn "$CMDLINE has more than one line — refusing to edit it. Fix by hand."
  else
    cp -n "$CMDLINE" "${CMDLINE}.bak"
    printf '%s cgroup_enable=memory cgroup_memory=1' \
      "$(tr -d '\n' < "$CMDLINE")" > "${CMDLINE}.new"
    mv "${CMDLINE}.new" "$CMDLINE"
    say "Memory cgroup enabled in cmdline.txt (backup: ${CMDLINE}.bak)"
    warn "Takes effect on the NEXT REBOOT. Containers created before that reboot"
    warn "keep their old limit — recreate them: docker compose up -d --force-recreate"
  fi

  # Raspberry Pi's kernel has AppArmor compiled in and even selects it as the
  # default security module, but CONFIG_LSM is empty in the vendor build. The
  # result is deceptively half-enabled: securityfs is mounted and the apparmor
  # package is installed, yet /sys/kernel/security/lsm contains only
  # "capability" and apparmor.service is skipped. Select the built-in module
  # explicitly at boot. Docker will then generate and enforce docker-default.
  if [[ ! -f "$CMDLINE" ]]; then
    warn "$CMDLINE not found — skipping AppArmor kernel enablement"
  elif grep -qw 'security=apparmor' "$CMDLINE"; then
    say "AppArmor already selected in cmdline.txt"
  elif [[ "$(wc -l < "$CMDLINE")" -gt 1 ]]; then
    warn "$CMDLINE has more than one line — refusing to edit it. Fix by hand."
  else
    cp -n "$CMDLINE" "${CMDLINE}.bak-apparmor"
    printf '%s security=apparmor' \
      "$(tr -d '\n' < "$CMDLINE")" > "${CMDLINE}.new"
    mv "${CMDLINE}.new" "$CMDLINE"
    say "AppArmor selected in cmdline.txt (backup: ${CMDLINE}.bak-apparmor)"
    warn "Takes effect on the NEXT REBOOT. Verify afterward with: aa-status"
  fi
fi

# ================================================================= DRIVE =====
if run drive; then
  say "Mounting the data drive at $DATA_ROOT (never reformatted — UUID is stable)"
  mkdir -p "$DATA_ROOT"

  # The drive is addressed by FILESYSTEM UUID, not by /dev/sdX, because device
  # ordering is not stable across reboots — plug in a second USB disk and the
  # names swap. DATA_DEV is only used to LOOK UP the UUID the first time.
  #
  # ⚠ There is deliberately no default UUID and no way to proceed with a
  # placeholder: a bogus UUID in /etc/fstab is a line that never mounts and,
  # with the wrong options, a Pi that will not boot. If .env has no UUID we
  # detect one, show it, and make you confirm it.
  if [[ -z "${DATA_DRIVE_UUID:-}" || "$DATA_DRIVE_UUID" == *changeme* || "$DATA_DRIVE_UUID" == "<"* ]]; then
    [[ -b "$DATA_DEV" ]] || {
      warn "DATA_DEV=$DATA_DEV is not a block device. Find the right one with:"
      warn "    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT"
      warn "then set DATA_DEV in $STACK/.env and re-run: sudo bash $0 drive"
      exit 1
    }
    DATA_DRIVE_UUID="$(blkid -s UUID -o value "$DATA_DEV" || true)"
    [[ -n "$DATA_DRIVE_UUID" ]] || { warn "No filesystem UUID on $DATA_DEV. Is it formatted?"; exit 1; }
    echo
    lsblk -o NAME,SIZE,FSTYPE,LABEL "$DATA_DEV"
    warn "About to add $DATA_DEV (UUID=$DATA_DRIVE_UUID) to /etc/fstab as $DATA_ROOT."
    warn "THIS MUST BE YOUR DATA DISK, NOT THE SD CARD."
    read -rp "Correct? [y/N] " a; [[ "$a" == [yY] ]] || exit 1
    # Write it back so later phases and fsck-datadrive.sh agree with fstab.
    if grep -q '^DATA_DRIVE_UUID=' "$STACK/.env"; then
      sed -i "s|^DATA_DRIVE_UUID=.*|DATA_DRIVE_UUID=$DATA_DRIVE_UUID|" "$STACK/.env"
    else
      echo "DATA_DRIVE_UUID=$DATA_DRIVE_UUID" >> "$STACK/.env"
    fi
    say "Recorded DATA_DRIVE_UUID in $STACK/.env"
  fi

  if ! grep -q "$DATA_DRIVE_UUID" /etc/fstab; then
    # Dropped the old `users` option, which silently implied noexec,nosuid,nodev.
    # nofail keeps the Pi booting if the USB disk is absent or slow to appear.
    echo "UUID=$DATA_DRIVE_UUID $DATA_ROOT ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount -a || true
  if mountpoint -q "$DATA_ROOT"; then
    df -h "$DATA_ROOT" | tail -1
    mkdir -p "$DATA_ROOT/backup/appdata"
    chown -R 1000:1000 "$DATA_ROOT/backup"
  else
    warn "Data drive NOT mounted. Check the USB disk, then: sudo mount -a"
    warn "Everything downstream depends on this. Fix before continuing."
    exit 1
  fi
fi

# ============================================================ PERMISSIONS =====
# Every writer on the data drive must agree about ownership, or Transmission's
# "delete with data" silently fails. See fix-permissions.sh for the full story;
# short version: the old box ran Transmission as uid 115, this one runs it as
# 1000, and a directory owned by a ghost uid cannot be written to.
if run perms; then
  say "Normalising ownership and modes on the data drive"
  "$STACK/scripts/fix-permissions.sh"
fi

# ================================================================ DOCKER =====
if run docker; then
  say "Installing Docker (official convenience script — arm64 native)"
  if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
  fi
  usermod -aG docker pi
  systemctl enable --now docker

  # Order Docker AFTER the data drive. Without this, a reboot can start the
  # containers before the USB disk is mounted: the data root exists as an empty
  # mountpoint, Plex bind-mounts *that*, and comes up with empty libraries.
  #
  # Ordering only (After=), deliberately not RequiresMountsFor=. If the disk ever
  # dies, a hard dependency would stop Docker entirely — which takes Pi-hole with
  # it and leaves the whole LAN without DNS. Media breaks; name resolution should
  # not. The mount is `nofail`, so boot proceeds either way.
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/10-wait-for-data-drive.conf <<EOF
[Unit]
After=$DATA_MOUNT_UNIT
EOF
  systemctl daemon-reload

  # Cap the journal and container logs; the SD card is the scarce resource here.
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker
fi

# ================================================================ NATIVE =====
# Things that touch hardware directly and gain nothing from a container.
if run native; then
  # Dropped from the old build at the owner's request (2026-08-23):
  #   shairport-sync — AirPlay target. No longer wanted.
  #   pigpiod        — GPIO daemon. Removed from Debian 13 anyway; nothing
  #                    observably used it. For GPIO later: apt install gpiod.
  # avahi stays: Samba needs it to advertise the share to Finder.
  say "Native services: avahi (mDNS for Samba), LED off"
  apt_install avahi-daemon
  systemctl enable --now avahi-daemon

  # Carried over from the old build: kills the power/activity LEDs.
  # NOTE: the sysfs names changed. Pi OS Bookworm/kernel 5.x exposed led0 (ACT)
  # and led1 (PWR); Trixie/kernel 6.x renamed them to ACT and PWR. Handle both,
  # and never fail the unit just because a name is absent on some model.
  cat > /usr/local/sbin/set-pi-leds <<'EOF'
#!/bin/sh
# usage: set-pi-leds <0|1>
val="$1"
for name in ACT PWR led0 led1; do
    p="/sys/class/leds/$name/brightness"
    [ -w "$p" ] || continue
    max="$(cat "/sys/class/leds/$name/max_brightness" 2>/dev/null || echo 1)"
    [ "$val" = "0" ] && echo 0 > "$p" || echo "$max" > "$p"
done
exit 0
EOF
  chmod +x /usr/local/sbin/set-pi-leds

  cat > /etc/systemd/system/disable-led.service <<'EOF'
[Unit]
Description=Disables the power-LED and active-LED
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/set-pi-leds 0
ExecStop=/usr/local/sbin/set-pi-leds 1

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl reset-failed disable-led.service 2>/dev/null || true
  systemctl enable --now disable-led.service
fi

# ============================================================== FIREWALL =====
# Deliberately NOT ufw. ufw filters in the `filter`/INPUT chain, but Docker
# DNATs published ports in `nat`/PREROUTING, which runs FIRST — so packets to
# 8082, 8083, 9091 and 3552 never reach a ufw rule. `ufw status` would read
# green while those ports stayed wide open. Filtering happens in our own
# nftables table, in both input AND forward, so containers are actually covered.
#
# The policy is "private sources may do anything, everything else is dropped".
# The LAN loses nothing; the win is that a mis-clicked port forward on the
# router no longer exposes a service whose password is `raspberry`.
if run firewall; then
  say "Host firewall (nftables)"
  apt_install nftables

  install -o root -g root -m 755 "$STACK/config/nftables.conf" /etc/nftables.conf

  # See the override file's header: the stock ExecStop flushes the ENTIRE
  # ruleset, Docker's rules included.
  mkdir -p /etc/systemd/system/nftables.service.d
  install -o root -g root -m 644 "$STACK/config/nftables-service-override.conf" \
          /etc/systemd/system/nftables.service.d/override.conf
  systemctl daemon-reload

  nft -c -f /etc/nftables.conf || warn "nftables.conf failed its syntax check — NOT enabling"
  if nft -c -f /etc/nftables.conf; then
    systemctl enable --now nftables
    say "  firewall active; LAN access unchanged, non-private sources dropped"
  fi
fi

# ================================================================= SAMBA =====
if run samba; then
  say "Samba share for $DATA_ROOT (replaces the empty FTP dir)"
  apt_install samba samba-common-bin

  if ! grep -q "^\[$DATA_SHARE_NAME\]" /etc/samba/smb.conf; then
    cat >> /etc/samba/smb.conf <<EOF

[$DATA_SHARE_NAME]
   path = $DATA_ROOT
   browseable = yes
   read only = no
   valid users = pi
   create mask = 0664
   directory mask = 0775
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:posix_rename = yes
EOF
  fi

  # `fruit` above is the macOS interop module — gives you correct Finder
  # behaviour and stops .DS_Store files from littering the share as real files.

  # Bind Samba itself only to loopback and the wired LAN. Loopback is needed by
  # smbpasswd. Samba accepts tailscale0 syntactically but does not bind smbd to
  # that non-broadcast interface; native Tailscale TCP forwarding below exposes
  # the loopback listener on the tailnet without reopening any other interface.
  sed -i -E 's|^[[:space:];#]*interfaces[[:space:]]*=.*|   interfaces = lo eth0|' /etc/samba/smb.conf
  sed -i -E 's|^[[:space:];#]*bind interfaces only[[:space:]]*=.*|   bind interfaces only = yes|' /etc/samba/smb.conf

  # No guest fallback and no ad-hoc user-created shares. The data share already has
  # valid users = pi, so authenticated access is unchanged.
  sed -i -E 's|^[[:space:];#]*map to guest[[:space:]]*=.*|   map to guest = never|' /etc/samba/smb.conf
  sed -i -E 's|^[[:space:];#]*usershare allow guests[[:space:]]*=.*|   usershare allow guests = no|' /etc/samba/smb.conf
  sed -i -E 's|^[[:space:];#]*usershare max shares[[:space:]]*=.*|   usershare max shares = 0|' /etc/samba/smb.conf

  # Debian's stock smb.conf ships active [homes], [printers] and [print$]
  # sections. This box is neither a home-directory server nor a print server;
  # The data share is the only one we want. Comment each entire section so a future
  # rebuild cannot silently expose ~/.ssh or advertise unused printer shares.
  for section in homes printers 'print$'; do
    start=$(awk -v header="[$section]" '$0 == header { print NR; exit }' /etc/samba/smb.conf)
    if [[ -n "$start" ]]; then
      end=$(awk -v s="$start" 'NR>s && /^\[/ {print NR-1; exit}' /etc/samba/smb.conf)
      [[ -n "$end" ]] || end=$(wc -l < /etc/samba/smb.conf)
      sed -i "${start},${end} s/^\([^#;]\)/;\1/" /etc/samba/smb.conf
      say "  disabled the stock [$section] share"
    fi
  done
  testparm -s >/dev/null 2>&1 || { warn "smb.conf is INVALID — refusing to restart Samba"; exit 1; }

  for unit in smbd nmbd; do
    install -d "/etc/systemd/system/${unit}.service.d"
    install -o root -g root -m 644 "$STACK/config/samba-tailscale-ordering.conf" \
            "/etc/systemd/system/${unit}.service.d/10-tailscale-ordering.conf"
  done
  systemctl daemon-reload

  printf '%s\n%s\n' "$SAMBA_PASSWORD" "$SAMBA_PASSWORD" | smbpasswd -s -a pi
  systemctl enable --now smbd nmbd
  systemctl restart smbd nmbd
  if systemctl is-active --quiet tailscaled; then
    tailscale serve --bg --tcp=445 tcp://127.0.0.1:445
    tailscale serve --bg --tcp=139 tcp://127.0.0.1:139
  else
    warn "tailscaled is inactive — SMB is LAN-only until Tailscale Serve is configured"
  fi
  say "Share available at smb://${LAN_IP}/${DATA_SHARE_NAME}"
fi

# =================================================================== DNS =====
if run dns; then
  say "Freeing port 53 for the Pi-hole container"
  # RPi OS Lite normally leaves :53 alone, but check rather than assume —
  # a silent conflict here means the container starts and the LAN loses DNS.
  if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
    warn "systemd-resolved is enabled; disabling its stub listener."
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/no-stub.conf
    systemctl restart systemd-resolved
  fi
  if ss -lnup 2>/dev/null | grep -q ':53 '; then
    warn "Something is STILL listening on UDP/53:"
    ss -lnup | grep ':53 ' || true
    warn "Resolve this before starting the stack."
  fi

  # Point the host itself at its own Pi-hole once it is up.
  if command -v nmcli >/dev/null; then
    nmcli con mod "Wired connection 1" ipv4.ignore-auto-dns yes ipv4.dns "127.0.0.1" 2>/dev/null || \
      warn "Could not set host DNS via nmcli — do it manually if needed."
  fi
fi

# ================================================================= STACK =====
if run stack; then
  say "Starting the container stack"
  # Arcane needs the HOST's docker GID to reach /var/run/docker.sock. It differs
  # between installs, so derive it rather than trusting the value in .env — a
  # stale GID gives a working UI that lists nothing, which is a confusing failure.
  HOST_DOCKER_GID="$(getent group docker | cut -d: -f3)"
  if [[ -n "$HOST_DOCKER_GID" ]]; then
    if grep -q '^DOCKER_GID=' "$STACK/.env"; then
      sed -i "s/^DOCKER_GID=.*/DOCKER_GID=$HOST_DOCKER_GID/" "$STACK/.env"
    else
      echo "DOCKER_GID=$HOST_DOCKER_GID" >> "$STACK/.env"
    fi
    export DOCKER_GID="$HOST_DOCKER_GID"
    say "Docker GID for Arcane: $HOST_DOCKER_GID"
  fi

  mkdir -p "$STACK"/appdata/{pihole/etc,plex,transmission,homebridge,filebrowser,arcane,microbin}
  mkdir -p "$STACK"/appdata/starbase80/icons
  mkdir -p "$STACK"/appdata/caddy/{data,config}

  # starbase80's icons are deliberately LOCAL rather than CDN-fetched, so the
  # dashboard renders with no internet and makes no outbound requests per load.
  # Nine files, ~270 KB, which also lands in the nightly appdata backup.
  # Missing icons are not fatal — you get a broken image, not a broken page —
  # so a download failure only warns.
  for _icon in pi-hole plex transmission filebrowser homebridge microbin arcane samba-server raspberry-pi; do
    _dest="$STACK/appdata/starbase80/icons/${_icon}.png"
    [[ -s "$_dest" ]] && continue
    curl -sfL -m 20 -o "$_dest" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/${_icon}.png" \
      || warn "  icon ${_icon}.png failed to download — dashboard will show a broken image"
  done

  # Render the dashboard config from its template. Done with sed rather than
  # envsubst so this needs no extra package, and the token list is explicit —
  # an unrecognised ${...} in the template stays visibly unsubstituted rather
  # than silently becoming an empty string.
  #
  # ⚠ Validate before writing. starbase80 runs a full Vite build at container
  # start, so malformed JSON does not degrade the page — it kills the container,
  # and the failure looks like a hung start rather than a config error.
  _sb_tmpl="$STACK/config/starbase80-config.json.tmpl"
  _sb_out="$STACK/appdata/starbase80/config.json"
  sed -e "s|\${LAN_IP}|$LAN_IP|g" \
      -e "s|\${CADDY_DOMAIN}|$CADDY_DOMAIN|g" \
      -e "s|\${DATA_SHARE_NAME}|$DATA_SHARE_NAME|g" \
      "$_sb_tmpl" > "${_sb_out}.new"
  if jq empty "${_sb_out}.new" 2>/dev/null; then
    mv "${_sb_out}.new" "$_sb_out"
    say "Dashboard config rendered from $(basename "$_sb_tmpl")"
  else
    rm -f "${_sb_out}.new"
    warn "starbase80 template did not render to valid JSON — keeping the previous config."
    warn "Check $_sb_tmpl with: jq empty $_sb_tmpl"
    [[ -s "$_sb_out" ]] || { warn "...and there is no previous config. starbase80 will not start."; }
  fi

  # Filebrowser (Quantum) reads config.yaml at every start from the same
  # directory that holds database.db. Refresh it from the repo copy so the file
  # in git stays authoritative; settings changed in the UI live in database.db
  # and are untouched by this.
  cp -a "$STACK/config/filebrowser-config.yaml" "$STACK/appdata/filebrowser/config.yaml"

  # Harmless for appdata/caddy: the official Caddy image runs as root, which
  # ignores ownership. Left in the sweep rather than special-cased so there is
  # one rule for this directory, not an exception to remember.
  chown -R 1000:1000 "$STACK/appdata"
  cd "$STACK"
  # --ignore-buildable skips Caddy, which has no upstream image to pull (it is
  # built from ./caddy). Without it, compose tries to pull pi-stack/caddy:<ver>
  # from Docker Hub, does not find it, and fails the whole phase.
  docker compose pull --ignore-buildable
  # ⚠ --build is what compiles Caddy with the DuckDNS plugin. On a fresh Pi 4
  # this is a Go build from a cold module cache: allow 3-5 minutes, during which
  # nothing appears to be happening.
  docker compose up -d --build
  say "Waiting for containers to settle"
  sleep 20
  docker compose ps

  # Filebrowser needs no password step any more. Quantum forces the admin
  # password to FILEBROWSER_ADMIN_PASSWORD at every start, and
  # docker-compose.yml passes that through from FILEBROWSER_PASSWORD in .env —
  # so .env is authoritative and this is idempotent by construction.
  #
  # The old one-off `docker run ... users update` container is gone with it, and
  # so is the bolt exclusive-lock trap that made it necessary.
  if [[ -z "${FILEBROWSER_PASSWORD:-}" ]]; then
    warn "FILEBROWSER_PASSWORD not set in .env — filebrowser will refuse to start."
  fi

  # Transmission is the opposite failure mode: it starts happily either way.
  # The image only enables rpc-authentication-required while USER and PASS are
  # both set, so an empty value here means the RPC comes up with NO password
  # and nothing complains.
  if [[ -z "${TRANSMISSION_PASSWORD:-}" ]]; then
    warn "TRANSMISSION_PASSWORD not set in .env — RPC will start with NO authentication."
  fi

  # Arcane's password is not provisionable: it enforces 12+ chars with upper,
  # lower, digit and symbol, and the CLI reset needs both a TTY and
  # ALLOW_CLI_PASSWORD_RESET=true. Set it by hand after first boot; see README.
fi

# ================================================================ BACKUP =====
if run backup; then
  say "Installing appdata backups (nightly core 03:30 x7, weekly full Sat 03:00 x1)"
  chmod +x "$STACK/scripts/backup-appdata.sh"

  # Two tiers, because a full snapshot is 2.4 GB and the data drive has ~18 GB
  # free. See the header of backup-appdata.sh for the reasoning.
  for tier in core full; do
    cat > "/etc/systemd/system/appdata-backup-${tier}.service" <<EOF
[Unit]
Description=Back up pi-stack appdata to the HDD (${tier})
Requires=$DATA_MOUNT_UNIT
After=$DATA_MOUNT_UNIT docker.service

[Service]
Type=oneshot
ExecStart=$STACK/scripts/backup-appdata.sh ${tier}
EOF
  done

  cat > /etc/systemd/system/appdata-backup-core.timer <<'EOF'
[Unit]
Description=Nightly pi-stack appdata backup (core)

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/appdata-backup-full.timer <<'EOF'
[Unit]
Description=Weekly pi-stack appdata backup (full, incl. Plex metadata)

[Timer]
# Saturday 03:00 — an hour before maintenance, so the snapshot you roll back to
# predates any package upgrade that goes wrong.
OnCalendar=Sat *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Supersedes the single-timer layout from earlier revisions of this script.
  systemctl disable --now appdata-backup.timer 2>/dev/null || true
  rm -f /etc/systemd/system/appdata-backup.timer /etc/systemd/system/appdata-backup.service

  systemctl daemon-reload
  systemctl enable --now appdata-backup-core.timer appdata-backup-full.timer
  systemctl list-timers 'appdata-backup-*' --no-pager || true
fi

# =========================================================== RESTORE TEST =====
if run backup; then
  say "Installing quarterly backup restore test"
  chmod +x "$STACK/scripts/restore-test.sh"

  cat > /etc/systemd/system/pi-restore-test.service <<EOF
[Unit]
Description=Extract and validate the newest pi-stack core backup
Requires=$DATA_MOUNT_UNIT
After=$DATA_MOUNT_UNIT appdata-backup-core.service

[Service]
Type=oneshot
TimeoutStartSec=1800
ExecStart=$STACK/scripts/restore-test.sh
EOF

  cat > /etc/systemd/system/pi-restore-test.timer <<'EOF'
[Unit]
Description=Quarterly pi-stack backup restore test

[Timer]
# First Sunday of Mar/Jun/Sep/Dec, away from update and fsck windows.
OnCalendar=Sun *-03,06,09,12-01..07 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pi-restore-test.timer
fi

# ============================================================ MAINTENANCE =====
if run maintenance; then
  say "Installing weekly maintenance (Sat 04:00) and reboot (Sat 05:00)"
  chmod +x "$STACK/scripts/maintenance.sh"

  cat > /etc/systemd/system/pi-maintenance.service <<EOF
[Unit]
Description=Weekly apt upgrade and cleanup
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
# Capped so a wedged apt cannot still be running when the 05:00 reboot lands.
TimeoutStartSec=3000
ExecStart=$STACK/scripts/maintenance.sh
EOF

  cat > /etc/systemd/system/pi-maintenance.timer <<'EOF'
[Unit]
Description=Weekly maintenance

[Timer]
OnCalendar=Sat *-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/pi-reboot.service <<'EOF'
[Unit]
Description=Weekly scheduled reboot
# Ordering only, not a dependency: if maintenance failed or never ran, the
# reboot should still happen. systemd's TimeoutStartSec on pi-maintenance
# guarantees it is finished by 04:50 regardless.
After=pi-maintenance.service

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF

  cat > /etc/systemd/system/pi-reboot.timer <<'EOF'
[Unit]
Description=Weekly reboot, one hour after maintenance starts

[Timer]
OnCalendar=Sat *-*-* 05:00:00
# NOT Persistent: a missed reboot must never fire on the next boot, or a Pi that
# was off over the weekend reboots itself the moment you power it back on.
Persistent=false

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pi-maintenance.timer pi-reboot.timer
  systemctl list-timers 'pi-*' --no-pager || true
fi

# ============================================================== QUARTERLY =====
if run quarterly; then
  say "Installing quarterly update (first Sat of Jan/Apr/Jul/Oct, 01:00)"
  chmod +x "$STACK/scripts/quarterly-update.sh"

  cat > /etc/systemd/system/pi-quarterly-update.service <<EOF
[Unit]
Description=Quarterly OS and container image update, with automatic rollback
Requires=$DATA_MOUNT_UNIT
After=$DATA_MOUNT_UNIT docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Backup + apt + five image pulls on a Pi. Must finish well before the 03:00
# backup and 04:00 maintenance slots.
TimeoutStartSec=5400
ExecStart=$STACK/scripts/quarterly-update.sh
EOF

  cat > /etc/systemd/system/pi-quarterly-update.timer <<'EOF'
[Unit]
Description=Quarterly update window

[Timer]
# First Saturday of Jan/Apr/Jul/Oct at 01:00 — ahead of that morning's backup
# (03:00), maintenance (04:00) and reboot (05:00), so a new kernel installed
# here is activated by the same morning's reboot.
OnCalendar=Sat *-01,04,07,10-01..07 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pi-quarterly-update.timer
  systemctl list-timers pi-quarterly-update.timer --no-pager || true
fi

# =============================================================== WATCHDOG =====
# The only measure here that survives the kernel itself locking up. Everything
# else in this file — restart policies, healthchecks, timers — needs a working
# scheduler to run. A wedged kernel has none, and the box sits dark until
# somebody pulls the plug. The BCM2835 has a hardware watchdog; use it.
if run watchdog; then
  say "Hardware watchdog"

  # Raspberry Pi OS ALREADY arms this. It ships
  #     /usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf
  #         RuntimeWatchdogSec=1m
  #         RebootWatchdogSec=2m
  # and drop-ins are merged in filename order across ALL directories, so a file
  # in /etc only wins if its name sorts LATER. An /etc/systemd/system.conf.d/
  # 10-*.conf is silently overridden by the vendor's 40-*.conf — it looks
  # applied, `cat` shows your values, and systemd uses theirs. Hence 50-.
  #
  # Their values are also fine (a 2 min reboot watchdog is stricter than the
  # 10 min systemd default), so on Pi OS this phase deliberately does nothing
  # but verify. The drop-in below is for a non-Pi-OS base where nobody armed it.
  if [[ ! -c /dev/watchdog ]]; then
    warn "No /dev/watchdog on this board — skipping."
  elif grep -rqiE '^[[:space:]]*RuntimeWatchdogSec' /usr/lib/systemd/system.conf.d/ 2>/dev/null; then
    say "Already armed by the OS vendor — leaving it alone:"
    grep -rhiE '^[[:space:]]*(Runtime|Reboot)WatchdogSec' /usr/lib/systemd/system.conf.d/ | sed 's/^/    /'
    rm -f /etc/systemd/system.conf.d/10-watchdog.conf   # from an earlier revision of this script
  else
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/50-watchdog.conf <<'EOF'
[Manager]
# PID 1 pets /dev/watchdog every RuntimeWatchdogSec/2. If PID 1 stops being
# scheduled at all, the hardware resets the board. The driver clamps this to
# its own granularity, so the value you set is a request, not a promise.
RuntimeWatchdogSec=30
# Armed across shutdown too: if a container refuses to stop and systemd stalls,
# the Saturday 05:00 reboot completes anyway instead of hanging until Monday.
RebootWatchdogSec=2min
EOF
    # Re-exec PID 1 so it picks this up now. Safe on a running system (systemd
    # serialises and restores its state) but it is the only thing in this file
    # that touches PID 1.
    systemctl daemon-reexec
  fi

  printf '    effective: %s, device %s, hw timeout %ss\n' \
    "$(systemctl show -p RuntimeWatchdogUSec --value) runtime / $(systemctl show -p RebootWatchdogUSec --value) reboot" \
    "$(cat /sys/class/watchdog/watchdog0/state 2>/dev/null || echo '?')" \
    "$(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null || echo '?')"
fi

# =================================================================== HEAL =====
if run heal; then
  say "Installing the container watchdog (every 5 min)"
  chmod +x "$STACK/scripts/container-watchdog.sh"
  mkdir -p /var/lib/pi-stack/watchdog

  cat > /etc/systemd/system/pi-container-watchdog.service <<EOF
[Unit]
Description=Restart pi-stack containers that are up but not answering
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
TimeoutStartSec=300
ExecStart=$STACK/scripts/container-watchdog.sh
EOF

  cat > /etc/systemd/system/pi-container-watchdog.timer <<'EOF'
[Unit]
Description=pi-stack container health watchdog

[Timer]
# 15 min after boot, then every 5. The delay keeps it from judging containers
# that are still inside their healthcheck start_period after a reboot.
OnBootSec=15min
OnUnitActiveSec=5min
# NOT Persistent: this is a "how are things right now" check. Replaying missed
# runs after downtime tells you nothing.
Persistent=false

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pi-container-watchdog.timer
fi

# =========================================================== BESZEL AGENT =====
if run beszelagent; then
  say "Installing native Beszel Agent with SMART access"
  apt_install smartmontools
  : "${BESZEL_KEY:?set BESZEL_KEY in $STACK/.env}"
  : "${BESZEL_TOKEN:?set BESZEL_TOKEN in $STACK/.env}"

  if ! id -u beszel >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/beszel-agent --shell /usr/sbin/nologin beszel
  fi
  usermod -aG docker,disk beszel

  # Keep the fingerprint in appdata so normal backups cover the native service
  # and the hub sees the same system after rebuild/migration.
  install -d -o beszel -g beszel -m 0750 "$STACK/appdata/beszel-agent"
  chown -R beszel:beszel "$STACK/appdata/beszel-agent"

  chmod +x "$STACK/scripts/install-beszel-agent.sh"
  "$STACK/scripts/install-beszel-agent.sh" "$(tr -d '[:space:]' < "$STACK/beszel-agent-version")"

  # Keep agent credentials out of the world-readable unit and out of the
  # process list. systemd reads this root-only file before dropping privileges.
  umask 077
  {
    printf 'KEY="%s"\n' "$BESZEL_KEY"
    printf 'TOKEN="%s"\n' "$BESZEL_TOKEN"
    printf '%s\n' \
      'HUB_URL="http://localhost:8086"' \
      'DISABLE_SSH="true"' \
      "DATA_DIR=\"$STACK/appdata/beszel-agent\"" \
      "EXTRA_FILESYSTEMS=\"$DATA_ROOT\"" \
      "SMART_DEVICES=\"${DATA_DEV%[0-9]}:sat\"" \
      'SMART_INTERVAL="1h"' \
      'LOG_LEVEL="info"'
  } > /etc/beszel-agent.env

  cat > /etc/systemd/system/beszel-agent.service <<EOF
[Unit]
Description=Beszel host metrics and SMART agent
Wants=network-online.target $DATA_MOUNT_UNIT
After=network-online.target $DATA_MOUNT_UNIT docker.service
Requires=docker.service

[Service]
Type=simple
User=beszel
Group=beszel
SupplementaryGroups=docker disk
EnvironmentFile=/etc/beszel-agent.env
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/beszel-agent/beszel-agent
Restart=on-failure
RestartSec=5
UMask=0027

# smartctl needs raw-I/O capability for SATA/SAT. SYS_ADMIN is retained because
# Beszel supports NVMe too, though this Pi currently has only /dev/sda.
AmbientCapabilities=CAP_SYS_RAWIO CAP_SYS_ADMIN
CapabilityBoundingSet=CAP_SYS_RAWIO CAP_SYS_ADMIN
DevicePolicy=closed
DeviceAllow=/dev/sda r
PrivateDevices=no

# Upstream's service hardening, with access retained for host/Docker metrics.
KeyringMode=private
LockPersonality=yes
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHome=read-only
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
ReadWritePaths=/opt/pi-stack/appdata/beszel-agent
RemoveIPC=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
SystemCallFilter=~@mount @module @obsolete @reboot @swap

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable beszel-agent.service

  # One-time migration from the old compose service. Its pinned image remains
  # on disk as a manual rollback target until normal Docker pruning reaches it.
  if docker inspect beszel-agent >/dev/null 2>&1; then
    docker stop beszel-agent >/dev/null
    docker rm beszel-agent >/dev/null
  fi
  systemctl restart beszel-agent.service
  systemctl is-active --quiet beszel-agent.service
fi

# ============================================================== DISKGUARD =====
if run diskguard; then
  say "Installing the daily disk guard"
  apt_install smartmontools
  chmod +x "$STACK/scripts/disk-guard.sh"

  cat > /etc/systemd/system/pi-disk-guard.service <<EOF
[Unit]
Description=Daily free-space and HDD SMART check
After=$DATA_MOUNT_UNIT
Wants=$DATA_MOUNT_UNIT

[Service]
Type=oneshot
TimeoutStartSec=300
ExecStart=$STACK/scripts/disk-guard.sh
EOF

  cat > /etc/systemd/system/pi-disk-guard.timer <<'EOF'
[Unit]
Description=Daily disk guard

[Timer]
# 08:00, after the night's backup, so a backup that filled the drive is caught
# the same morning rather than a day later.
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pi-disk-guard.timer

  # smartd is deliberately NOT enabled: it mails root, nothing reads that mail
  # on this box, and it would just be another daemon polling the disk.
  systemctl disable --now smartd 2>/dev/null || true
fi

# ==================================================================== FSCK =====
if run fsck; then
  say "Installing the 6-monthly data-drive check (Feb/Aug, first Sat 01:00)"
  chmod +x "$STACK/scripts/fsck-datadrive.sh"

  cat > /etc/systemd/system/pi-fsck-datadrive.service <<EOF
[Unit]
Description=Offline check and repair of $DATA_ROOT
After=$DATA_MOUNT_UNIT docker.service
Requires=docker.service

[Service]
Type=oneshot
# NO TIMEOUT, deliberately. systemd killing e2fsck part-way through a repair is
# one of the few ways to turn a fixable filesystem into a lost one. A full check
# of 45.8M inodes over USB can take a while and must be allowed to finish.
TimeoutStartSec=infinity
ExecStart=$STACK/scripts/fsck-datadrive.sh
EOF

  cat > /etc/systemd/system/pi-fsck-datadrive.timer <<'EOF'
[Unit]
Description=6-monthly data-drive check

[Timer]
# First Saturday of February and August at 01:00. Deliberately in months the
# quarterly update does NOT run (Jan/Apr/Jul/Oct), so the two never collide,
# and before that morning's 03:00 backup and 05:00 reboot.
OnCalendar=Sat *-02,08-01..07 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pi-fsck-datadrive.timer
fi

# =============================================================== SUMMARY =====
say "Provisioning complete"
printf '\n%-24s %s\n' "NATIVE SERVICE" "STATE"
for s in ssh docker avahi-daemon smbd nmbd; do
  # `systemctl is-active` prints "inactive" AND exits non-zero, so a naive
  # `|| echo not-found` prints both. Capture first, default only if empty.
  state="$(systemctl is-active "$s" 2>/dev/null)" || true
  printf '%-24s %s\n' "$s" "${state:-not-found}"
done
echo
docker compose -f "$STACK/docker-compose.yml" ps 2>/dev/null || true

cat <<EOF

================================================================
  Endpoints — start at the dashboard, it links to everything else.

    Dashboard     https://home.$CADDY_DOMAIN/
    Pi-hole       https://pihole.$CADDY_DOMAIN/
    Transmission  https://torrents.$CADDY_DOMAIN/
    Homebridge    https://homebridge.$CADDY_DOMAIN/
    Filebrowser   https://files.$CADDY_DOMAIN/
    Arcane        https://docker.$CADDY_DOMAIN/
    MicroBin      https://paste.$CADDY_DOMAIN/
    Plex          http://$LAN_IP:32400/web    (deliberately unproxied)
    Samba         smb://$LAN_IP/$DATA_SHARE_NAME

  Fallbacks, for when Caddy or DuckDNS is broken:
    :8084 dashboard  :8080 pi-hole  :9091 transmission  :8581 homebridge
    :8082 files      :3552 arcane   :8083 paste

  Verify before you walk away:
    1. DNS works from another device on the LAN.
    2. A REAL certificate is being served, not Caddy's internal CA fallback:
         echo | openssl s_client -connect 127.0.0.1:443 \\
           -servername home.$CADDY_DOMAIN 2>/dev/null \\
           | openssl x509 -noout -issuer
       Issuer must say Let's Encrypt.
    3. Homebridge accessories are all online in the Home app.
    4. Plex libraries resolve under $DATA_ROOT (watch state intact).
    5. sudo systemctl start appdata-backup-core.service   # test the backup once

  Nothing here notifies you. This is the whole alerting system:

      systemctl --failed            <-- CHECK THIS OCCASIONALLY
      systemctl list-timers 'pi-*' 'appdata-*'
      systemctl status pi-disk-guard pi-container-watchdog

  A failed backup, a triggered rollback or a dying disk shows up in the first
  command and nowhere else.
================================================================
EOF
