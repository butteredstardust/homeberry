# homeberry — operations

Use this runbook for `raspberrypi` at **<LAN_IP>**. [README.md](../README.md) contains the build procedure. This runbook assumes the stack runs.

**Broken right now?** → [Recovery](#2-recovery).

⚠ **This Pi is the LAN DNS server.** Pi-hole downtime stops DNS for every user. Before planned downtime, set the router DNS to `1.1.1.1`.

---

## 1. This machine

| | |
|---|---|
| Host | `raspberrypi`, Pi 4B 4 GB, Raspberry Pi OS Lite 64-bit (Debian 13 Trixie) |
| Address | <LAN_IP> — **DHCP reservation on the router**, not configured on the Pi |
| SSH | `ssh pi`, ed25519 key only; password auth disabled |
| Stack root | `/opt/pi-stack` |
| Data drive | `DATA_ROOT` from `.env` — ext4, mounted by UUID (see `.env` → `DATA_DRIVE_UUID`) |
| Secrets | `/opt/pi-stack/.env`, mode 600, root-owned, gitignored |
| Docker GID | 985 (host-specific; `provision.sh` re-derives it) |

Record a baseline after the build. Update it when the values change. A healthy value needs a known baseline. Example: `/` 11% used, `$DATA_ROOT` 91% (65 GB free), RAM 2.9 GB available, and `systemctl --failed` empty.

### 1.1 Endpoints

All endpoints are LAN-only and behind the firewall. **None is forwarded.** [Decisions: TLS is not authorisation](DECISIONS.md#tls-is-not-authorisation--never-forward-these-ports) explains why none may be forwarded.

Every web UI has an HTTPS name. See [HTTPS](services/https.md). Use `Fallback` only when Caddy or DuckDNS is broken. Read the note below before you use one from another host.

Services use the `pi` username and a password from `.env`. Two table entries are exceptions. The shared password is valid only for this LAN-only stack.

⚠ **Do not record passwords in this file.** `.env` stores them. It is mode 600 and gitignored. This table names variables, not values.

| Service | HTTPS name (`*.${CADDY_DOMAIN}`) | Fallback | User | Password |
|---|---|---|---|---|
| **Dashboard** | **`home.`** — the front door, links to everything below | `:8084` | none | none |
| Authelia | `auth.` — login and TOTP enrolment portal | `:8087` → container `:9091` | `pi` | `.env` → `AUTHELIA_PASSWORD` |
| Pi-hole | `pihole.` → `/admin` | `:8080/admin` | **none — v6 has no username field** | `.env` → `PIHOLE_PASSWORD` |
| Plex | **not proxied, on purpose** | `:32400/web` | plex.tv account | not on this box |
| Transmission | `torrents.` | `:9091` | `pi` | `.env` → `TRANSMISSION_PASSWORD` |
| Homebridge | `homebridge.` | `:8581` | `pi` | PBKDF2 in `appdata/homebridge/auth.json`, **not** in `.env` |
| Filebrowser | `files.` | `:8082` | `pi` | `.env` → `FILEBROWSER_PASSWORD` |
| Arcane | `docker.` | `:3552` | `arcane` | **exception** — 12+ chars, mixed case, digit and symbol, or Arcane refuses it · `.env` → `ARCANE_PASSWORD` |
| MicroBin | `paste.` | `:8083` | `pi` | `.env` → `MICROBIN_PASSWORD` |
| Samba | n/a — not HTTP | `smb://<LAN_IP>/<share>` | `pi` | `.env` → `SAMBA_PASSWORD` |
| SSH | n/a | `:22` | `pi` | key only, password auth disabled |

⚠ **The Fallback column is a loopback port, not a LAN address.** `BIND_ADDR` defaults to `127.0.0.1`. It publishes container UIs only on host loopback. `http://<LAN_IP>:8082` is refused from another host. This keeps Caddy as the entry point and enforces `ADMIN_SOURCES`.

When Caddy or TLS is broken, tunnel a fallback:

```bash
ssh -N -L 8082:127.0.0.1:8082 pi@<LAN_IP>    # then http://127.0.0.1:8082
```

Four fallbacks use `network_mode: host` and are not loopback-bound: `:8080` (Pi-hole), `:8581` (Homebridge), `:32400` (Plex), and Samba. nftables restricts the first two to `ADMIN_SOURCES`. See [Firewall](#6-firewall).

**Plex is deliberately unproxied.** It ships its own `*.plex.direct` certificate
and its clients connect straight to `:32400`; a proxy in front tends to break
direct-play and remote-access detection rather than help.

**Ports 80 and 443 belong to Caddy.** Pi-hole was moved off `:443` (it served a
self-signed block page there that nothing ever reached, because blocked domains
resolve to `0.0.0.0`, not to this Pi) and the dashboard off `:80` to `:8084`.

**Arcane is the password exception.** It enforces 12+ characters with upper,
lower, digit and symbol, and rejects a weak password outright — the CLI errors,
it is not a warning. That login is effectively root on the host ([Arcane](services/apps.md#arcane)). Its generated
password is in `.env` → `ARCANE_PASSWORD`, which is **not** consumed by
`docker-compose.yml`; it is stored there so the secret lives with the others.

**Start at the dashboard.** `https://home.${CADDY_DOMAIN}/` is the one to
bookmark. `http://<LAN_IP>/`, `http://<hostname>.local/` and
`http://home.internal/` all still work and reach it *through* Caddy.

Other listening ports: `53` (DNS), `139`/`445` (Samba), `51413` (Transmission
peer), `32410`–`32414` (Plex DLNA), Homebridge HAP (ephemeral).
Authoritative list: `sudo ss -lntp`.

Homebridge uses `bonjour-hap` while the host Avahi daemon provides the machine's
normal `.local` presence. `ENABLE_AVAHI=0` prevents the host-networked container
from starting another Avahi daemon on the same UDP socket. Do not remove it to
troubleshoot discovery; doing so restores the duplicate mDNS-stack warning.

### 1.2 Reading the passwords

`.env` is mode 600 and root-owned. Use `sudo`. These commands print seven password variables: Pi-hole, Samba, Filebrowser, Transmission, Arcane, MicroBin, and Authelia.

```bash
sudo grep -E '_PASSWORD=' /opt/pi-stack/.env               # on the Pi
ssh pi "sudo grep -E '_PASSWORD=' /opt/pi-stack/.env"      # remotely
sudo grep '^ARCANE_PASSWORD=' /opt/pi-stack/.env           # one service
```

Homebridge does not store a readable password here. `auth.json` contains a PBKDF2 hash. Reset it when needed.

⚠ **Do not paste this output into MicroBin**, chat, or an issue tracker. See [MicroBin](services/apps.md#microbin).

Use this command to read service secrets that are not logins:

```bash
sudo grep -E 'ARCANE_(ENCRYPTION|JWT)|DUCKDNS' /opt/pi-stack/.env
```

`DUCKDNS_TOKEN` can edit DNS for this subdomain only. If it leaks, rotate it at duckdns.org. Then run `docker compose up -d caddy`.

### 1.3 Password resets

**Filebrowser.** Edit `.env`. Restart the service. The environment applies the value at each start.

```bash
sudo vim /opt/pi-stack/.env          # FILEBROWSER_PASSWORD=
cd /opt/pi-stack && sudo docker compose up -d filebrowser
```

Changing the *username* creates an additional admin. It does not rename the account. Remove `appdata/filebrowser/database.db`. Restart Filebrowser to create one account.

**Pi-hole.** Change `PIHOLE_PASSWORD`. Run `docker compose up -d pihole`. Version 6 uses a password-only form.

**Transmission.** ⚠ **Do not edit `settings.json`.** The linuxserver image sets `rpc-authentication-required` at each start. It sets `true` when `USER` and `PASS` exist. It otherwise sets `false`. Credentials are in `docker-compose.yml`.

```bash
sudo vim /opt/pi-stack/.env          # TRANSMISSION_PASSWORD=
cd /opt/pi-stack && sudo docker compose up -d transmission
sudo grep rpc-authentication-required appdata/transmission/settings.json   # true
```

RPC had **no authentication at all** until 2026-08-25. Both `quarterly-update.sh`
and the compose healthcheck accept `401`, so enabling it does not mark the
container unhealthy.

**Homebridge** — no env var; the hash is in `auth.json`. Reset by deleting it —
the UI returns to `admin`/`admin`:

```bash
cd /opt/pi-stack
sudo cp appdata/homebridge/auth.json /tmp/auth.json.bak
sudo rm appdata/homebridge/auth.json && sudo docker restart homebridge
```

To set a known password without losing the account, recompute the hash with the
app's own parameters — PBKDF2-HMAC-SHA512, 210000 iterations, 64 bytes, and the
**existing salt used as an ASCII string, not decoded from hex**:

```bash
docker exec homebridge node -e 'require("crypto").pbkdf2("NEWPASS","<salt from auth.json>",210000,64,"sha512",(e,k)=>console.log(k.toString("hex")))'
```

**Arcane** — CLI reset is gated behind an env var not set in compose, and needs a
real TTY. Pass `-e` to `docker exec`; over SSH, wrap in `script` to get a pty:

```bash
sudo docker exec -it -e ALLOW_CLI_PASSWORD_RESET=true arcane \
  ./arcane admin reset-password --username pi
```

Policy enforced here: 12+ chars, upper, lower, digit, symbol. Do **not** rotate
`ARCANE_ENCRYPTION_KEY` to fix a login — it decrypts stored registry credentials.

**Samba** — independent of Docker; `.env` only records it:

```bash
sudo smbpasswd -a pi && sudo systemctl reload smbd
```

Changing it breaks saved credentials on any device with the share mounted.

`[rpidata]` is the only share. Debian's stock `[homes]`, which auto-exported
`/home/pi` (read-only, `valid users = %S`) to anyone who could authenticate as
`pi`, was commented out 2026-08-25 and `provision.sh` now disables it on a
rebuild. It exposed `~/.ssh/authorized_keys` and `~/.bash_history`; no private
keys were ever in there. Backup at `/etc/samba/smb.conf.bak-2026-08-25`.

The unused stock `[printers]` and `[print$]` sections are disabled as well; this
Pi does not run CUPS. `[rpidata]` is therefore the only active Samba share.

Guest fallback and usershares are disabled. Samba binds only to loopback and
`eth0`; Samba cannot bind reliably to Tailscale's non-broadcast interface, so
Tailscale Serve provides tailnet-only raw TCP forwarding for ports 139/445 to
the loopback listeners. This is **Serve, not Funnel**—it is still governed by
`tailscale-policy.hujson` and is not public.

```bash
sudo testparm -s | grep -E 'interfaces|map to guest|usershare'
sudo tailscale serve status
sudo ss -lntp | grep -E ':(139|445) '
```

---

## 2. Recovery

### 2.1 Triage

Use these checks before you restart a service. Run them on the host.

```bash
systemctl --failed                                  # the entire alerting system
docker compose -f /opt/pi-stack/docker-compose.yml ps
df -h / /mnt/rpidata
journalctl -u pi-container-watchdog -n 50
sudo systemctl start pi-disk-guard.service && systemctl status pi-disk-guard
```

### 2.2 Container down or unhealthy

Check the container log before you restart the container. Run these commands on the host.

```bash
cd /opt/pi-stack
docker logs --tail 100 <name>
docker compose up -d <name>      # recreate from compose
docker restart <name>            # just bounce it
```

`container-watchdog.sh` restarts an unhealthy container for ~10 min. It restarts each container at most **3 times per 24 h**. If it stops, read the journal before you restart the container.

### 2.3 Restore appdata

⚠ **This procedure overwrites current appdata.** Confirm that the selected archive is the required restore point before you run `docker compose down`.

Use this as the main appdata recovery path. Snapshots are in `/mnt/rpidata/backup/appdata/`. The workstation mirror is `~/pi-backups/`. `mac/pull-backups.sh` sets that location. Each tarball root contains `.env` and `appdata/`. Archives use mode `0600`. They contain service credentials and private keys.

```bash
cd /opt/pi-stack
ls -lht /mnt/rpidata/backup/appdata/
docker compose down
sudo systemctl stop beszel-agent
sudo mv appdata appdata.broken                      # keep it, don't delete
sudo cp -a .env .env.before-restore                 # current site config rollback
sudo tar --same-owner -xzf /mnt/rpidata/backup/appdata/appdata-core-YYYYMMDD-HHMM.tar.gz -C /opt/pi-stack
sudo chown -R beszel:beszel appdata/beszel-agent
# The archive holds appdata as it was, so a snapshot older than an artwork change
# restores an icons/ directory without the current dashboard logo. Nothing else in
# this procedure runs provision.sh, and the healthcheck only proves nginx answers —
# a missing logo restores "healthy" and looks fine until you open the page.
sudo cp -f assets/homeberry-256.png appdata/starbase80/icons/homeberry.png
docker compose up -d
sudo systemctl start beszel-agent
```

Restore one service with `sudo tar -xzf <snap>.tar.gz -C /opt/pi-stack appdata/homebridge`.

**`core` vs `full`:** `core` (nightly, ~70 MB, keep 7) holds everything
irreplaceable — Plex library DB and watch state, HomeKit pairings, Authelia's
TOTP enrolments, torrent resume data, Pi-hole config, Caddy's certificates, and
`.env` (credentials, drive
identity, firewall sources and the private `PIHOLE_EXTRA_HOSTS` inventory).
`full` (Sat 03:00, ~2.4 GB, keep 1) adds Plex's `Metadata/` artwork, which Plex
re-downloads by itself. **Restoring `core` loses nothing permanent.**

`pi-restore-test.timer` independently proves this every quarter: it extracts
the newest core archive under `/var/tmp`, checks load-bearing paths and Beszel
ownership, and opens every staged SQLite database. Run it on demand with
`sudo systemctl start pi-restore-test.service`.

Pi unreachable? Same tarballs on the Mac:
`scp ~/pi-backups/appdata-core-*.tar.gz pi:/tmp/`

### 2.4 SD card died — full rebuild

The HDD and its backups survive. Only the OS is lost. Follow [Build](../README.md#4-build) for steps 1–5. Restore appdata before you start an empty stack.

```bash
sudo systemctl stop beszel-agent
sudo tar --same-owner -xzf /mnt/rpidata/backup/appdata/appdata-full-*.tar.gz -C /opt/pi-stack
sudo chown -R beszel:beszel appdata/beszel-agent
docker compose up -d --build
sudo systemctl start beszel-agent
```

Plex keeps its claim and libraries as long as `appdata/plex` is restored. **Do
not re-claim the server** — that is what loses watch state.

Restoring `appdata/caddy` also restores the certificates and ACME account key, so
the rebuild does not need fresh ACME orders. Losing it is survivable — Caddy
re-issues — but costs a fresh set against the rate limit.

### 2.5 Data drive won't mount

```bash
lsblk -f && blkid /dev/sda1
sudo mount -a
sudo dmesg | grep -iE 'sda|EXT4-fs|I/O error'
sudo systemctl start pi-fsck-datadrive.service --no-block
sudo tail -f /var/log/pi-fsck.log
```

`/mnt/rpidata` is `nofail`. The host boots without it. DNS keeps working. Plex and Transmission start with empty media.

Docker is ordered `After=mnt-rpidata.mount`
(`/etc/systemd/system/docker.service.d/10-wait-for-data-drive.conf`). Ordering
**only** — deliberately not `RequiresMountsFor=`, which would stop Docker
entirely if the disk died and take LAN DNS with it.

Drive replaced? The new UUID goes in `.env` (`DATA_DRIVE_UUID`) and `/etc/fstab`
— blank it in `.env` and re-run `sudo bash provision.sh drive` to have it
re-detected from `DATA_DEV` and written back.

### 2.6 Bad update

`quarterly-update.sh` rolls back after a failed health check. Use these commands for a manual rollback.

```bash
cd /opt/pi-stack
cp .docker-compose.prev.yml docker-compose.yml
docker compose up -d --build
cat /mnt/rpidata/backup/quarterly-update.log
```

Old images are still on disk — `maintenance.sh` prunes only *dangling* images,
never `image prune -a`, precisely so the rollback target survives.

### 2.7 DNS down

⚠ **Pi-hole downtime stops LAN DNS for the house.** Set the router DNS to `1.1.1.1` before extended Pi-hole work.

```bash
docker logs --tail 50 pihole
docker exec pihole dig +short @127.0.0.1 pi.hole
sudo ss -lnup | grep ':53 '        # something else on the port?
docker compose up -d pihole
```

Set the router's DNS to `1.1.1.1` immediately.

### 2.8 HTTPS broken

Nothing is lost. `:8080` (Pi-hole) and `:8581` (Homebridge) answer directly on `<LAN_IP>`. `BIND_ADDR` binds container UIs to loopback. Use SSH to reach `:8084`, `:8082`, `:8083`, `:9091`, `:3552`, `:8085`, and `:8086`.

```bash
ssh -N -L 8084:127.0.0.1:8084 -L 8082:127.0.0.1:8082 -L 8083:127.0.0.1:8083 \
       -L 9091:127.0.0.1:9091 -L 3552:127.0.0.1:3552 -L 8085:127.0.0.1:8085 \
       -L 8086:127.0.0.1:8086 -L 8087:127.0.0.1:8087 pi@<LAN_IP>
```

`http://<LAN_IP>/` still reaches the dashboard. Caddy serves that HTTP site block without a certificate. Diagnose with [HTTPS](services/https.md).

If SSH is refused, check `ADMIN_SOURCES` first. You may use the wrong machine. See [Firewall](#6-firewall).

---

## 3. Schedule

| When | Unit | What |
|---|---|---|
| every 5 min | `pi-container-watchdog.timer` | restart containers up but not answering |
| daily 03:30 | `appdata-backup-core.timer` | ~70 MB verified snapshot, keep 7 |
| daily 06:30 (**workstation**) | `com.example.pi-backup-pull` | pull that snapshot off the Pi, keep 14 |
| daily 08:00 | `pi-disk-guard.timer` | free space, SMART, power/thermal, zram, TLS and Tailscale route/lock/key expiry |
| Sat 03:00 | `appdata-backup-full.timer` | ~2.4 GB snapshot incl. Plex artwork, keep 1 |
| Sat 04:00 | `pi-maintenance.timer` | apt upgrade, autoremove, clean, prune dangling, vacuum journal 14d |
| Sat 05:00 | `pi-reboot.timer` | the one scheduled reboot |
| 1st Sat Jan/Apr/Jul/Oct 01:00 | `pi-quarterly-update.timer` | `apt full-upgrade` + re-pin images, with rollback |
| 1st Sat Feb/Aug 01:00 | `pi-fsck-datadrive.timer` | offline `e2fsck` of `/mnt/rpidata`, repairs included |
| 1st Sun Mar/Jun/Sep/Dec 02:00 | `pi-restore-test.timer` | extract newest core backup and validate restore paths/databases |

`systemctl list-timers 'pi-*' 'appdata-*'`

Saturday jobs are staggered. They do not overlap. Backups run **before** the upgrade. The rollback snapshot therefore predates a bad package. Quarterly and six-month jobs use different months.

Steady-state backups use ~2.9 GB on the Pi and ~1 GB on the Mac.

Keep these settings:

- `pi-reboot.timer` is **not** `Persistent=true`. A missed reboot must not fire
  on next boot, or a Pi that was off over the weekend reboots itself on power-on.
- `pi-maintenance.service` has `TimeoutStartSec=3000`, so a wedged apt is killed
  at 04:50 and cannot still hold dpkg locks when the reboot lands.

---

## 4. Monitoring

**Nothing notifies you.** Use these commands as the alerting system:

```bash
systemctl --failed                          # <-- the one that matters
systemctl status pi-disk-guard              # disk, SMART, power/thermal, zram, TLS
journalctl -u pi-container-watchdog -n 50
sudo tail /var/log/pi-fsck.log
cat /mnt/rpidata/backup/quarterly-update.log
tail ~/Library/Logs/pi-backup-pull.log      # on the Mac
```

`disk-guard.sh` exits non-zero when it finds a problem. The failure appears in `systemctl --failed`. The data-drive threshold is 95%. The certificate warning is 21 days.

journald uses `Storage=volatile`. **Logs do not survive a reboot.** Diagnose before the Saturday 05:00 restart.

Three browser views provide additional state:

| | Where | What it adds |
|---|---|---|
| Dozzle | `https://logs.${CADDY_DOMAIN}` | all twelve containers' logs at once, searchable |
| Beszel | `https://metrics.${CADDY_DOMAIN}` | CPU/mem/disk/net **history**, which nothing else here keeps |
| Diun | its own log, read via Dozzle | daily "a newer image was published" |

Diun is the only automatic image-update monitor. `provision.sh arcane` sets
Arcane's **Environment → Jobs → Enable Polling** setting off after the first
stack start, avoiding duplicate hourly Docker Distribution lookups and their
transient registry timeouts; its manual image check still works. The setting
lives in `appdata/arcane/arcane.db`, so it survives container recreation and is
included in the normal appdata backups. The `services` stage runs this phase;
on an older deployment, run it once explicitly.

The phase waits up to three minutes for Arcane to seed that database, because on
a first provision the file appears before the table and the table before the row.
If it is still unreadable it warns in the end-of-run summary and leaves polling
on rather than aborting the remaining phases — duplicate registry lookups are
wasteful, not dangerous. Re-run `sudo bash provision.sh arcane` once the stack is
healthy and confirm with:

```bash
sudo sqlite3 /opt/pi-stack/appdata/arcane/arcane.db \
  "SELECT value FROM settings WHERE key='pollingEnabled';"   # expect: false
```

⚠ **These views do not notify you.** They report only when someone opens them. Beszel alerts are not configured. Diun notifiers are off. `systemctl --failed` remains the alerting system. See [Observability](services/observability.md).

---

## 5. Self-healing

| Layer | Covers | Does not cover |
|---|---|---|
| `restart: unless-stopped` | a process that **exits** | a process that hangs |
| healthchecks + `container-watchdog.sh` | container **up but not answering** | a host that stops scheduling |
| hardware watchdog (BCM2835) | **kernel hang** — resets the board | dead SD card or disk |
| backups + Mac copy | **data loss** | everything above, faster |

A container stopped **by hand** remains down after reboot. This is the meaning of `unless-stopped`. `backup-appdata.sh` and `fsck-datadrive.sh` restart services from a `trap`.

`container-watchdog.sh` waits for 2 unhealthy checks (~10 min). It restarts a container at most **3 times per container per 24 h**. It does not touch a stopped container. It uses the backup `flock`. After its limit, it requires a human. A Pi-hole restart loop causes repeated DNS outages.

The hardware watchdog needs **no configuration**. Pi OS provides `/usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf`. Verify the active value, not the file.

```bash
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
cat /sys/class/watchdog/watchdog0/state    # -> active
```

systemd merges `system.conf.d` drop-ins by **filename order across all
directories**, so a `10-*.conf` in `/etc` is silently overridden by the vendor's
`40-*.conf` — `cat` shows your values while systemd uses theirs. Note the
**`USec`** suffix above; `RuntimeWatchdogSec` is not queryable and returns
nothing.

### 5.1 Filesystem checks

Debian ships ext4 with `Maximum mount count: -1` and `Check interval: 0`, so
**nothing checks the data drive on its own**. `fsck-datadrive.sh` replaces that,
on a schedule instead of at a surprise boot:

```bash
sudo systemctl start pi-fsck-datadrive.service --no-block
sudo tail -f /var/log/pi-fsck.log
```

It stops Plex, Transmission and Samba, unmounts, runs `e2fsck -fp`, escalates to
`-fy` only on exit code 4, remounts and restarts everything via a trap. Pi-hole
and Homebridge stay up — **no DNS outage**. A full check takes tens of seconds on a ~700 GB spinning disk:
but only ~13,500 files, and `metadata_csum` lets e2fsck skip never-used
inode-table blocks. `18.8% non-contiguous` is torrent fragmentation, not damage.

Three properties not to break:

- **Never** lazy-unmounts; verifies the unmount twice by different methods before
  invoking e2fsck. e2fsck on a mounted rw filesystem destroys it.
- Unit has `TimeoutStartSec=infinity`. systemd killing e2fsck mid-repair can turn
  a fixable filesystem into a lost one.
- Must stop `smbd`/`nmbd`. smbd holds its cwd inside the share while any client
  is connected, so `umount` fails with `target is busy` even after the containers
  stop.

`tune2fs -c` periodic checks are deliberately **not** enabled — that fires an
unattended fsck at an unpredictable boot, including the Saturday 05:00 reboot.

---

## 6. Firewall

The firewall uses nftables. It has its own `inet lanfw` table.

| | |
|---|---|
| Engine | nftables, own table `inet lanfw` |
| Rules | `nftables.conf` in this repo → `/etc/nftables.conf` |
| Unit | `nftables.service`, enabled, plus a drop-in override |
| Policy | input `drop`, forward `accept` with an explicit drop, output `accept` |
| Tier 1 allowed | all of RFC1918, link-local, loopback, ICMP/ICMPv6, DHCP replies, `tailscale0` |
| Tier 1 dropped | everything else — i.e. any public source address |
| Tier 2 | `$admin_ports` (`22`, `8080`, `8581`) restricted to `$admin_sources` |
| `$admin_sources` | generated from `ADMIN_SOURCES` in `.env` by `provision.sh firewall` |
| Caddy host path | `$CADDY_HOST_IP` may reach only host ports `8080` and `8581` |

**Tier 1.** LAN services remain available to the house. Tier 1 drops non-private sources. It protects services if a router port forward exists by mistake. It is a backstop. See [Decisions: TLS is not authorisation](DECISIONS.md#tls-is-not-authorisation--never-forward-these-ports).

**Tier 2.** Tier 2 restricts SSH, the Pi-hole admin panel, and Homebridge to `ADMIN_SOURCES`. A private source outside that value cannot reach them. The shipped value is all of RFC1918. It matches Tier 1 until you narrow it. This prevents an initial build from locking out its owner.

```bash
# in .env
ADMIN_SOURCES="192.168.0.50/32"        # your workstation, as a DHCP reservation
```

Read the deadman-switch procedure below before you run the phase.

```bash
sudo bash provision.sh firewall
```

`provision.sh` arms `fw-deadman` when `ADMIN_SOURCES` differs from the default. Stop the timer only after you verify access from a **new** session.

Caddy reaches host-networked Pi-hole and Homebridge through `caddy_host`. `.env` provides `CADDY_HOST_SUBNET`, `CADDY_HOST_GATEWAY`, and `CADDY_HOST_IP`. Compose and nftables use these values. `provision.sh stack` checks the values. It rejects overlap with a Docker network. It refuses a different address in `/etc/nftables.conf`. Only the Caddy IP reaches `8080` and `8581` before Tier 2. Do not broaden this to a subnet. Other containers could bypass the workstation-only rule.

**Tier 2 ends at layer 4.** The firewall cannot distinguish web names behind Caddy on `:443`. The `Caddyfile` `(adminonly)` snippet applies the per-vhost rule. It covers `pihole` `files` `torrents` `docker` `homebridge` `logs` and `metrics`. It uses the same `ADMIN_SOURCES` value. Caddy substitutes this value during parsing. Restart Caddy after a change.

```bash
docker compose up -d --force-recreate caddy
```

The dashboard (`home.`) and pastebin (`paste.`) remain open by design.

**The tailnet is always admin.** nftables accepts `tailscale0` before Tier 2. A tailnet peer uses `100.64.0.0/10`. That source is not in `ADMIN_SOURCES`. Changing rule order stops remote SSH. Caddy cannot match an interface. It allows `100.64.0.0/10`. Tier 1 drops non-private traffic that does not arrive on `tailscale0`. Join a tailnet before you narrow the firewall.

⚠ **This is a reachability tier, not authentication.** Every service keeps its
own login. Do not remove one because this exists.

**Why not ufw.** ufw filters in `filter`/INPUT. Docker DNATs published ports in `nat`/PREROUTING first. Packets for 8082, 8083, 9091, and 3552 do not reach ufw. The firewall uses a `forward` chain as well as `input`.

**Three traps, all handled — do not undo them:**

- **Never put `flush ruleset` in `/etc/nftables.conf`.** The stock Debian file
  does. Docker's DNAT and filter rules live in the same kernel ruleset via
  iptables-nft, so a flush deletes every published port, and only a Docker daemon
  restart brings them back. The file uses `destroy table inet lanfw`.
- **The stock `ExecStop` is `nft flush ruleset`** — same damage, triggered by a
  plain `systemctl restart nftables`. `nftables-service-override.conf` replaces
  it with a targeted `destroy`. The empty `ExecStop=` line in that file is
  load-bearing: systemd appends to list directives, so without it the stock flush
  still runs.
- **No rule matches on an interface name**, with the single deliberate exception
  of `tailscale0` above. `wlan0` exists but is down with no connection profile;
  the box must survive a move to wifi. The Docker bridge name
  (`br-fe956b41828c`) is derived from the compose project name and changes if
  that is renamed. Matching on source address avoids both.
- **`define admin_sources` in `/etc/nftables.conf` is generated.** `provision.sh
  firewall` rewrites that line from `.env` on every run, so editing it in place
  survives until the next provision and then silently reverts — and worse,
  leaves the Caddyfile's copy of the allowlist disagreeing with it. Edit `.env`.

Caddy on `:443` needed no rule change — RFC1918 is already accepted wholesale,
which is exactly why the vhost-level allowlist has to live in the Caddyfile.

Inbound BitTorrent peers on 51413 are dropped by the forward chain. CGNAT prevents forwarded peers. If that changes, add the accept in the `forward` chain only.

⚠ **Verify from another machine on a new connection.** A check from the current session cannot prove that a new connection will work. There is no serial console. A lockout requires HDMI and a keyboard. Arm the dead man's switch before you change rules.

```bash
sudo systemd-run --on-active=600 --unit=fw-deadman /usr/sbin/nft destroy table inet lanfw
sudo nft -c -f /etc/nftables.conf     # syntax check, no apply
sudo nft -f /etc/nftables.conf
# verify from ANOTHER machine, on a NEW connection, before you trust it
sudo systemctl stop fw-deadman.timer  # only once you are sure
```

**The input drop counter can increase without an attack.** The ISP router queries Pi-hole from a rotating `100.64.0.0/10` address. Verified traffic in `pihole-FTL.db` was 100% reverse-DNS and `_dns-sd._udp` lookups for `<LAN_SUBNET>`. It contained zero real domains. LAN clients query the Pi directly. Dropping this traffic does not affect DNS. It prevents roughly 230k junk queries a day in the FTL database. The forward counter should remain zero.

To see what is actually being dropped:

```bash
sudo nft add rule inet lanfw input log prefix "lanfw-drop: " level info limit rate 20/minute
sudo journalctl -kf | grep lanfw-drop
sudo nft -f /etc/nftables.conf     # reload removes the log rule (and resets counters)
```

---

## 7. Service notes

Per-service runbook notes live in [`services/`](services/):

| Document | Covers |
| --- | --- |
| [Applications](services/apps.md) | Filebrowser, MicroBin, Dashboard (starbase-80), Arcane |
| [HTTPS](services/https.md) | Caddy, Let's Encrypt, DuckDNS |
| [Network](services/network.md) | Pi-hole blocklists and the encrypted-DNS bypass, Tailscale |
| [Observability](services/observability.md) | Dozzle, Diun, Beszel |
| [Authentication](services/auth.md) | Authelia forward-auth and TOTP, Docker socket proxies |

---

## 8. Update policy

- **Debian stable and security updates** run continuously through `unattended-upgrades`; third-party repositories are excluded.
- **Other OS and vendor repository updates** run weekly through `apt-get --with-new-pkgs upgrade` after the full backup and before the reboot.
- **Images and `apt full-upgrade`** run quarterly through `quarterly-update.sh`.

`maintenance.sh` **must keep `--with-new-pkgs`.** Plain `upgrade` refuses a new dependency. Kernel meta-packages require one (`linux-image-rpi-v8` → `linux-image-6.18.39-rpi-v8`). Plain `upgrade` therefore holds the kernel. `full-upgrade` can remove packages. Do not run that unattended at 4 am. `--with-new-pkgs` adds dependencies and removes nothing.

The quarterly job restores the prior state after a failed health check:

1. full backup first
2. simulate `full-upgrade`; if it wants to **remove** anything, skip it, fall back
   to `--with-new-pkgs upgrade`, leave removals for a human
3. re-pin each image to the current digest **of its own channel tag** — these are
   not all `latest` (Filebrowser tracks `stable`); resolve the newest Caddy 2.x
   and rewrite the build arg; keep the old file as `.docker-compose.prev.yml`
4. health-check every service for up to 5 min, including an end-to-end TLS check
   through Caddy
5. **on any failure, restore the previous compose file and images automatically**,
   then health-check the rollback too

Run `sudo systemctl start pi-quarterly-update.service` to start early. It runs at 01:00. A new kernel then starts at the 05:00 reboot.

Debian **major** upgrades (13 → 14) are not automated. Run them by hand from a backup.

### AppArmor

The Raspberry Pi kernel includes AppArmor. `security=apparmor` in `/boot/firmware/cmdline.txt` selects it. After boot, `apparmor.service` loads host profiles. Docker assigns `docker-default` to non-privileged containers.

```bash
cat /sys/kernel/security/lsm                    # capability,apparmor
sudo aa-status
docker inspect $(docker ps -q) --format '{{.Name}} {{.AppArmorProfile}}'
```

---

## 9. Performance

Verified 2026-08-23. Most generic Pi changes are already active or unsuitable for this host.

| Tweak | State |
|---|---|
| zram | **already active** — 2 GB, `zstd`, priority 100, via `systemd-zram-setup@zram0` + `rpi-swap`. **Do not `apt install zram-tools`** — it fights the OS's own setup |
| swap on SD | none. Only `/dev/zram0` is in `/proc/swaps`. `/var/swap` exists but is zram's *writeback* device on loop0. Writeback so far: **0 bytes** |
| `/tmp` on tmpfs | Debian 13 default, 1.9 GB. ⚠ wiped on reboot — see [HTTPS](services/https.md) |
| desktop | not installed (Lite image) |
| journal | `Storage=volatile`, lives in `/run`, never touches flash; `maintenance.sh` also vacuums to 14 d |
| power/thermal | `throttled=0x0`, SoC 64–65 °C vs an 80 °C throttle point; checked daily by `disk-guard.sh` |

Do not apply these changes:

- **`/var/log` on tmpfs** — destroys `/var/log/pi-fsck.log`, the only record of
  the 6-monthly check. Buys nothing: `/var/log` is 500 KB, journald is already
  volatile.
- **`/var/tmp` on tmpfs (30 MB)** — `/var/tmp` is the disk-backed escape hatch for
  anything too big for `/tmp`. Capping it reintroduces the failure that bit the
  migration.
- **Overclocking** — DNS server, unattended, nothing CPU-bound (load ~0.3).
- **`gpu_mem=16`** — legacy under `vc4-kms-v3d` (CMA, 76 MB). Reclaims ~60 MB out
  of 2.9 GB free and risks the `/dev/dri` passthrough.
- **Raising `vm.swappiness` for zram** — the usual 100–180 advice assumes swap is
  free. Here zram's writeback target is the **SD card**, the scarce component.
  Left at 60; swap in use: 0 B.
- **USB boot** — the only USB disk is the spinning media drive. The real upgrade
  is a USB SSD.

---

## 10. Constraints

- **The ISP uses CGNAT.** The host has no inbound connectivity. [HTTPS](services/https.md) uses DNS-01 because ACME HTTP-01 cannot work. Re-verify before you spend a day on port forwarding: traceroute puts the router's WAN side on RFC1918 (`hop 2` is a `10.x.x.x` address) while the world sees a different address, and the router's UPnP `GetExternalIPAddress` returns empty. There is no global IPv6 either. A port forward opens only the last hop.
- **Transmission cannot accept inbound peers.** `51413/tcp+udp` are published and LAN-reachable. `network_mode: host` cannot change CGNAT.
- **The upstream options are routable IPv4 or a VPN with port forwarding.** Transmission operates as a closed peer until then.
- **Watch data-drive free space.** Backups abort below ~3.5 GB free. `disk-guard.sh` warns at 95%.
- **appdata is on the SD card.** A card failure can lose up to one day of changes. A USB SSD is the better storage for this state.
- **Transmission RPC has no enforced whitelist.** Authentication uses `pi` and `TRANSMISSION_PASSWORD`.
- **`rpc-whitelist-enabled` and `rpc-host-whitelist-enabled` are `false`.** Enabling either makes `torrents.` return 403 unless Caddy sends `header_up Host localhost` and the source includes `172.18.*`.
- **DuckDNS is a third-party dependency.** If it stops, certificate renewal stops ~60 days later. `disk-guard.sh` warns ~21 days before expiry.
- **Pi-hole is the only resolver the router provides.** Pi-hole failure stops household DNS. See [Dashboard](services/apps.md#dashboard-starbase-80).
- **`cgroup_enable=memory cgroup_memory=1` is at the end of `/boot/firmware/cmdline.txt`.** It overrides the Pi firmware `cgroup_disable=memory` and enables Docker `mem_limit`.
- ⚠ **`/boot/firmware/cmdline.txt` must remain one line.** A newline makes the Pi unbootable. `/boot/firmware/cmdline.txt.bak` is the recovery copy.
- **The firewall allows every private source by design.** It does not defend against a compromised LAN device. See [Firewall](#6-firewall).
- **Filebrowser can access backups.** A user who can use its UI can remove `<DATA_ROOT>/backup`.
- ⚠ **Never run `chmod 777` on the data drive.** The required ownership is `1000:1000`, directories `2775`, and files `0664`. Run `sudo /opt/pi-stack/fix-permissions.sh` to correct it.
- **Keep `/mnt/rpidata/torrent-complete` unchanged.** Containers bind-mount the same path. Renaming it breaks Plex library locations.
- **The HDD is a spinning USB disk.** It is suitable for media and unsuitable for databases. SMART reallocated, pending, uncorrectable, and CRC counts are all 0.
- **Plex receives `/dev/dri` when it exists.** The Pi 4 is a direct-play server. Remove the `devices:` block if Plex cannot start.
- **Stop Plex before editing `Preferences.xml`.** Plex rewrites the file on shutdown.
- **Stop Transmission before editing `settings.json`.** Transmission rewrites the file on shutdown.
- **Filebrowser reads `config.yaml` only.** You can edit that file while its container runs.

---

## 11. Day-to-day

Run these commands on the host for routine checks and maintenance.

```bash
cd /opt/pi-stack
docker compose ps
docker compose logs -f pihole
sudo systemctl start appdata-backup-core.service    # backup now
sudo systemctl start pi-disk-guard.service          # disk/SMART/power/TLS report now
sudo ./fix-permissions.sh                           # Transmission can't delete?
ls -lh /mnt/rpidata/backup/appdata/
```

**Deploy a change from the Mac.** `/tmp` is tmpfs and is cleared on reboot.

```bash
ssh pi 'mkdir -p /tmp/deploy'                       # /tmp is tmpfs, wiped on reboot
scp docker-compose.yml Caddyfile pi:/tmp/deploy/
ssh pi 'sudo install -m 644 /tmp/deploy/* /opt/pi-stack/ && \
        cd /opt/pi-stack && sudo docker compose config -q && \
        sudo docker compose up -d --build'
```

`docker compose config -q` validates the change before it affects a running service. It detects an empty `.env` value and malformed YAML.

In non-interactive SSH, `/usr/sbin` is not on PATH. `swapon`, `sysctl`, and `losetup` are there. Prefix `export PATH=/usr/sbin:/sbin:$PATH` before you run them.
