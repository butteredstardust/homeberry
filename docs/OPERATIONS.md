# pi-stack — operations

Runbook for `raspberrypi`, the household Pi at **<LAN_IP>**.
Build instructions are in [README.md](../README.md); this file assumes it is running.

**Broken right now?** → [§2 Recovery](#2-recovery).

⚠ **This Pi is the LAN's DNS server.** While Pi-hole is down, nothing on the
network resolves — for anyone. Before planned downtime, point the router's DNS
at `1.1.1.1`.

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

Record a baseline here after the build and update it when it moves — a "healthy"
figure is only useful if you know what healthy looked like. Example shape:
`/` 11% used, `$DATA_ROOT` 91% (65 GB free), RAM 2.9 GB available,
`systemctl --failed` empty.

### 1.1 Endpoints

All LAN-only, all behind the firewall (§6). **None is forwarded, and the reasons
none may ever be are in [README §7.3](../README.md#73-tls-is-not-authorisation--never-forward-these-ports).**

Since 2026-08-26 every web UI has an HTTPS name (§7.4). The `Fallback` column is
kept deliberately as the break-glass route for when Caddy or DuckDNS is broken —
but read the note under the table before assuming it is reachable from another
machine. It is not, by default.

Every service uses the same username, `pi`, and a password you set in `.env`.
A single shared password is a deliberate simplification for a LAN-only box; it
is also the first thing to change if that description ever stops being true.
Two exceptions, both in the table.

⚠ **Do not record the actual passwords in this file.** `.env` is the one place
they live, it is mode 600, and it is gitignored. This table names the variable,
never the value.

| Service | HTTPS name (`*.${CADDY_DOMAIN}`) | Fallback | User | Password |
|---|---|---|---|---|
| **Dashboard** | **`home.`** — the front door, links to everything below | `:8084` | none | none |
| Pi-hole | `pihole.` → `/admin` | `:8080/admin` | **none — v6 has no username field** | `.env` → `PIHOLE_PASSWORD` |
| Plex | **not proxied, on purpose** | `:32400/web` | plex.tv account | not on this box |
| Transmission | `torrents.` | `:9091` | `pi` | `.env` → `TRANSMISSION_PASSWORD` |
| Homebridge | `homebridge.` | `:8581` | `pi` | PBKDF2 in `appdata/homebridge/auth.json`, **not** in `.env` |
| Filebrowser | `files.` | `:8082` | `pi` | `.env` → `FILEBROWSER_PASSWORD` |
| Arcane | `docker.` | `:3552` | `arcane` | **exception** — 12+ chars, mixed case, digit and symbol, or Arcane refuses it · `.env` → `ARCANE_PASSWORD` |
| MicroBin | `paste.` | `:8083` | `pi` | `.env` → `MICROBIN_PASSWORD` |
| Samba | n/a — not HTTP | `smb://<LAN_IP>/<share>` | `pi` | `.env` → `SAMBA_PASSWORD` |
| SSH | n/a | `:22` | `pi` | key only, password auth disabled |

⚠ **The Fallback column is a loopback port, not a LAN address.** `BIND_ADDR`
(default `127.0.0.1`) publishes every container UI on the Pi's loopback only, so
`http://<LAN_IP>:8082` is refused from another machine. That is what makes Caddy
a real chokepoint rather than one of two doors — otherwise any LAN device could
skip it and the `ADMIN_SOURCES` allowlist with it.

To use a fallback while Caddy or TLS is broken, tunnel it:

```bash
ssh -N -L 8082:127.0.0.1:8082 pi@<LAN_IP>    # then http://127.0.0.1:8082
```

Four fallbacks are *not* loopback-bound, because those services use
`network_mode: host`: `:8080` (Pi-hole), `:8581` (Homebridge), `:32400` (Plex)
and Samba. The first two are admin ports and are restricted to `ADMIN_SOURCES`
by nftables instead — see §6.

**Plex is deliberately unproxied.** It ships its own `*.plex.direct` certificate
and its clients connect straight to `:32400`; a proxy in front tends to break
direct-play and remote-access detection rather than help.

**Ports 80 and 443 belong to Caddy.** Pi-hole was moved off `:443` (it served a
self-signed block page there that nothing ever reached, because blocked domains
resolve to `0.0.0.0`, not to this Pi) and the dashboard off `:80` to `:8084`.

**Arcane is the password exception.** It enforces 12+ characters with upper,
lower, digit and symbol, and rejects a weak password outright — the CLI errors,
it is not a warning. That login is effectively root on the host (§7.5). Its generated
password is in `.env` → `ARCANE_PASSWORD`, which is **not** consumed by
`docker-compose.yml`; it is stored there so the secret lives with the others.

**Start at the dashboard.** `https://home.${CADDY_DOMAIN}/` is the one to
bookmark. `http://<LAN_IP>/`, `http://<hostname>.local/` and
`http://home.internal/` all still work and reach it *through* Caddy.

Other listening ports: `53` (DNS), `139`/`445` (Samba), `51413` (Transmission
peer), `32410`–`32414` (Plex DLNA), Homebridge HAP (ephemeral).
Authoritative list: `sudo ss -lntp`.

### 1.2 Reading the passwords

`.env` is mode 600 and root-owned, so `sudo` is not optional. This prints all six
— Pi-hole, Samba, Filebrowser, Transmission, Arcane, MicroBin:

```bash
sudo grep -E '_PASSWORD=' /opt/pi-stack/.env               # on the Pi
ssh pi "sudo grep -E '_PASSWORD=' /opt/pi-stack/.env"      # remotely
sudo grep '^ARCANE_PASSWORD=' /opt/pi-stack/.env           # one service
```

Homebridge's is **not** here — PBKDF2 in `auth.json`, reset-only, never
readable.

⚠ **Do not paste that output into MicroBin** (§7.2), or any chat or issue tracker.

Service secrets rather than logins, deliberately excluded from the grep above:

```bash
sudo grep -E 'ARCANE_(ENCRYPTION|JWT)|DUCKDNS' /opt/pi-stack/.env
```

`DUCKDNS_TOKEN` can edit DNS for this subdomain and nothing else; if it leaks,
rotate at duckdns.org then `docker compose up -d caddy`.

### 1.3 Password resets

**Filebrowser** — edit `.env`, restart. Re-applied from the environment at every
start:

```bash
sudo vim /opt/pi-stack/.env          # FILEBROWSER_PASSWORD=
cd /opt/pi-stack && sudo docker compose up -d filebrowser
```

Changing the *username* does not rename the account — filebrowser seeds a new
admin and leaves the old one valid. Delete `appdata/filebrowser/database.db` and
restart so only one exists (this is how `admin` → `pi` was done).

**Pi-hole** — same pattern, `PIHOLE_PASSWORD`, then `docker compose up -d pihole`.
No username in v6; the form is password-only.

**Transmission** — ⚠ **do not edit `settings.json`.** The linuxserver image owns
`rpc-authentication-required`: its init forces it `true` when both `USER` and
`PASS` are set and `false` otherwise, on every start, so a hand-edit is reverted
seconds later. Credentials live in `docker-compose.yml`:

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

```bash
systemctl --failed                                  # the entire alerting system
docker compose -f /opt/pi-stack/docker-compose.yml ps
df -h / /mnt/rpidata
journalctl -u pi-container-watchdog -n 50
sudo systemctl start pi-disk-guard.service && systemctl status pi-disk-guard
```

### 2.2 Container down or unhealthy

```bash
cd /opt/pi-stack
docker logs --tail 100 <name>
docker compose up -d <name>      # recreate from compose
docker restart <name>            # just bounce it
```

`container-watchdog.sh` already restarts unhealthy containers for ~10 min, max
**3 times per 24 h**. If it gave up, the journal says so — restarting is not the
fix; read the logs.

### 2.3 Restore appdata

Main recovery path. Snapshots in `/mnt/rpidata/backup/appdata/`, mirrored to
`~/pi-backups/` on the workstation (set in `mac/pull-backups.sh`). Tarball root is `appdata/`.

```bash
cd /opt/pi-stack
ls -lht /mnt/rpidata/backup/appdata/
docker compose down
sudo systemctl stop beszel-agent
sudo mv appdata appdata.broken                      # keep it, don't delete
sudo tar --same-owner -xzf /mnt/rpidata/backup/appdata/appdata-core-YYYYMMDD-HHMM.tar.gz -C /opt/pi-stack
sudo chown -R beszel:beszel appdata/beszel-agent
docker compose up -d
sudo systemctl start beszel-agent
```

Single service: `sudo tar -xzf <snap>.tar.gz -C /opt/pi-stack appdata/homebridge`

**`core` vs `full`:** `core` (nightly, ~70 MB, keep 7) holds everything
irreplaceable — Plex library DB and watch state, HomeKit pairings, torrent resume
data, Pi-hole config, Caddy's certificates. `full` (Sat 03:00, ~2.4 GB, keep 1)
adds Plex's `Metadata/` artwork, which Plex re-downloads by itself. **Restoring
`core` loses nothing permanent.**

`pi-restore-test.timer` independently proves this every quarter: it extracts
the newest core archive under `/var/tmp`, checks load-bearing paths and Beszel
ownership, and opens every staged SQLite database. Run it on demand with
`sudo systemctl start pi-restore-test.service`.

Pi unreachable? Same tarballs on the Mac:
`scp ~/pi-backups/appdata-core-*.tar.gz pi:/tmp/`

### 2.4 SD card died — full rebuild

The HDD and its backups survive; only the OS is lost. Follow
[README §4](../README.md#4-build) for steps 1–5, then instead of starting empty:

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

`/mnt/rpidata` is `nofail`, so the Pi boots without it and DNS keeps working;
Plex and Transmission start with empty media.

Docker is ordered `After=mnt-rpidata.mount`
(`/etc/systemd/system/docker.service.d/10-wait-for-data-drive.conf`). Ordering
**only** — deliberately not `RequiresMountsFor=`, which would stop Docker
entirely if the disk died and take LAN DNS with it.

Drive replaced? The new UUID goes in `.env` (`DATA_DRIVE_UUID`) and `/etc/fstab`
— blank it in `.env` and re-run `sudo bash provision.sh drive` to have it
re-detected from `DATA_DEV` and written back.

### 2.6 Bad update

`quarterly-update.sh` rolls back automatically on a failed health check. By hand:

```bash
cd /opt/pi-stack
cp .docker-compose.prev.yml docker-compose.yml
docker compose up -d --build
cat /mnt/rpidata/backup/quarterly-update.log
```

Old images are still on disk — `maintenance.sh` prunes only *dangling* images,
never `image prune -a`, precisely so the rollback target survives.

### 2.7 DNS down

```bash
docker logs --tail 50 pihole
docker exec pihole dig +short @127.0.0.1 pi.hole
sudo ss -lnup | grep ':53 '        # something else on the port?
docker compose up -d pihole
```

Mitigate immediately: set the router's DNS to `1.1.1.1`.

### 2.8 HTTPS broken

Nothing is lost, but the way back in is narrower than it used to be. `:8080`
(Pi-hole) and `:8581` (Homebridge) still answer on `<LAN_IP>` directly. The
container UIs (`:8084`, `:8082`, `:8083`, `:9091`, `:3552`, `:8085`, `:8086`)
are bound to loopback by `BIND_ADDR`, so reach them over ssh — one tunnel does
all of them:

```bash
ssh -N -L 8084:127.0.0.1:8084 -L 8082:127.0.0.1:8082 -L 8083:127.0.0.1:8083 \
       -L 9091:127.0.0.1:9091 -L 3552:127.0.0.1:3552 -L 8085:127.0.0.1:8085 \
       -L 8086:127.0.0.1:8086 pi@<LAN_IP>
```

`http://<LAN_IP>/` also still reaches the dashboard, since Caddy serves that
plain-HTTP site block without a certificate. Diagnose with §7.4.

If ssh itself is refused, `ADMIN_SOURCES` is the first thing to check — you may
be on the wrong machine. See §6.

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

Saturday is staggered so nothing overlaps, and backups run **before** the upgrade
so the rollback snapshot predates any bad package. Quarterly and 6-monthly jobs
occupy different months so they can never collide.

Steady-state backup cost: ~2.9 GB on the Pi, ~1 GB on the Mac.

Two details not to break:

- `pi-reboot.timer` is **not** `Persistent=true`. A missed reboot must not fire
  on next boot, or a Pi that was off over the weekend reboots itself on power-on.
- `pi-maintenance.service` has `TimeoutStartSec=3000`, so a wedged apt is killed
  at 04:50 and cannot still hold dpkg locks when the reboot lands.

---

## 4. Monitoring

**Nothing notifies you.** Push notifications were declined; this is the whole
alerting system:

```bash
systemctl --failed                          # <-- the one that matters
systemctl status pi-disk-guard              # disk, SMART, power/thermal, zram, TLS
journalctl -u pi-container-watchdog -n 50
sudo tail /var/log/pi-fsck.log
cat /mnt/rpidata/backup/quarterly-update.log
tail ~/Library/Logs/pi-backup-pull.log      # on the Mac
```

`disk-guard.sh` exits non-zero on a problem specifically so it lands in
`systemctl --failed`. Threshold is 95% on `/mnt/rpidata`; certificate warning at
21 days.

journald is `Storage=volatile` (Pi OS default, to spare the SD card) — **logs do
not survive a reboot**. Diagnose before the Saturday 05:00 restart, not after.

Since 2026-08-26 there are also three browser-based views of the same box — but
read the caveat below before relying on them:

| | Where | What it adds |
|---|---|---|
| Dozzle | `https://logs.${CADDY_DOMAIN}` | all twelve containers' logs at once, searchable |
| Beszel | `https://metrics.${CADDY_DOMAIN}` | CPU/mem/disk/net **history**, which nothing else here keeps |
| Diun | its own log, read via Dozzle | daily "a newer image was published" |

⚠ **None of these changed the first sentence of this section: nothing notifies
you.** They are dashboards — they report only when someone opens them. Beszel can
alert but has not been configured to, and Diun's notifiers are deliberately off
(§7.8). `systemctl --failed` is still the alerting system. Details in §7.8.

---

## 5. Self-healing

| Layer | Covers | Does not cover |
|---|---|---|
| `restart: unless-stopped` | a process that **exits** | a process that hangs |
| healthchecks + `container-watchdog.sh` | container **up but not answering** | a host that stops scheduling |
| hardware watchdog (BCM2835) | **kernel hang** — resets the board | dead SD card or disk |
| backups + Mac copy | **data loss** | everything above, faster |

A container stopped **by hand** stays down across reboots — that is what
`unless-stopped` means. Hence `backup-appdata.sh` and `fsck-datadrive.sh` restart
services from a `trap` instead of trusting the restart policy.

`container-watchdog.sh` is deliberately timid: 2 consecutive unhealthy checks
(~10 min) before acting, max **3 restarts per container per 24 h**, never touches
a stopped container, takes the same `flock` as the backup. Past budget it stops
and says a human is needed — a restart loop on Pi-hole is repeated LAN DNS
outages for everyone.

Hardware watchdog needs **no configuration**; Pi OS ships
`/usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf`. Verify what is *in
effect*, never what is on disk:

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

Added 2026-08-25. Before that there was none: `-P INPUT ACCEPT`, no ufw, no
nftables, nothing but Docker's own publish rules.

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

**Tier 1 — what it buys.** The LAN keeps unrestricted access to the household
services, so nothing in the house behaves differently. The only traffic dropped
is from a non-private source. Worth having because if a port forward is ever
added on the router by accident, this is what stands between that mistake and an
open Filebrowser. It is a backstop, not the control — see
[README §7.3](../README.md#73-tls-is-not-authorisation--never-forward-these-ports).

**Tier 2 — what it buys, and why it ships off.** Tier 1 does nothing against a
device that is *already* on your LAN. Tier 2 is the answer: SSH, the Pi-hole
admin panel and Homebridge are dropped for any private source outside
`ADMIN_SOURCES`, so a compromised TV can stream Plex and resolve DNS but cannot
reach the infrastructure. **The shipped default is all of RFC1918**, which makes
it exactly as permissive as tier 1 — deliberately, because a first build on a Pi
with no serial console must not be able to lock its owner out. It only starts
doing anything once you narrow it:

```bash
# in .env
ADMIN_SOURCES="192.168.0.50/32"        # your workstation, as a DHCP reservation
```

then re-run the phase — and read the deadman-switch recipe below first:

```bash
sudo bash provision.sh firewall
```

`provision.sh` arms `fw-deadman` automatically whenever `ADMIN_SOURCES` differs
from the default, and tells you to stop the timer once you have confirmed access
from a **new** session.

**Tier 2 stops at layer 4, and that is not a gap — it is a split.** Once every
web UI is behind Caddy on `:443`, the firewall cannot tell `docker.DOMAIN` from
`home.DOMAIN`; they are the same TCP port. The per-vhost half lives in the
`Caddyfile`'s `(adminonly)` snippet and covers `pihole` `files` `torrents`
`docker` `homebridge` `logs` `metrics`. It reads the **same** `ADMIN_SOURCES`
value, so the two cannot drift — but Caddy substitutes it at parse time, so a
change needs a restart, not a reload:

```bash
docker compose up -d --force-recreate caddy
```

Left open on purpose: the dashboard (`home.`) and the pastebin (`paste.`).

**The tailnet is always admin.** nftables accepts `tailscale0` by interface
*before* the tier-2 rule (its order there is load-bearing — a tailnet peer's
source is `100.64.0.0/10`, which is not in `ADMIN_SOURCES`, so the wrong order
would kill remote SSH). Caddy has no interface to match on, so it allows
`100.64.0.0/10` outright; that is safe only because tier 1 already drops every
non-private source that did not arrive on `tailscale0`. **Joining a tailnet is
the cheapest insurance against locking yourself out of your own firewall.**

⚠ **This is a reachability tier, not authentication.** Every service keeps its
own login. Do not remove one because this exists.

**Why not ufw.** ufw filters in `filter`/INPUT. Docker DNATs published ports in
`nat`/PREROUTING, which the kernel traverses **first**, so packets to 8082, 8083,
9091 and 3552 never reach a ufw rule. You would get a green `ufw status` and an
unchanged attack surface. Hence a `forward` chain here, not just `input`.

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

Inbound BitTorrent peers on 51413 are dropped by the forward chain. Academic
under CGNAT (§10) — if that ever changes and you want a forwarded peer port, add
the accept in the `forward` chain and nowhere else.

**Changing the rules without locking yourself out.** There is no serial console
on this Pi; a lockout means HDMI and a keyboard. Arm a dead man's switch first:

```bash
sudo systemd-run --on-active=600 --unit=fw-deadman /usr/sbin/nft destroy table inet lanfw
sudo nft -c -f /etc/nftables.conf     # syntax check, no apply
sudo nft -f /etc/nftables.conf
# verify from ANOTHER machine, on a NEW connection, before you trust it
sudo systemctl stop fw-deadman.timer  # only once you are sure
```

**The input drop counter is expected to climb — that is not an attack.** The ISP
router queries this Pi's DNS from a CGNAT-range address (a `100.64.0.0/10` address, which
rotates). On the setup this came from: **the overwhelming majority of queries in `pihole-FTL.db` arrived this way, 100% of
them reverse-DNS and `_dns-sd._udp` lookups for `<LAN_SUBNET>`, zero real
domains.** Every LAN client resolves against the Pi directly, so nothing
forwards real DNS through the router and dropping this breaks nothing — it also
stops roughly 230k junk queries a day from bloating the FTL database on the SD
card. The forward counter should stay at zero.

To see what is actually being dropped:

```bash
sudo nft add rule inet lanfw input log prefix "lanfw-drop: " level info limit rate 20/minute
sudo journalctl -kf | grep lanfw-drop
sudo nft -f /etc/nftables.conf     # reload removes the log rule (and resets counters)
```

---

## 7. Service notes

### 7.1 Filebrowser

Swapped 2026-08-25 from `filebrowser/filebrowser:s6` to **FileBrowser Quantum**
(`gtstef/filebrowser:stable`, v1.5.3). The original was archived with open
advisories and no fixes coming. It is a hard fork, so **nothing carried over**:
the old bolt DB was not migrated, the config format is different, the CLI/shell
runner is gone. Old v1 state was parked at `appdata/filebrowser.fb1-archived/`
and deleted 2026-08-25.

| | |
|---|---|
| Image | `gtstef/filebrowser:stable` (v1.x). **Not `beta`** — that is v2.x, which moves bolt → SQLite and renames config keys |
| Config | `filebrowser-config.yaml` → `appdata/filebrowser/config.yaml`; read at every start |
| Database | `appdata/filebrowser/database.db` — users, shares, UI-set settings |
| Runs as | uid/gid 1000, natively — no PUID/PGID variant tag needed |
| Scope | whole drive at `/srv`, one source named `RPIDATA` |

- **`FILEBROWSER_ADMIN_PASSWORD` is enforced at every start**, not just the
  first. Log line: `Resetting admin user to default username and password.` So
  `.env` is authoritative and **a password changed in the web UI is silently
  reverted** — at the latest by the Saturday 05:00 reboot. To manage it from the
  UI instead, drop that variable from `docker-compose.yml`.
- **The entrypoint is overridden to set `umask 0002`.** Go applies
  `createFilePermission`/`createDirectoryPermission` through the umask, which is
  0022 in this image, so without the override uploads silently land 0644/0755 and
  lose the group write bit that Samba's masks and `fix-permissions.sh` assume.
  Verified: uploads are `1000:1000` `0664`, new dirs `drwxrwsr-x`. If a future
  release goes distroless this fails loudly at start and the quarterly job rolls
  back.
- **The thumbnail cache is a 256 MB tmpfs** at `/home/filebrowser/tmp`. A RAM
  disk on purpose: the SD benchmarks at ~19 MB/s (the app warns at every start),
  thumbnails for a large media library are pure flash wear, and anything under
  `appdata/` would land in every nightly backup. The cache has **no eviction** —
  `cacheDirCleanup` only wipes at start and shutdown — so the size cap is the
  only bound. Ignore the "less than the 20 GB minimum recommended" warning. When
  it fills, a cache write fails, gets logged, and the preview is still served.
- Config changes made in the **UI** live in `database.db` and are not in git.
  Keep durable decisions in `filebrowser-config.yaml`.

To narrow what it can reach, replace the `/srv` volume with per-folder mounts and
list them as separate entries under `server.sources` — Quantum supports multiple
named sources; the old one could only show one root.

### 7.2 MicroBin

Pastebin and small-file drop, added 2026-08-25 to move text between machines on
the LAN without a shared clipboard. Rust, single binary, SQLite.

| | |
|---|---|
| Image | `danielszabo99/microbin:latest`, digest-pinned, arm64 |
| Version | 2.1.4 |
| Data | `appdata/microbin/` — `database.sqlite` + `public/` |
| Runs as | `1000:1000` via `user:` — image has no `USER` and ignores PUID/PGID |
| Config | environment only, in `docker-compose.yml`; no config file |

⚠ **Auth does not cover paste reads.** Verified 2026-08-25:

| Path | Unauthenticated |
|---|---|
| `/`, `/admin`, `/pastalist` | **401** |
| `/upload/<id>`, `/raw/<id>` | **200, full content** |

Upstream behaviour — it is what makes a link shareable — and no setting turns it
off. HTTPS changed nothing about this; encrypting transport adds no authorisation
check. **Never paste secrets into it.** Enumeration is still blocked: ids are
random animal triplets and the listing page needs the password.

- **`MICROBIN_ADMIN_PASSWORD` defaults to the published `admin`/`m1cr0b1n`.**
  Overriding it is not optional.
- **`MICROBIN_PUBLIC_PATH` must be set**, now to
  `https://paste.${CADDY_DOMAIN}`, or every "copy link" hands out a
  `localhost` URL useless on another machine.
- **Upload cap is lowered to 64 MB** (default 2048). `appdata` is on the SD card
  and is tar'd whole into the nightly backup, so one large upload would balloon a
  ~70 MB snapshot. Use Samba for anything big.
- **No `curl` or `wget` in the image**, same trap as Arcane — but it is a Debian
  trixie base with `bash`, so the healthcheck speaks HTTP over `/dev/tcp`. It
  accepts `401` because the index is behind basic auth.
- Pastes expire after **24 h** by default; GC removes anything older than **90
  days** (`MICROBIN_DEFAULT_EXPIRY`, `MICROBIN_GC_DAYS`). Pick a longer expiry in
  the form for anything you want to keep.

### 7.3 Dashboard (starbase-80)

Added 2026-08-25 so nobody has to remember which port a service lives on.

| | |
|---|---|
| Image | `jordanroher/starbase-80` v1.6.6, digest-pinned |
| Port | **8084** on the host → 4173 in the container (nginx listens on 4173) |
| Links | `starbase80-config.json`, mounted read-only |
| Icons | `appdata/starbase80/icons/`, 9 PNGs, ~270 KB, served locally |
| Auth | **none** — it is a page of links; the firewall and "never forward" are the control |

**Four names reach it, all now through Caddy:**

| URL | Works on | Needs |
|---|---|---|
| `https://home.${CADDY_DOMAIN}/` | everything, incl. hardcoded-DNS devices | the internet's DNS |
| `http://<LAN_IP>/` | everything | nothing |
| `http://raspberrypi.local/` | macOS, iOS, Windows, Linux with Avahi | mDNS (already running) |
| `http://home.internal/` | everything, **since the router's secondary DNS was removed** | Pi-hole must be the only resolver |

⚠ **`home.internal` briefly did not work, and the cause is worth remembering.**
The router's DHCP was handing out **two** resolvers — `<LAN_IP>` *and*
`8.8.8.8`. `dig` queries only the first and answered correctly, which made it
look fine; macOS `getaddrinfo` races both and takes Google's NXDOMAIN, so every
Pi-hole-only name failed. Verified 2026-08-25: `pi.hole` failed identically, and
setting the Mac to `<LAN_IP>` alone made `home.internal` resolve instantly.
**Fixed at the router** by removing the secondary DNS entry — one change, every
device. If a secondary resolver is ever re-added there, these names break again
and the symptom looks like a Pi-hole fault rather than a router one. Clients pick
it up on their next DHCP renewal (2 h lease); force it on macOS with
`sudo ipconfig set en0 DHCP`.

Ad blocking is **not** affected by this — verified, a blocked domain still
returns `0.0.0.0` five times out of five, because Pi-hole answers positively and
fast. Only names existing *solely* in Pi-hole are hit.

The record is declared as `FTLCONF_dns_hosts` on the pihole service in
`docker-compose.yml`, semicolon-separated. ⚠ Do **not** add local DNS records in
the Pi-hole web UI or by editing `pihole.toml` — Pi-hole rewrites that file and
the next container recreate discards them.

**Things that will bite you:**

- **It runs a full Vite build (`npm run build`) at every start**, in the
  foreground, before nginx binds. Measured 9.4 s on this Pi 4. `start_period` is
  60 s so a slow boot is not mistaken for a failure and restarted into another
  build.
- **`mem_limit: 1g` is enforced as of 2026-08-25 — it was a silent no-op before
  that** (§10, cmdline). ⚠ The limit is fixed when a container is **created**, so
  `docker compose restart` does not apply a changed value; use
  `docker compose up -d --force-recreate <svc>`. Verify with
  `docker inspect starbase80 --format '{{.HostConfig.Memory}}'` → `1073741824`.
- **It must run as root**, unlike MicroBin which is pinned to 1000:1000. The
  entrypoint `sed -i`s root-owned 0644 files inside `/app` and then builds there;
  as uid 1000 every write fails and the container dies before nginx starts. It
  holds no secrets, mounts only two read-only paths and has no socket.
- **Bad JSON takes the dashboard down, deliberately** — the entrypoint validates
  `config.json` and exits 1 rather than serve a broken page. Nothing else in the
  stack is affected. Check with `python3 -m json.tool starbase80-config.json`
  before restarting.
- **The links moved from raw IPs to HTTPS names on 2026-08-26**, reversing the
  rule that used to be here. The old reasoning was that Pi-hole names fail on a
  device with hardcoded DNS. DuckDNS names do not have that problem: they are
  **public** records, so they resolve on any device, including one using Google's
  resolvers, which `home.internal` never could. Plex and Samba keep raw IPs —
  Plex is unproxied and `smb://` is not HTTP.
- Editing links: `starbase80-config.json` → `docker compose up -d
  --force-recreate starbase80`. The mount is read-only, so the running container
  never rewrites it.

### 7.4 HTTPS (Caddy + Let's Encrypt + DuckDNS)

Added 2026-08-26. Routing and reasoning live in `Caddyfile` — **read that file
first.** The design constraints are in
[README §7.1–7.2](../README.md#71-https-works-because-of-dns-01-not-because-anything-is-exposed).
This section is what to do when it misbehaves.

| | |
|---|---|
| Image | **built here**, `caddy/Dockerfile` — official image has no DNS modules |
| Plugin | `github.com/caddy-dns/duckdns`, compiled in via `xcaddy` |
| Build time | ~6 min on a Pi 4 |
| Certificate | one wildcard, `*.${CADDY_DOMAIN}`, 90 days |
| ACME account | **no email registered** (owner's choice) |

**Operational consequences of the build:**

- Caddy is **not** in `quarterly-update.sh`'s digest `CHANNELS` — there is no
  digest to pin. The script bumps the `CADDY_VERSION` build arg instead and
  rebuilds under the same backup/health/rollback gate.
- Use `docker compose up -d --build caddy` after editing `caddy/Dockerfile`.
- Use `docker compose pull --ignore-buildable`, or the pull fails looking for
  `pi-stack/caddy` on Docker Hub.

**The Dockerfile's final `RUN caddy list-modules | grep -q dns.providers.duckdns`
is load-bearing.** Without it a missing plugin fails at *runtime*, after `:80`
and `:443` are already bound.

⚠ **Caddy falls back to its own internal CA when ACME fails**, so the site keeps
working with a certificate nothing trusts, silently. With no ACME account email,
Let's Encrypt cannot warn about a stalled renewal, and journald is
`Storage=volatile` so the failure logs vanish at the next reboot. `disk-guard.sh`
therefore checks issuer and expiry daily (21-day warning) and trips
`systemctl --failed`.

```bash
# what is actually being served — the -servername is MANDATORY, or you get the
# fallback certificate and a false alarm
echo | openssl s_client -connect 127.0.0.1:443 \
  -servername home.${CADDY_DOMAIN} 2>/dev/null \
  | openssl x509 -noout -issuer -dates

docker logs caddy 2>&1 | grep -iE 'acme|challenge|duckdns'

# reload routing without dropping connections (no restart, no re-issuance)
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

**Known failure modes, all hit during setup:**

- **`lookup acme-v02.api.letsencrypt.org on 127.0.0.11:53: server misbehaving`** —
  compose recreated `pihole` and `caddy` in the same second, so Caddy's DNS path
  (Docker → host → Pi-hole) had no resolver. Fixed with `dns: [1.1.1.1, 9.9.9.9]`
  on the caddy service. ⚠ **`depends_on` is the wrong fix** and was rejected
  deliberately: Caddy proxies Pi-hole's own admin UI, so making Caddy wait on
  Pi-hole lets a sick Pi-hole take every name down. The `dns:` key only affects
  external queries — container-name resolution via `127.0.0.11` still works.
- **`resolvers 1.1.1.1 9.9.9.9` inside the `tls` block is separate and equally
  load-bearing.** After writing the TXT record Caddy polls DNS to confirm
  propagation; left alone it asks Pi-hole *on this same Pi*, which has cached the
  old empty TXT and serves it for the full TTL, so Caddy waits for a record it
  already set.
- **Do not diagnose DuckDNS propagation through a caching recursor.** A canary
  TXT looked stuck for minutes; `1.1.1.1` was serving a cached copy. Query the
  authoritative server: `dig TXT _acme-challenge.${CADDY_DOMAIN}
  @ns8.duckdns.org` (TTL is 60 s).
- **`caddy fmt` complains after hand-edits.** Check with
  `docker exec caddy caddy fmt /etc/caddy/Caddyfile | diff - /opt/pi-stack/Caddyfile`.
- **`/tmp` is tmpfs and is wiped on reboot.** `mkdir -p /tmp/deploy` before `scp`
  after a restart, or the copy fails with `dest open ... Failure`.

⚠ **Never run the stock DuckDNS updater cron on this network.** A `/update` call
with no `ip=` parameter sets the A record to the *caller's* address — which here
is the public CGNAT address — and every name breaks at once. Verified 2026-08-26
with a canary that the plugin's TXT-only writes do **not** do this: the A record
stayed `<LAN_IP>`.

### 7.5 Arcane

Added 2026-08-23. `ghcr.io/getarcaneapp/manager` (**not** `ofkm/arcane` — the
project moved), arm64, port 3552, data in `appdata/arcane/arcane.db`.

- **It does not mount the Docker socket.** It reaches the API over
  `DOCKER_HOST=tcp://socket-proxy-rw:2375`, on the `internal: true`
  `socketproxy_rw` network. Consequence: **`group_add`/`DOCKER_GID` are no longer
  needed by Arcane** — a TCP socket has no file permissions. `DOCKER_GID` is
  still used by the native Beszel agent, so `provision.sh` still derives it.
  Historical note: before the proxy, Arcane needed `group_add:
  ["${DOCKER_GID}"]` because `/var/run/docker.sock` is `root:docker` mode 660,
  and without it the UI loaded and listed *nothing*.
- **The image is DISTROLESS** — no shell, no wget, no curl, so a curl/wget
  healthcheck can never pass and leaves it permanently unhealthy for
  `container-watchdog.sh` to restart in a loop. The binary has its own
  subcommand: `test: ["CMD", "./arcane", "health"]`.
- Seeded login is **`arcane` / `arcane-admin`**, printed in the container log.
  The official docs claim admin/admin and are wrong. Renamed to `pi` 2026-08-25.

⚠ **Still treat its login as root on the host, proxy or not.** `socket-proxy-rw`
blocks `EXEC` and narrows the API to what Arcane actually uses, which removes
the one-line "shell inside any container" path — but anything that can *create*
a container can create one with `/` bind-mounted. The proxy reduces the blast
radius of a bug in Arcane; it is not a privilege boundary between the person
logged into Arcane and the host. Set `SOCKET_PROXY_POST=0` in `.env` to make it
genuinely read-only. See
[README §7.3](../README.md#73-tls-is-not-authorisation--never-forward-these-ports),
and §7.9 for the proxy itself.

⚠ **Historical note, since older copies of this file said otherwise:** Arcane
used to mount `/var/run/docker.sock` directly, and the note here read "`:ro` on
the socket is theatre — one socket serves reads and writes alike". That was
true and is why the proxy exists: the Docker API is not authorisation-aware, so
read-only had to be enforced *outside* it.

**Leave its four risky jobs disabled.** All ship off and are verified false in
`arcane.db` settings: `autoUpdate`, `autoHealEnabled`, `scheduledPruneEnabled`,
`vulnerabilityScanEnabled`. Auto-update bypasses the backup/health-gate/rollback
in §8; auto-heal duplicates `container-watchdog.sh` but fires every 30 s with no
24 h budget; scheduled-prune can delete the image a rollback needs. Use Arcane to
look, and to start/stop/restart.

**The Projects page needs a mount.** Arcane discovers projects by scanning its
`projectsDirectory` (`/app/data/projects`) on disk; it does **not** adopt running
compose projects from their `com.docker.compose.project` labels. So a
hand-deployed stack shows 9 containers and 0 projects. Added 2026-08-26:

```yaml
- /opt/pi-stack:/app/data/projects/pi-stack:ro
```

Arcane then logs `Discovered new project ... project=pi-stack` and reports
running 9/9. Two things `:ro` does **not** do:

- **Deploy / Redeploy / Stop still work** (unless `SOCKET_PROXY_POST=0`). They
  go over the Docker API, and write nothing to the project directory — the mount
  is irrelevant to them. A stray click restarts the whole stack, Pi-hole
  included. There is no `redeploy_disabled` column in Arcane's schema (it is
  computed, and appears tied to `gitops_managed_by`), so those buttons cannot be
  greyed out. **Treat the page as read-only by convention** — or set
  `SOCKET_PROXY_POST=0` and have it enforced.
- It is not a new privilege boundary. Arcane's API access is what makes it root,
  and that is bounded by the socket proxy, not by this mount.

What `:ro` *does* buy: no web-editor edits silently diverging from the git copy.

**Known-wrong field:** the API reports `hasBuildDirective: false` even though the
caddy service has `build: ./caddy`, so an Arcane-run deploy would be a plain
`up -d` and a Caddy bump made that way would silently no-op. `quarterly-update.sh`
does pass `--build`.

The DB row caches `status=unknown, 0/0` with
`status_reason = "…status pending Docker service query"`. That is stale — the
live API resolves it correctly. Do not read the row and panic.

### 7.6 Pi-hole: blocklists, and the encrypted-DNS bypass

**`gravity.db` is authoritative for adlists — `/etc/pihole/adlists.list` is a v5
leftover and lies.** It shows one list; there are **17 rows, 9 enabled**.
Always query the DB:

```bash
docker exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db \
  'SELECT id,enabled,address,comment FROM adlist ORDER BY id;'
docker exec pihole pihole -g          # rebuild after any change, ~2 min
```

⚠ `pihole-FTL sqlite3`, not `sqlite3` — the container is minimal and has no
standalone binary. And **single quotes** for string literals: SQLite reads
`"..."` as a *column reference*, so a double-quoted INSERT fails with
`no such column`. For anything non-trivial, write the SQL to a file and pipe it
in (`sqlite3 db < file.sql`) rather than nesting quotes inside `ssh`/`docker exec`.

⚠ `sqlite3 -column /tmp/q.sql` **hangs**. Passing a `.sql` file as the first
argument opens it *as the database* and blocks on stdin. Always `< file.sql`.

**The repository's declarative source is `config/pihole-adlists.txt`**, applied
by `sudo bash provision.sh adlists`. The import is additive and idempotent — an
address already in `gravity.db` keeps its current enabled state and comment, so
a list you disabled by hand stays disabled across re-runs, and nothing is ever
deleted. Add a list there rather than in the web UI if you want it to survive a
rebuild.

Current gravity: **1,172,601 unique domains** (1,301,928 rows) across 9 lists.

#### The enabled set (reviewed 2026-08-26)

| id | List | Domains | Genuinely unique | Role |
|---|---|---|---|---|
| 14 | developerdan ads-and-tracking-extended | 429,286 | 303,992 | Bulk ads/tracking |
| 19 | HaGeZi Pro | 226,095 | 127,157 | Curated ads/tracking |
| 23 | **HaGeZi TIF Medium** | 326,409 | — (new) | Malware/phishing/scam |
| 5 | AdguardDNS (r-a-y mirror) | 176,859 | 94,843 | Mobile ads |
| 1 | StevenBlack | 81,395 | 50,245 | Baseline |
| 13 | oisd small | 58,714 | 35,459 | Low-false-positive baseline |
| 22 | dibdot DoH-IP-blocklists | 1,914 | 1,901 | DoH endpoints |
| 16 | nocoin | 313 | 143 | Cryptojacking |
| 8 | EasyPrivacySpecific | 943 | 102 | Marginal, but same repo as id 5 |

**Disabled, not deleted** — `enabled=0` with a dated `comment` explaining why, so
the decision is reversible and self-documenting. Re-enable with an `UPDATE` plus
`pihole -g`; never `DELETE`, or the reasoning is lost.

| id | List | Why disabled |
|---|---|---|
| 10 | GoodbyeAds-YouTube | 97,446 of its 97,645 entries are `googlevideo.com` — YouTube's **content** CDN, not ads. Upstream last commit 2024-11-22. |
| 2, 4 | Ultimate.Hosts.Blacklist `hosts0`,`hosts1` | See below. |
| 21 | SpotifyAdBlock | Blocks 746 `spotify.com`/`scdn.co` hosts including `*.video-ak.cdn.spotify.com` content CDNs. |
| 12 | AdAway | 6,540 domains, **10** unique. |
| 15 | yoyo.org | 3,518 domains, **2** unique. |
| 9 | AdguardMobileAds | 924 domains, **4** unique. |
| 3 | rolist-hosts | 97 domains, 19 unique. Upstream last commit 2020-01-20. |

#### Why Ultimate.Hosts.Blacklist was dropped, and what replaced it

It looked like the largest contributor worth keeping — 297,500 domains, 174,354
of them unique to it. Two findings reversed that:

1. **Only 2 of 6 shards were imported.** Upstream ships `hosts0`–`hosts5`; the
   config had `hosts0` and `hosts1`. That is an arbitrary third of a list — the
   coverage was never coherent to begin with.
2. **Sampling the 174,354 unique domains showed they are not ad domains.** They
   are phishing/scam hosts on free platforms — `0ffice-resolving-l0gin-365.*`,
   `att-team-104712.weeblysite.com`, `*.workers.dev`, `*.000webhostapp.com`,
   IPFS-gateway phishing. Genuine threat coverage, but in the **wrong shape**: a
   static snapshot of *ephemeral* indicators. Phishing hosts live days to weeks,
   so a frozen list of them is mostly long-dead domains, while the live ones are
   by definition absent.

Replaced by **HaGeZi TIF Medium** (id 23) — a maintained threat feed covering the
same category properly. Same maintainer and same Codeberg mirror as id 19, so it
adds **no new dependency**.

⚠ **Medium tier deliberately.** Full `tif.txt` is 2,148,490 entries and upstream
warns it over-blocks. `tif.mini` is 173,613. Medium (326,409) is the balance
point. Do not "upgrade" to full without re-running the false-positive sweep.

#### Two results that look like regressions but are not

**DoH hostnames now answer `NOERROR` + `0.0.0.0` instead of `NXDOMAIN`.**
Nothing broke. TIF Medium contains the DoH endpoints itself, and a **gravity hit
takes precedence** over the `server=/domain/` path in `misc.dnsmasq_lines`.
Gravity answers `0.0.0.0`; `server=/x/` answers NXDOMAIN. Both block the
bootstrap — a client cannot open TLS to `0.0.0.0`. Verified 17/17 still blocked.
Keep the `dnsmasq_lines` regardless: they are the layer that does not depend on a
third-party list continuing to carry those names.

**`scdn.co` and `open.scdn.co` return no address.** They have no A record at
`1.1.1.1` either — apex/CNAME-only names. Not a false positive. When a check
looks like an over-block, **always compare against a public resolver before
acting**; `dig +short | tail -1` renders NODATA and NXDOMAIN identically.

#### What DNS blocking cannot do — do not re-add lists for this

Verified 2026-08-26 after dropping the YouTube/Spotify/Romanian lists. In all
three cases the answer is **not** "find a better list".

**YouTube ads: impossible via DNS.** Ads stream from `*.googlevideo.com` — the
same hosts, often the same connections, as the video itself. There is no
hostname that serves ads and not content. That is exactly why GoodbyeAds blocked
97,446 `googlevideo.com` names: a shotgun that degrades playback. Measured cost
of dropping it: a 40-domain sample was **0 blocked, 39 NXDOMAIN (already dead
ephemeral CDN names), 1 live** — and that one *should* resolve, it serves video.
Nothing of value was lost. Fix client-side: uBlock Origin, SponsorBlock,
ReVanced (Android), `yt-dlp`, or Premium.

**Spotify audio ads: impossible via DNS.** Free-tier audio ads are injected into
the same stream, from the same CDN, as the music. DNS can only reach the
*named* ad/telemetry hosts — and those are still blocked without list 21:

| Host | Status | |
|---|---|---|
| `adeventtracker.spotify.com`, `ads-fa.spotify.com`, `analytics.spotify.com`, `adstudio.spotify.com` | `0.0.0.0` | still blocked |
| `pagead2.googlesyndication.com`, `googleads.g.doubleclick.net`, `s0.2mdn.net` | `0.0.0.0` | wildcard-covered by the general lists |
| `spclient.wg.spotify.com`, `partners.spotify.com`, `desktop.spotify.com` | resolves | **app-critical, must not be blocked** |

Fix client-side: SpotX-Bash / BlockTheSpot patch the desktop client, or Premium.

**Romanian ads: the dead list cost nothing.** Of rolist's 97 domains — 75 still
blocked by exact match, 8 more by wildcard, **13 dead upstream** (the list rotted
since its 2020 last commit), and exactly **1** live and unblocked: `zopim.com`,
which is Zendesk Chat — a support widget, not an ad network. Leave it resolving.

⚠ **Do not feed ROad Block (`tcptomato/ROad-Block`) to Pi-hole**, despite it
being the actively-maintained Romanian list (last commit 2026-08-24). It is a
**browser** filter list: 350 of its 482 `||` rules carry a URL path
(`||fanatik.ro/wp-content/.../netbet*.webp`), which DNS cannot express. Pi-hole
drops those as non-domain entries — and any that did parse would blackhole whole
legitimate news sites (`fanatik.ro`, `luju.ro`, `stiridecluj.ro`). It covered
exactly 1 of the 22 candidate gap domains. Its correct home is **uBlock Origin**
in the browser, where path matching works.

**General rule: a filter list full of URL paths or cosmetic (`##`) rules is a
browser list.** Check `grep '^||' list | grep -c '/'` before importing anything.

#### Verifying after any adlist change

```bash
sudo cp /opt/pi-stack/appdata/pihole/etc/gravity.db{,.bak-$(date +%Y%m%d)}   # first
docker exec pihole pihole -g
# must still be blocked:
dig +short @<LAN_IP> doubleclick.net googleadservices.com     # 0.0.0.0
# must still resolve — false-positive sweep:
for d in google.com github.com apple.com netflix.com plex.tv youtube.com \
         googlevideo.com i.scdn.co api.spotify.com microsoft.com paypal.com \
         whatsapp.com hsbc.co.uk revolut.com stripe.com slack.com zoom.us \
         dropbox.com steampowered.com bbc.co.uk booking.com duckdns.org pi.hole; do
  a=$(dig +short @<LAN_IP> "$d" | grep -v '^$' | tail -1)
  [ "$a" = "0.0.0.0" ] && echo "FALSE POSITIVE: $d"
done
```

#### Domain count is not the performance cost

Measured on this box after the change: blocked lookup **3.1 ms mean / 4 ms max**,
`pihole-FTL` RSS **61 MB** with 1.17M domains, 913 MB of 3,795 MB RAM in use.
FTL holds gravity in an indexed SQLite table, so lookup is O(log n) — going from
1.1M to 3M domains would cost single-digit MB and no measurable latency.

⚠ **So "trim the lists for speed" is the wrong reason to trim.** The real costs
are **false positives**, rebuild time, and maintenance surface. Judge a list by
its *unique* contribution and whether its upstream is alive — never by size.
Note the net effect here: 16 lists → 9, but unique domains went **up** (1.12M →
1.17M), because what was removed was redundant and what was added was not.

#### Why the Pi cannot stop DNS bypass, only discourage it

```
default via <ROUTER_IP> dev eth0     ← the ROUTER is the gateway, not this Pi
```

**This Pi is a leaf node.** A device sending DNS to `8.8.8.8` sends it to the
router; the packet never traverses this box. Therefore:

⚠ **The universal advice — an nftables/iptables `REDIRECT` of port 53 to
Pi-hole — is a NO-OP on this topology.** The rule loads, `nft list ruleset`
looks correct, and it catches nothing, because there is no traffic to catch.
Do not add it and do not believe it works. (`net.ipv4.ip_forward = 1` is
Docker's doing, not evidence that this box routes LAN traffic.)

Enforcement is possible only at the router — one rule dropping outbound `:53`
and `:853` from everything except <LAN_IP>. That is out of scope by choice.

#### What is done instead: remove the bootstrap

A client that wants to speak DoH to `dns.google` must first *resolve*
`dns.google` — through Pi-hole. Answer NXDOMAIN and the upgrade never happens.

| Layer | Where | Covers |
|---|---|---|
| 18 explicit `server=/domain/` lines | `FTLCONF_misc_dnsmasq_lines` in `docker-compose.yml` | the major providers: Google, Cloudflare, Quad9, NextDNS, AdGuard, OpenDNS DoH, CleanBrowsing, ControlD, Apple Private Relay, RFC 9462 DDR |
| `dibdot/DoH-IP-blocklists` adlist | `gravity.db`, id 22 | the ~1,400-domain long tail of public DoH servers |
| Firefox canary | **native to Pi-hole v6**, nothing to configure | Firefox auto-DoH |

`server=/domain/` with no address is the dnsmasq idiom for "answer NXDOMAIN, do
not forward", and domain matching covers subdomains — `cloudflare-dns.com` also
catches `chrome.`, `mozilla.`, `security.`, `family.`.

**Deliberately not a blocklist entry.** Gravity answers `NOERROR` + `0.0.0.0`;
some clients read that as a reachable host worth trying. NXDOMAIN is
unambiguous. This is also why the Firefox canary cannot be a blocklist entry:
`use-application-dns.net` must return **NXDOMAIN specifically** or Firefox keeps
DoH on. Verified 2026-08-26 — the canary returns NXDOMAIN while `doubleclick.net`
returns `NOERROR` + `0.0.0.0`, which is the difference in one command.

Measured 2026-08-26, random 40-domain sample of the DoH list: **7/40 blocked
before, 40/40 after.**

```bash
# verify the block
for d in dns.google chrome.cloudflare-dns.com one.one.one.one dns.nextdns.io \
         dns.adguard.com mask.icloud.com use-application-dns.net; do
  printf '%-30s %s\n' "$d" \
    "$(docker exec pihole dig "$d" @127.0.0.1 | grep -oE 'status: [A-Z]+')"
done                                      # all must say NXDOMAIN

# regression: these must still resolve normally
docker exec pihole dig +short opendns.com google.com @127.0.0.1
```

⚠ **Never add `opendns.com` to that list** — `208.67.222.222` is this Pi's own
upstream (`PIHOLE_UPSTREAMS`). Only the `doh.*` hostnames are blocked. Blocking
a *hostname* never affects an upstream configured by *IP*, which is also why
Caddy's ACME `resolvers 1.1.1.1 9.9.9.9` (§7.4) are unaffected — do not conflate
the hostname `one.one.one.one` with the address `1.1.1.1`.

#### What this does NOT catch — do not overestimate it

- A device with a **hardcoded resolver IP** and no hostname to look up.
- Android "Private DNS" pointed at an IP, or any DoH client with baked-in
  addresses.
- Any VPN.

It stops the **opportunistic** case — a browser or OS silently upgrading itself
— and raises the bar on a lazy manual bypass. **It cannot stop a determined
one, and nothing configured on this Pi ever will.**

**Accepted trade-offs, 2026-08-26:** Chrome's "Secure DNS" toggle stops working,
and iCloud Private Relay and NextDNS stop working, for everyone in the house.
To undo, delete the `FTLCONF_misc_dnsmasq_lines` key and
`docker compose up -d pihole`; disable adlist 22 and re-run `pihole -g`.

**To detect an actual bypass** (not implemented): the Pi can see the LAN
neighbour table (`ip neigh show dev eth0`) and Pi-hole's own client history. A
device present on the LAN that has made zero DNS queries in N hours is either
bypassing or is a dumb device. That comparison is the only thing that would
catch a deliberate bypass from this box.

---

### 7.7 Tailscale (remote access)

Installed 2026-08-26. Solves the thing CGNAT makes otherwise impossible: there
is no inbound path to this box and no port that can be forwarded.

| | |
|---|---|
| Version | 1.102.3, official Debian trixie repo, arm64 |
| This Pi | `<PI_TAILNET_IP>` (plus an IPv6 in `fd7a:115c:a1e0::/48`), hostname from `LOCAL_HOSTNAME` |
| Mode | subnet router for `<LAN_SUBNET>`, **not** an exit node |
| Install | **native, not a container** — the container needs `NET_ADMIN` + host networking anyway, and its state handling is fiddlier for no gain |

```bash
tailscale status          # peers, and direct-vs-DERP per peer
tailscale ip -4           # this node's tailnet address
systemctl status tailscaled
```

#### What was changed on the host

| Change | File | Why |
|---|---|---|
| `iifname "tailscale0" accept` in `input` **and** `forward` | `nftables.conf` | see below |
| `net.ipv4.ip_forward = 1`, `net.ipv6.conf.all.forwarding = 1` | `/etc/sysctl.d/99-tailscale.conf` | forwarding was runtime-only, set incidentally by Docker — not a guarantee it is set before `tailscaled` starts |
| `ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off` | `/etc/systemd/system/ethtool-udp-gro.service` | without it the kernel cannot coalesce forwarded UDP and WireGuard throughput through this box is capped. **ethtool settings do not survive reboot**, hence the unit |

⚠ **The firewall rule matches an interface name, which `nftables.conf` otherwise
forbids — this is the one deliberate exception.** Tailnet peers carry
`100.64.0.0/10` addresses: the *same* CGNAT range the ISP router queries us from.
Accepting that range by source address would re-admit the ~230k junk DNS queries
a day that rule exists to drop. Interface matching is the only way to separate
them, and `tailscale0` is named by tailscaled itself so it cannot drift the way
`wlan0` or the compose-generated bridge name can.

⚠ **`--accept-dns=false` on the Pi, deliberately.** This host resolves via
`nameserver 127.0.0.1` (Pi-hole). Letting tailscaled rewrite `/etc/resolv.conf`
to `100.100.100.100` would point the host at the tailnet resolver, which points
back at this Pi — a loop.

**Port 41641 is deliberately NOT opened.** Under CGNAT with zero IPv6 (verified:
no global v6 address, no v6 route off-net) no unsolicited inbound packet can
arrive, so the rule would be dead weight. NAT traversal still works — replies
match the existing `ct state established,related` accept. Add it if the ISP ever
provides a real address or IPv6; direct paths get faster.

#### Settings that live ONLY in the admin console

⚠ **These are invisible to this repo and survive no rebuild.** If the Pi is ever
reprovisioned, they must be redone by hand at
<https://login.tailscale.com/admin/machines>.

| Setting | Value | Consequence if missed |
|---|---|---|
| Subnet route `<LAN_SUBNET>` | **approved** | An advertised-but-unapproved route is **silently ignored** — no error anywhere. The classic hour-long debug. Now also covered by `autoApprovers` in the policy file, so a reprovisioned Pi approves itself. |
| Key expiry on `raspberrypi` | **disabled** | Default ~6 months, after which the Pi drops off the tailnet and there is no remote way back in. Non-negotiable for a server. |
| DNS → Nameservers | `<PI_TAILNET_IP>` + *Override DNS servers* | Without it the DuckDNS names do not resolve remotely and there is no ad-blocking off-LAN |
| Policy file (ACLs) | paste `tailscale-policy.hujson` | Default policy is **allow-all**. See §7.7.3. The repo copy and the console drift silently — the console is what enforces. |
| Device tags | `tag:mobile` / `tag:desktop` | An untagged new device lands in the **admin tier** with full LAN access. Tag it at join time (§7.7.2). |

**The DNS choice is a trade-off.** *Override DNS servers* gives Pi-hole filtering
everywhere, but if this Pi is unreachable those devices lose DNS outright rather
than failing over. The alternative is Split DNS (*Restrict to domain*
`duckdns.org`) — own hostnames via Pi-hole, everything else via the device's
normal resolver. Switching is console-only; nothing on the Pi changes.

#### Why the existing certificate keeps working remotely

Nothing about Caddy, the Caddyfile, or the wildcard cert needed to change:

```
remote device ─ tailnet ─► Pi (<PI_TAILNET_IP>) ─ subnet route ─► <LAN_SUBNET>
                            └─ Pi-hole answers DNS for the tailnet
```

Pi-hole resolves `*.${CADDY_DOMAIN}` to `<LAN_IP>`, which is
reachable over the subnet route — the same answer it gives on the LAN. One cert,
one site block, no split-horizon workaround.

⚠ **`https://<PI_TAILNET_IP>/` fails, and that is correct.** Caddy serves only the
DuckDNS hostname, so a request by bare IP matches no site block and the
connection is closed. Always test by hostname:

```bash
curl --resolve files.${CADDY_DOMAIN}:443:<PI_TAILNET_IP> \
     https://files.${CADDY_DOMAIN}/
```

#### Verification

```bash
tailscale status                                   # expect "active; direct ..." per peer
dig +short @<PI_TAILNET_IP> doubleclick.net          # 0.0.0.0  -> firewall + Pi-hole OK
dig +short @<PI_TAILNET_IP> google.com               # resolves -> upstream OK
ssh pi@<LAN_IP> 'tailscale status --json | grep -A3 PrimaryRoutes'   # route live
```

Verified 2026-08-26 end-to-end: DNS over the tunnel, all six published ports
reachable, valid Let's Encrypt wildcard served over the tunnel
(`ssl_verify_result=0`), 9/9 containers healthy, 0 failed units.

**If Tailscale breaks, nothing on the LAN is affected.** It is additive: the
firewall rules only *add* accepts, and `systemctl stop tailscaled` returns the
box to its previous state. That is the rollback.

#### 7.7.1 Tailnet lock

Enabled 2026-08-27. Without it, whoever controls the coordination server can
insert a node into this tailnet and it is trusted immediately. With it, a new
node is unreachable until an existing trusted node signs it.

| | |
|---|---|
| Tailnet | `<your-tailnet>`, MagicDNS suffix `<tailXXXXXX>.ts.net` |
| Trusted signing key — workstation | `tlpub:<64 hex chars>` — from `tailscale lock status` |
| Trusted signing key — Pi | `tlpub:<64 hex chars>` |
| Disablement secrets | **1**, held in the owner's password manager |

```bash
tailscale lock status     # ENABLED + this node's signature + the trusted key list
tailscale lock log        # every signing event, append-only
```

⚠ **The disablement secret is deliberately NOT in this repo, not in `.env`, and
not on the Pi.** Tailscale prints it exactly once, at `lock init`, and will never
show it again. It is the only way to turn lock off if both signing nodes are
lost. A copy on the Pi would defeat the point — the Pi is one of the two things
it exists to survive.

⚠ **The quorum is 2.** Lose the Mac *and* the Pi *and* the secret and this
tailnet can never accept another node. Signing a third durable node is the fix;
until then, the password-manager entry is load-bearing.

⚠ **Lock signs node *additions* only. It revokes nothing.** The Pi's disabled key
expiry (deliberate, §7.7 console table) is unaffected by it, and so is any key
already trusted. Do not treat lock as a substitute for rotating a leaked key.

Two behaviours worth knowing before you touch it:

- `tailscale lock init` is **two-step** — it prints the command back at you and
  does nothing at all without `--confirm`. The first run is a dry run, not a
  failure.
- Enabling it briefly raised *"Tailscale can't reach the configured DNS servers"*
  on the Mac while the netmap re-synced. It cleared on its own; Pi-hole was never
  actually down. **Do not chase that warning for the first minute after a lock
  change** — verify with `dig @<PI_TAILNET_IP>` before believing it.

#### 7.7.2 Adding a device (iPhone, iPad, Windows)

Two things now gate a new device, and **each one fails in a way that looks like
broken networking**: it must be signed (lock), and it must be tagged (ACLs).

1. Install Tailscale on the device and log in as normal. It appears in
   `tailscale status` and in the admin console — and can talk to nothing.
2. **Sign it.** On the Mac (or the Pi):

   ```bash
   # the node key and the device's OWN tailnet-lock key, from the API:
   curl -s -u "$(cat tailscale-apikey.txt):" \
     "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all" \
     | jq -r '.devices[] | select(.tailnetLockError=="no signature")
              | "\(.name)\n  \(.nodeKey)\n  \(.tailnetLockKey)"'

   tailscale lock sign nodekey:<node key> nlpub:<that device's tailnetLockKey>
   ```

   ⚠ **Pass the second argument — the device's own lock key — as a rotation
   key.** It lets the device re-sign itself when its node key rotates. Without
   it, a routine rotation silently strands the device until you are next sitting
   at a signing node, which for a phone away from home is exactly when you can't.
   This is what the admin console's own flow does.

   ⚠ `tailscale lock status` on the Mac shows the trusted-key list but **does not
   list nodes awaiting signature** — query the API as above, or you will conclude
   there is nothing to sign.

3. **Tag it**, in the console under *Machines → ⋯ → Edit ACL tags*:
   `tag:mobile` for iPhone/iPad, `tag:desktop` for Windows.
4. Verify from the device: a DuckDNS name over https, and Plex.

⚠ **Step 3 is not optional and its failure mode is silent-but-permissive.** An
untagged device is owned by the user, matches `autogroup:member`, and therefore
lands in the **admin tier** — full access to the Pi on every port and to the
entire `<LAN_SUBNET>` behind the subnet router. It will work perfectly, which
is exactly why nobody notices.

⚠ **Tagging transfers ownership from the user to the tag.** Expected side
effects: the device stops matching `autogroup:member`, and its key expiry is
governed by the tag rather than the user. Both are intended here.

⚠⚠ **NEVER tag the Mac or the Pi.** Untagged *is* the admin tier — every admin
grant has `autogroup:member` as its **source**. Tag the Mac and it stops matching,
instantly losing the Pi, the LAN and both phones, because no grant names a tag as
a source except the client tiers. It is recoverable (edit the policy in the
console, which lives outside the tailnet) but it is a self-inflicted outage.
Tags exist to **demote** new devices below these two, never to classify them.
Same reasoning applies to the Pi, with the extra hazard that tagging it needs a
re-auth that can strand the box over SSH.

⚠ **iOS devices register their hostname as `localhost`**, so two of them show as
identical entries in `tailscale status` and only the MagicDNS name tells them
apart. Rename on join — this changes the MagicDNS name, so do it before anything
bookmarks the old one:

```bash
curl -s -X POST -u "$(cat tailscale-apikey.txt):" -H "Content-Type: application/json" \
  -d '{"name":"iphone"}' https://api.tailscale.com/api/v2/device/<id>/name
```

Tailscale derives the machine name from the device's own hostname, so phones
and tablets join under whatever iOS invented that week. Rename them once, here,
so the ACL
rules keep matching after the OS changes its mind about the hostname.

⚠ **iOS and iPadOS cannot sign.** Signing is a CLI operation, so those devices
must be signed *from* the Mac or the Pi. Plan accordingly if you are away from
both — a phone added on holiday stays useless until you can reach a signer.

#### 7.7.3 Access control (ACLs)

Policy file: **`tailscale-policy.hujson`** in this repo → paste into
<https://login.tailscale.com/admin/acls/file>. Before 2026-08-27 the tailnet ran
the stock **allow-all** policy, which was defensible at two devices and stops
being defensible the moment a phone or a Windows box joins.

| Tier | Members | Gets |
|---|---|---|
| Admin (untagged) | Mac, Pi | Everything on the Pi, the whole LAN, **and the tagged client devices** |
| `tag:mobile` | iPhone, iPad | 53, 80, 443, 32400, 445, icmp — **on the Pi only** |
| `tag:desktop` | Windows | the above, plus 139 — **on the Pi only** |

⚠ **The admin → client grant is deliberately ONE-directional.** The Mac can reach
the iPad (Taildrop, ping, screen sharing); the iPad cannot reach the Mac. A test
in the policy asserts exactly that, so making it symmetric by accident fails the
save. Added 2026-08-27, because **tagging a device removes it from
`autogroup:member`** and it therefore disappeared from the Mac's netmap entirely
— `tailscale status` stopped listing it. That looks like a broken device, not a
policy decision.

**Restricting the client tiers to :443 costs nothing**, which is what makes this
policy cheap to live with: Caddy already fronts every admin UI on 443
(§7.4). A phone reaching `pihole.${CADDY_DOMAIN}` never needed 8080. Break-glass
is the Mac's job, and it now costs even less than it did: the container UIs are
loopback-bound (`BIND_ADDR`), so break-glass means an ssh tunnel (§2.8) rather
than a raw port over the tailnet. Only `8080` and `8581` remain directly
reachable, from `ADMIN_SOURCES` or the tailnet. Plex is the one exception — unproxied by design, hence `tcp:32400`.

⚠ **The Pi has two addresses and every rule must name BOTH.** `<PI_TAILNET_IP>`
and `<LAN_IP>` are the same host, and `<LAN_IP>` is inside the
`<LAN_SUBNET>` subnet route. A rule that locks down the tailnet address while
granting the LAN range is **worth nothing** — the client just connects to the LAN
IP instead. Hence the `pi-ts` / `pi-lan` host pair, and hence the client tiers
get no LAN grant at all.

⚠ **Grants are allow-only; there is no deny.** A broader rule always wins. Never
"fix" a connectivity problem by adding a wide grant on top — widen the specific
tier instead, or you have quietly restored allow-all.

The real prize is lateral movement, not port hygiene. A compromised phone or a
malware-hosting Windows box is the likeliest incident here, and this policy keeps
either one off the router admin page, off other people's machines, and off SSH.

The `tests` block encodes that: the console **refuses to save** a policy where
`tag:mobile` can reach `:22`, the raw Arcane port, the router, or another LAN
host. Edit the grants carelessly and the save fails rather than the security
quietly evaporating.

```bash
# after any policy change, from a client device:
dig +short @<PI_TAILNET_IP> google.com                 # 53 still open
curl -sI https://files.${CADDY_DOMAIN}/     # 443 through Caddy
nc -zv <PI_TAILNET_IP> 22                              # MUST fail from mobile/desktop

# validate + apply from the Mac, without the console:
curl -s -u "$(cat tailscale-apikey.txt):" -H "Content-Type: application/hujson" \
  --data-binary @tailscale-policy.hujson \
  https://api.tailscale.com/api/v2/tailnet/-/acl/validate      # {} == clean
curl -s -X POST -u "$(cat tailscale-apikey.txt):" -H "Content-Type: application/hujson" \
  --data-binary @tailscale-policy.hujson \
  https://api.tailscale.com/api/v2/tailnet/-/acl               # hujson comments survive
```

⚠⚠ **NEVER test tailnet reachability with a bare `ping` on this network — check
the route first.**

```bash
route -n get <CLIENT_TAILNET_IP>   # interface MUST be utun*, not en0
```

Tailnet addresses are `100.64.0.0/10`, the **same CGNAT range the ISP uses**
(§7.7, and the reason the firewall matches by interface name). If a tailnet IP is
not in the routing table — which is exactly what happens when the ACL denies you
that peer — macOS sends the packet out `en0` to the default gateway, and *the
ISP's CGNAT infrastructure answers it*. Measured on one such link: a denied iPad "replied" in
**15 ms with 0% loss**. Over the real tunnel it was 100% loss; once permitted, it
was 260 ms. **The fast, healthy-looking reply was the false one.**

⚠ `192.0.2.50` in the test block is a **placeholder for "some other LAN
host"**, not a real device. If DHCP ever assigns it to something real the test
still asserts the correct thing; if you replace it, keep an address that is not
the Pi.

---

### 7.8 Observability (Dozzle, Diun, Beszel)

Added 2026-08-26. Three services that answer three different questions the stack
previously had no answer to: *what is a container saying*, *is an image out of
date*, *what did resource use look like an hour ago*. Combined cost including
the native agent is **~42 MB RSS**, on a box with 2.7 Gi available.

| Service | Answers | URL | Port | Auth |
|---|---|---|---|---|
| Dozzle | live + historical container logs | `https://logs.${CADDY_DOMAIN}` | 8085 | simple auth, `admin` / see `.env` → `DOZZLE_PASSWORD` |
| Diun | "is a newer image published?" | none — log output only | none | n/a |
| Beszel | CPU/mem/disk/net history + charts | `https://metrics.${CADDY_DOMAIN}` | 8086 | own account, created at first run |

Beszel has two parts — the `beszel` hub container and the native
`beszel-agent.service` collector; see below. Measured footprint: Dozzle 11 MB,
Diun 15 MB, Beszel hub 10 MB, native agent 6 MB.

#### Dozzle

Replaces `docker logs` for anything involving more than one container at a time —
it tails all twelve simultaneously and searches across them, which is the actual
use case when something breaks at 2am and you do not yet know which service is at
fault.

⚠ **A Dozzle session is equivalent to reading `.env`.** Container logs contain
environment dumps, tokens in stack traces, and full file paths. Hence:

- `DOZZLE_AUTH_PROVIDER: simple` — a login, not an open page. Do not remove it.
- `DOZZLE_ENABLE_ACTIONS: "false"` — no start/stop/restart buttons from the log
  viewer. Arcane already does container management, behind its own password;
  there is no reason for a second, weaker path to the same power.
- **No socket mount.** Dozzle reaches the API through `socket-proxy-ro`
  (`DOCKER_HOST=tcp://socket-proxy-ro:2375`), which allows `CONTAINERS`,
  `IMAGES`, `EVENTS`, `PING`, `VERSION`, `INFO` and — the part that matters —
  refuses `POST` and `EXEC`. So Dozzle genuinely *cannot* write, which a `:ro`
  socket mount could never have guaranteed. It is still not a confidentiality
  boundary: reading container metadata reveals every container's full
  environment, which is why the login above stays.
- **Never forward 8085.** It is also loopback-bound (`BIND_ADDR`) and behind
  `(adminonly)`, so this is now three layers deep — keep it that way.

The password was generated on the Pi and never printed to a terminal. It lives in
`/opt/pi-stack/.env` (mode 600) as `DOZZLE_PASSWORD`; the bcrypt hash of it lives
in `appdata/dozzle/users.yml`. To rotate, regenerate both — the regeneration
command is in a comment beside the variable in `.env`.

`https://logs.…` answering **307** is correct: that is the redirect to the login
form, i.e. proof auth is on. A 200 there would be the thing to worry about.

#### Diun

The deliberate anti-Watchtower. It checks whether a newer image has been
published and **writes a line to its log. It does not pull, and it does not
restart anything.** That is the entire point: this box has no automated backup
before an image change, no health gate, and no rollback, so an unattended update
is a coin flip that can take DNS down for the house. Diun turns "am I behind?"
into a question with an answer, while leaving the decision — and the timing, and
the `quarterly-update.sh` run that does it safely — to a human.

⚠ **Do not add a notifier that depends on this Pi.** `No notifier available` in
the log is expected and fine; the log *is* the notification, read via Dozzle.

Schedule is `0 6 * * *` (daily, 06:00). `DIUN_WATCH_FIRSTCHECKNOTIF: "false"`
suppresses the twelve "new image found" lines on first start — those are Diun
recording a baseline, not reporting updates.

**Digest pins are watched correctly.** Every image in `docker-compose.yml` is
pinned `tag@sha256:…`; Diun follows the *tag* and reports when the digest behind
it moves, which is exactly what is wanted. Verified at first run: 11 images
analyzed, all resolved.

⚠ **Caddy is excluded, via `labels: diun.enable: "false"`.** `pi-stack/caddy` is
built locally and exists on no registry, so Diun resolved it to
`docker.io/pi-stack/caddy` and failed with *"requested access to the resource is
denied"* — a guaranteed daily failure that would train everyone to ignore Diun's
output entirely. Caddy's upstream version is tracked by `CADDY_VERSION` in the
build args and bumped by `quarterly-update.sh`. Confirmed after the fix:
`failed=0`, `unchanged=11`.

⚠ **Diun's baseline is "what the tag pointed at when Diun first saw it", not
"what you have pinned."** It compares each remote tag against its own database,
so an image that was *already* behind at install time is recorded as the baseline
and never reported. Confirmed at install: Arcane's pin is
`sha256:2425b5a…` while `ghcr.io/getarcaneapp/manager:latest` already resolved to
`sha256:f10f95d…`, and the second run still said `unchanged=11`. Diun tells you
about drift **from today forward**; for "am I behind right now", compare the two
digests directly:

```bash
# what did the last check find?
sudo docker logs diun 2>&1 | grep -E "Jobs completed|New image|Image update"

# what Diun currently believes each tag resolves to (its DB, not a live check)
sudo docker exec diun diun image list

# the one-off "is my pin stale?" check Diun does NOT do for you
sudo docker inspect --format '{{.Name}} {{.Image}}' $(sudo docker ps -q)

# force a check now instead of waiting for 06:00 — Diun runs one on startup
sudo docker restart diun
```

#### Beszel

The `beszel` container stores history and draws charts. Since 2026-08-27 the
collector is a pinned host binary under `beszel-agent.service`; running it on
the host gives it native `smartctl` without a custom image or libc bind mounts.

⚠ **The agent could not be written ahead of time** — its `KEY` and `TOKEN` are
issued by the hub when a system is added in its UI, so the hub's first run had to
happen by hand first. Recorded here because a rebuild hits the same wall:

1. Open the hub and create the admin account. Beszel has **no default login —
   the first visitor becomes the owner**, so do this before anyone else on the
   LAN gets there.
2. *Add System* → the UI issues a `KEY` (public ed25519) and a `TOKEN`.
3. `BESZEL_KEY` and `BESZEL_TOKEN` go in `.env`. The key is public; the token
   authorises registration and is secret. Re-run `sudo ./provision.sh
   beszelagent` after rotating either value.

**The agent dials out; it does not listen.** Because `HUB_URL` and `TOKEN` are
set, the agent opens a WebSocket to the hub. Verified: `ss -lntp` shows **nothing
on 45876**. The alternative mode (hub polls agent) would need a port bound to
`0.0.0.0`, because the hub arrives from the docker bridge gateway rather than
loopback — an extra LAN listener for no gain. Do not add `LISTEN` back.
`DISABLE_SSH=true` also prevents the agent from opening that listener as a
fallback while the hub is restarting. Consequence: nftables needs no rule for
Beszel at all.

The dedicated `beszel` user belongs to `docker` (container metrics) and `disk`
(read access to `/dev/sda`). The unit grants only the two capabilities Beszel's
SMART integration requires and restricts device access to `/dev/sda`. This is
still privileged: Docker-socket membership is effectively host-root access.

`EXTRA_FILESYSTEMS=/mnt/rpidata` makes the HDD appear beside the SD root.
`SMART_DEVICES=/dev/sda:sat` handles the USB-SATA bridge explicitly. The bridge
returns smartctl status bit 2 because one ATA status opcode is unsupported, but
Beszel 0.18.8 parses the valid attribute payload anyway. Verified in the hub DB:
model string, state `PASSED`, temperature and 17 attributes.

```bash
sudo journalctl -u beszel-agent -n 50 | grep -E "Detected disk|SMART|WebSocket"
# must list BOTH sda1 (mount=/mnt/rpidata) and mmcblk0p2 (root=true)
sudo sqlite3 /opt/pi-stack/appdata/beszel/data.db \
  'select name,model,state,temp,updated from smart_devices;'
```

Only the hub is proxied by Caddy. The agent talks to it over the host network,
so there is nothing to reverse-proxy for it.

⚠ **Update hub and agent in the same run.** They are versioned together upstream
and share a protocol; a hub newer than its agent is the one pairing here that can
silently stop recording rather than fail loudly. The hub digest and native
`beszel-agent-version` pin are both managed by `quarterly-update.sh`, including
checksum verification, health gating and binary rollback.

#### Verification after any change to these three

```bash
# routes (from the Mac; expect 307 for logs, 200 for metrics)
for s in logs metrics; do
  curl -s -o /dev/null --resolve "$s.${CADDY_DOMAIN}:443:<LAN_IP>" \
    -w "$s %{http_code} verify=%{ssl_verify_result}\n" \
    "https://$s.${CADDY_DOMAIN}/"
done

# Diun must report failed=0 — a nonzero count means an image it cannot resolve
sudo docker logs diun 2>&1 | grep "Jobs completed" | tail -1

# Beszel agent must be active, see both disks, and must NOT be listening
systemctl status beszel-agent
sudo journalctl -u beszel-agent -n 50 | grep -E "Detected disk|SMART|WebSocket"
sudo ss -lntp | grep 45876 || echo "no listener, as intended"

# footprint
sudo docker stats --no-stream --format "{{.Name}}\t{{.MemUsage}}" \
  dozzle diun beszel
systemctl show beszel-agent -p MemoryCurrent
```

---

### 7.9 Docker socket proxies

**No application container on this box mounts `/var/run/docker.sock`.** The two
proxy containers necessarily mount it read-only. Arcane, Dozzle and Diun reach
the API over TCP through a
[`docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy)
instead. There are two instances because they want different things:

| | `socket-proxy-ro` | `socket-proxy-rw` |
|---|---|---|
| Used by | Dozzle, Diun | Arcane |
| Allowed | `CONTAINERS` `IMAGES` `EVENTS` `PING` `VERSION` `INFO` | the above plus `NETWORKS` `VOLUMES` `DISTRIBUTION` |
| `POST` | **0** — cannot change anything | `${SOCKET_PROXY_POST:-1}` |
| `EXEC` | **0** | **0** |
| Everything else | 0 | 0 |

**Why this is not just tidiness.** The Docker API is not authorisation-aware:
there is one socket, and it serves reads and writes alike. Mounting it `:ro`
sets a *file* permission on the socket node and changes nothing about what the
API will do — the old note in §7.5 said exactly this. The only place a
read/write distinction can be enforced is in front of the API, which is what the
proxy is. `POST: 0` is what makes "Dozzle is read-only" a fact rather than an
intention.

**`EXEC: 0` on both, including the read-write one.** Upstream's own example
enables it. It is refused here: `EXEC` is a one-line path to a shell inside any
container, which on this box includes Pi-hole and Caddy. Arcane's terminal
feature stops working; that is the intended trade.

The pinned `0.3.0` image's generic `CONTAINERS` ACL also matches
`POST /containers/<id>/exec`, before its `EXEC` ACL is evaluated. Both proxies
therefore mount `config/docker-socket-proxy-haproxy.cfg`, an upstream-derived
template with an earlier unconditional deny for exec creation. Keep that mount:
setting `EXEC=0` alone does **not** block this path in `0.3.0`. The image also
renders `haproxy.cfg` beside its template at startup, so its root filesystem
cannot be `read_only`; the socket and patched template mounts remain read-only.

⚠ **`docker-socket-proxy` speaks plain HTTP with no authentication.** Its only
protection is network reachability. The read-only and read-write planes use
separate `internal: true` networks: `socketproxy_ro` contains only Dozzle, Diun
and `socket-proxy-ro`; `socketproxy_rw` contains only Arcane and
`socket-proxy-rw`. Sharing one network would let a compromised read-only
consumer bypass its proxy and call the read-write one directly. Neither proxy
publishes a port. Never add one — publishing `2375` hands root on the host to
anything that can reach it.

⚠ **Both socket-proxy networks are `internal: true`, with no outbound route.**
Consumers list `default` as well as their proxy network explicitly; naming any
network removes a service from `default` unless it is listed, and losing it
would leave Arcane unable to reach Caddy or the internet.

To make Arcane a read-only dashboard, set `SOCKET_PROXY_POST=0` in `.env` and
recreate it. The buttons stay in the UI and fail — Arcane has no way to hide
them (§7.5).

Verify nothing regressed:

```bash
# nothing should mount the socket except the two proxies
sudo docker ps --format '{{.Names}}' | while read -r c; do
  sudo docker inspect "$c" --format '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' \
    | grep docker.sock
done

# neither proxy publishes a port
sudo docker compose -f /opt/pi-stack/docker-compose.yml ps socket-proxy-ro socket-proxy-rw

# both trust-plane networks are internal
sudo docker network inspect pi-stack_socketproxy_ro pi-stack_socketproxy_rw \
  --format '{{.Name}} {{.Internal}}'   # both true
```

---

## 8. Update policy

- **Debian stable and security updates** — `unattended-upgrades`, continuously;
  third-party repositories are excluded.
- **Rest of the OS and vendor repositories** — weekly,
  `apt-get --with-new-pkgs upgrade`. This includes installed packages from the
  Docker, Tailscale and Raspberry Pi repositories; it runs after the full backup
  and before the scheduled reboot. Do not add a separate monthly updater.
- **Images + `apt full-upgrade`** — quarterly, `quarterly-update.sh`.

`maintenance.sh` **must keep `--with-new-pkgs`.** Plain `upgrade` refuses anything
pulling in a new package, and kernel meta-packages always do
(`linux-image-rpi-v8` → `linux-image-6.18.39-rpi-v8`), so it pins the kernel
forever. `full-upgrade` installs the kernel but may *remove* packages — not a 4 am
unattended decision. `--with-new-pkgs` adds dependencies, removes nothing.

The quarterly job undoes itself:

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

Run early: `sudo systemctl start pi-quarterly-update.service`. It runs at 01:00 so
a kernel it installs takes effect at the 05:00 reboot that morning.

Debian **major** upgrades (13 → 14) are not automated. By hand, from a backup, on
a day you have time.

### AppArmor

The Raspberry Pi kernel has AppArmor compiled in but requires
`security=apparmor` in `/boot/firmware/cmdline.txt` to select it. After boot,
`apparmor.service` loads the host profiles and Docker automatically assigns its
generated `docker-default` profile to non-privileged containers.

```bash
cat /sys/kernel/security/lsm                    # capability,apparmor
sudo aa-status
docker inspect $(docker ps -q) --format '{{.Name}} {{.AppArmorProfile}}'
```

---

## 9. Performance

Audited 2026-08-23. Most generic "Pi tweaks" advice is already in place here or
actively wrong for this box.

| Tweak | State |
|---|---|
| zram | **already active** — 2 GB, `zstd`, priority 100, via `systemd-zram-setup@zram0` + `rpi-swap`. **Do not `apt install zram-tools`** — it fights the OS's own setup |
| swap on SD | none. Only `/dev/zram0` is in `/proc/swaps`. `/var/swap` exists but is zram's *writeback* device on loop0. Writeback so far: **0 bytes** |
| `/tmp` on tmpfs | Debian 13 default, 1.9 GB. ⚠ wiped on reboot — see §7.4 |
| desktop | not installed (Lite image) |
| journal | `Storage=volatile`, lives in `/run`, never touches flash; `maintenance.sh` also vacuums to 14 d |
| power/thermal | `throttled=0x0`, SoC 64–65 °C vs an 80 °C throttle point; checked daily by `disk-guard.sh` |

Refused, with reasons:

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

- **The ISP uses CGNAT — there is no inbound connectivity, and this is not
  fixable here.** Traceroute puts the router's WAN side on RFC1918
  (`hop 2` is a `10.x.x.x` address) while the world sees a different one; the router's
  UPnP `GetExternalIPAddress` returns empty. A port forward only opens the last
  hop. No global IPv6 either. Two consequences: Transmission's peer port cannot be
  opened (**not** caused by containerising — 51413/tcp+udp are published and
  LAN-reachable, so `network_mode: host` would not help; don't suggest it again),
  and ACME HTTP-01 can never work, which is why HTTPS is DNS-01 only (§7.4).
  Fixes are upstream only: routable IPv4 from the ISP, or a VPN with port
  forwarding. Meanwhile Transmission works as a "closed" peer.
- **Watch the data drive's free space.** Backups abort below ~3.5 GB free, and
  on the setup this came from media was ~80% of the disk. `disk-guard.sh`
  warns at 95%.
- **appdata lives on the SD card**, chosen over buying an SSD. Plex's SQLite DB is
  the main wear source, which is what makes the nightly backup load-bearing. Card
  death costs at most a day. A USB SSD is still the better answer.
- **Transmission's RPC has no whitelist enforced.** Auth is on (`pi` plus
  `TRANSMISSION_PASSWORD`); `rpc-whitelist` is `192.168.*.*` but
  `rpc-whitelist-enabled` is `false`, so it is not enforced. Incidentally this is
  *why* the Caddy route works unmodified: with `rpc-host-whitelist-enabled` also
  `false`, neither the proxied Host header nor the proxy's `172.18.x` source
  address is rejected. Turn either whitelist back on and `torrents.` breaks with a
  403 — the fix is `header_up Host localhost` plus adding `172.18.*`, **not**
  disabling the RPC password.
- **The certificate depends on a third party staying alive.** DuckDNS is a free
  service run by volunteers. If it disappears, renewals stop ~60 days later and
  every HTTPS name eventually fails — the `IP:port` fallbacks are what make that
  an annoyance rather than an outage, which is the entire reason they were kept.
  `disk-guard.sh` gives ~21 days of warning.
- **Pi-hole must remain the ONLY resolver the router hands out** (§7.3). The real
  cost: **Pi-hole is a single point of failure for household DNS with no fallback
  at all.** That is deliberate — a fallback that answers *some* names is worse
  than none — and it is why Pi-hole downtime takes the internet down for everyone.
- **`cgroup_enable=memory cgroup_memory=1` is appended to
  `/boot/firmware/cmdline.txt`** (2026-08-25) — without it the Pi firmware's
  `cgroup_disable=memory` wins and Docker discards every `mem_limit` silently.
  Ordering is what makes it work: our tokens sit at the end of the line, so the
  kernel's `cgroup_enable` handler runs *after* the firmware's disable. `dmesg`
  shows both, disable then enable. ⚠ **`cmdline.txt` must stay a single line** —
  an embedded newline makes the Pi unbootable. A pristine copy is at
  `/boot/firmware/cmdline.txt.bak`; the partition is FAT32, so recovery is putting
  the SD card in any machine and renaming that file. Costs ~1% of RAM to the
  controller's page accounting. `provision.sh` re-applies it on a rebuild.
- **The firewall does not defend against your own LAN** (§6). Every private source
  is allowed by design, so any compromised device in the house reaches every
  service with nothing but a shared password in its way. Accepted trade; it is
  the reason none of these ports may ever be forwarded, firewall or not.
- **Filebrowser can reach the backups.** The whole drive is at `/srv`, so anyone
  logged into the UI can delete `<DATA_ROOT>/backup`. The price of "see the
  whole drive"; §7.1 has how to narrow it.
- **Never `chmod 777` the data drive.** It was the old workaround for Transmission
  failing to delete files, and it treated the symptom. Cause: the pre-2026 box ran
  Transmission as `debian-transmission` (uid 115/gid 123), which does not exist
  here — 109 leftover paths were owned by that ghost uid, and deleting a file
  needs write on its *parent directory*. Fixed 2026-08-23: everything is
  `1000:1000`, dirs `2775`, files `0664`. Re-run
  `sudo /opt/pi-stack/fix-permissions.sh` if it looks wrong again.
- **Paths stay `/mnt/rpidata/torrent-complete`** and are bind-mounted at the
  identical path inside containers. Renaming orphans Plex's library locations, and
  Plex cannot re-point a library without losing watch state.
- **The HDD is a spinning USB disk** — fine for media, poor for databases, which
  is why appdata is not on it. SMART clean: reallocated, pending, uncorrectable
  and CRC counts all 0.
- **`/dev/dri` is passed to Plex** on the assumption it may exist. The Pi 4 cannot
  meaningfully transcode; this is a direct-play server. If the container refuses
  to start, delete the `devices:` block.
- **Editing a live config file requires the container STOPPED** for Plex
  (`Preferences.xml`) and Transmission (`settings.json`) — both rewrite their file
  on shutdown and clobber live edits. Filebrowser's `config.yaml` does not have
  this problem; it is read-only to the app.

---

## 11. Day-to-day

```bash
cd /opt/pi-stack
docker compose ps
docker compose logs -f pihole
sudo systemctl start appdata-backup-core.service    # backup now
sudo systemctl start pi-disk-guard.service          # disk/SMART/power/TLS report now
sudo ./fix-permissions.sh                           # Transmission can't delete?
ls -lh /mnt/rpidata/backup/appdata/
```

**Deploying a change from the Mac:**

```bash
ssh pi 'mkdir -p /tmp/deploy'                       # /tmp is tmpfs, wiped on reboot
scp docker-compose.yml Caddyfile pi:/tmp/deploy/
ssh pi 'sudo install -m 644 /tmp/deploy/* /opt/pi-stack/ && \
        cd /opt/pi-stack && sudo docker compose config -q && \
        sudo docker compose up -d --build'
```

`docker compose config -q` is the validation gate — it catches an empty `.env`
value or malformed YAML *before* anything running is touched.

`sudo`/`ssh` note: `swapon`, `sysctl`, `losetup` live in `/usr/sbin`, which is not
on PATH for non-interactive ssh. Prefix `export PATH=/usr/sbin:/sbin:$PATH` or
they are "command not found".
