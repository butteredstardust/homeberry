# Services — applications

Use this runbook for user-facing applications. See [OPERATIONS.md](../OPERATIONS.md) for host, recovery, and schedule details.

## Filebrowser

FileBrowser Quantum runs from `gtstef/filebrowser:stable` (v1.5.3). It is a
hard fork of `filebrowser/filebrowser:s6`. Its database, configuration format,
and CLI differ. No v1 state is in use. `appdata/filebrowser.fb1-archived/` is
removed.

| | |
|---|---|
| Image | `gtstef/filebrowser:stable` (v1.x). **Not `beta`** — that is v2.x, which moves bolt → SQLite and renames config keys |
| Config | `filebrowser-config.yaml` → `appdata/filebrowser/config.yaml`; read at every start |
| Database | `appdata/filebrowser/database.db` — users, shares, UI-set settings |
| Runs as | uid/gid 1000, natively — no PUID/PGID variant tag needed |
| Scope | whole drive at `/srv`, one source named `RPIDATA` |

⚠ **Any logged-in Filebrowser user can remove backups.** The service can reach
the full data drive at `/srv`. Limit access before you give a user an account.

- **`FILEBROWSER_ADMIN_PASSWORD` is enforced at every start.** `.env` is the
  authoritative password source. The log reports `Resetting admin user to default username and password.` A password set in the UI reverts by the Saturday 05:00 reboot. Remove that variable from `docker-compose.yml` to manage the password in the UI.
- **The entrypoint sets `umask 0002`.** Go applies
  `createFilePermission` and `createDirectoryPermission` through the umask.
  The image default is 0022. Without the override, uploads are 0644/0755 and
  lack the group write bit that Samba masks and `fix-permissions.sh` require.
  Verified: uploads are `1000:1000` `0664`. New directories are `drwxrwsr-x`.
  A distroless future release fails at start. The quarterly job then rolls back.
- **The thumbnail cache is a 256 MB tmpfs** at `/home/filebrowser/tmp`. This
  prevents thumbnail writes on the SD card. It also keeps the cache out of
  nightly backups. `cacheDirCleanup` runs only at start and shutdown. The size
  cap is the only cache bound. Ignore the "less than the 20 GB minimum
  recommended" warning. A full cache logs a failed write. The preview remains
  available.
- UI configuration changes are stored in `database.db`, not git. Keep durable
  configuration in `filebrowser-config.yaml`.

To limit access, replace the `/srv` volume with per-folder mounts. List each
mount under `server.sources`. Quantum supports multiple named sources.

## MicroBin

MicroBin transfers text and small files between LAN hosts. It is a Rust single
binary application with SQLite storage.

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

This is upstream behavior. No setting disables it. HTTPS encrypts transport. It
does not add authorization. **Never paste secrets into it.** IDs are random
animal triplets. The listing page requires the password.

- **`MICROBIN_ADMIN_PASSWORD` defaults to the published `admin`/`m1cr0b1n`.**
  Set a different value.
- **Set `MICROBIN_PUBLIC_PATH`** to `https://paste.${CADDY_DOMAIN}`. Otherwise,
  Copy link returns a `localhost` URL that fails on another host.
- **The upload cap is 64 MB** (default 2048). `appdata` is on the SD card. The
  nightly backup archives all of it. One large upload can increase a ~70 MB
  snapshot. Use Samba for large files.
- **The image has no `curl` or `wget`.** It is a Debian trixie image with
  `bash`. The healthcheck uses HTTP over `/dev/tcp`. It accepts `401` because
  basic auth protects the index.
- Pastes expire after **24 h** by default. GC removes pastes older than **90
  days** (`MICROBIN_DEFAULT_EXPIRY`, `MICROBIN_GC_DAYS`). Set a longer expiry in
  the form when required.

## Dashboard (starbase-80)

The dashboard provides service links without requiring a remembered port.

| | |
|---|---|
| Image | `jordanroher/starbase-80` v1.6.6, digest-pinned |
| Port | **8084** on the host → 4173 in the container (nginx listens on 4173) |
| Links | `appdata/starbase80/config.json`, mounted read-only — **rendered** by `provision.sh` from `config/starbase80-config.json.tmpl`; edit the template, not the output |
| Icons | `appdata/starbase80/icons/`, 13 PNGs, ~380 KB, served locally — 12 service icons fetched once from the icon CDN, plus `homeberry.png`, the logo, copied from `assets/` on every provision run |
| Auth | **none** — it is a page of links; the firewall and "never forward" are the control |

**Four names reach the dashboard:**

| URL | Works on | Needs |
|---|---|---|
| `https://home.${CADDY_DOMAIN}/` | everything, incl. hardcoded-DNS devices | the internet's DNS |
| `http://<LAN_IP>/` | everything | nothing |
| `http://raspberrypi.local/` | macOS, iOS, Windows, Linux with Avahi | mDNS (already running) |
| `http://home.internal/` | everything, **since the router's secondary DNS was removed** | Pi-hole must be the only resolver |

⚠ **Keep Pi-hole as the router's only DNS entry.** A secondary DNS entry makes
every Pi-hole-only name fail. The symptom looks like a Pi-hole fault. DHCP must
not provide both `<LAN_IP>` and `8.8.8.8`. `dig` can query the first resolver and
succeed. macOS `getaddrinfo` can use Google's NXDOMAIN instead. Verified
2026-08-25: `pi.hole` failed identically. Setting the Mac to `<LAN_IP>` alone
made `home.internal` resolve instantly. Clients update on the next DHCP renewal
(2 h lease). On macOS, force renewal with `sudo ipconfig set en0 DHCP`.

Ad blocking is **not** affected. Verified: a blocked domain returns `0.0.0.0`
five times out of five. Pi-hole answers that query positively and quickly. Only
names that exist only in Pi-hole fail.

`FTLCONF_dns_hosts` on the pihole service declares the base record. Add
DHCP-reserved hosts to untracked `.env` as semicolon-separated
`PIHOLE_EXTRA_HOSTS` entries. ⚠ Do **not** add local DNS records in the Pi-hole
web UI or edit `pihole.toml`. Pi-hole rewrites that file. The next container
recreate removes those changes.

Conditional forwarding is disabled. `FTLCONF_dns_revServers: ""` sets
`dns.revServers` to an empty array at every Pi-hole start. Do not replace the
empty string with `"[]"`. Pi-hole v6 treats `"[]"` as no override. It can retain
an old router-forwarding entry.

**Things that will bite you:**

- **It runs a full `npm run build` at every start.** The build runs in the
  foreground before nginx binds. Measured 9.4 s on this Pi 4. `start_period` is
  60 s. It prevents a slow boot from being restarted into another build.
- **`mem_limit: 1g` is enforced** ([Constraints](../OPERATIONS.md#10-constraints), cmdline). ⚠ The limit is set when a container is
  **created**. `docker compose restart` does not apply a changed value. Use
  `docker compose up -d --force-recreate <svc>`. Verify with
  `docker inspect starbase80 --format '{{.HostConfig.Memory}}'` → `1073741824`.
- **It must run as root.** The entrypoint runs `sed -i` on root-owned 0644 files
  in `/app`. It then builds there. As uid 1000, writes fail. The container stops
  before nginx starts. It holds no secrets, has two read-only mounts, and has no
  socket.
- **Invalid JSON stops the dashboard.** The entrypoint validates `config.json`
  and exits 1. It does not serve a broken page. Other stack services continue.
  Check with `jq empty appdata/starbase80/config.json` before restart.
- **Use HTTPS names for dashboard links.** DuckDNS records are **public**. They
  resolve on hosts using Google's resolvers. Pi-hole-only names do not. Plex and
  Samba use raw IPs. Plex is unproxied. `smb://` is not HTTP.
- **Edit `config/starbase80-config.json.tmpl`, never
  `appdata/starbase80/config.json`.** The mounted file is generated.
  `provision.sh` applies `${LAN_IP}`, `${CADDY_DOMAIN}`, and `${DATA_SHARE_NAME}`.
  It overwrites a manual output-file edit on the next run. Re-render without a
  full provision run:

  ```bash
  cd /opt/pi-stack && set -a && . ./.env && set +a
  sed -e "s|\${LAN_IP}|$LAN_IP|g" -e "s|\${CADDY_DOMAIN}|$CADDY_DOMAIN|g" \
      -e "s|\${DATA_SHARE_NAME}|$DATA_SHARE_NAME|g" \
      config/starbase80-config.json.tmpl > /tmp/sb.new
  jq empty /tmp/sb.new && sudo install -o 1000 -g 1000 -m644 /tmp/sb.new \
      appdata/starbase80/config.json
  sudo docker compose restart starbase80
  ```

  A `restart` is enough. The entrypoint re-reads the file and builds at every
  start. The mount is read-only. The running container cannot rewrite it.

## Arcane

Arcane uses `ghcr.io/getarcaneapp/manager` (**not** `ofkm/arcane`), arm64, port
3552, with data in `appdata/arcane/arcane.db`.

- **It does not mount the Docker socket.** It reaches the API through
  `DOCKER_HOST=tcp://socket-proxy-rw:2375` on the `internal: true`
  `socketproxy_rw` network. **Arcane does not need `group_add` or `DOCKER_GID`.**
  A TCP socket has no file permissions. The native Beszel agent still uses
  `DOCKER_GID`. `provision.sh` therefore derives it.
- **The image is DISTROLESS.** It has no shell, wget, or curl. A curl or wget
  healthcheck cannot pass. It leaves the container unhealthy for
  `container-watchdog.sh` to restart in a loop. Use its health subcommand:
  `test: ["CMD", "./arcane", "health"]`.
- The seeded login is **`arcane` / `arcane-admin`**. The container log prints it.
  The login name is `pi`.

⚠ **Treat the Arcane login as root on the host.** `socket-proxy-rw` blocks
`EXEC` and limits the API Arcane uses. A user who can *create* a container can
create one with `/` bind-mounted. The proxy reduces risk from an Arcane bug. It
does not separate an Arcane user from the host. Set `SOCKET_PROXY_POST=0` in
`.env` to make Arcane read-only. See
[Decisions: TLS is not authorisation](../DECISIONS.md#tls-is-not-authorisation--never-forward-these-ports),
and [Docker socket proxies](auth.md#docker-socket-proxies) for the proxy itself.

⚠ **Leave all four risky jobs disabled.** `autoUpdate`, `autoHealEnabled`,
`scheduledPruneEnabled`, and `vulnerabilityScanEnabled` are false in
`arcane.db` settings. `autoUpdate` bypasses the backup, health gate, and rollback
in [Update policy](../OPERATIONS.md#8-update-policy). `autoHealEnabled` duplicates
`container-watchdog.sh` every 30 s with no 24 h budget. `scheduledPruneEnabled`
can remove an image required for rollback. Use Arcane only to inspect, start,
stop, and restart.

**The Projects page needs a mount.** Arcane scans its `projectsDirectory`
(`/app/data/projects`) on disk. It does **not** adopt running Compose projects
from `com.docker.compose.project` labels. Without the mount, a hand-deployed
stack reports 9 containers and 0 projects.

```yaml
- /opt/pi-stack:/app/data/projects/pi-stack:ro
```

Arcane logs `Discovered new project ... project=pi-stack` and reports running
9/9. `:ro` does **not** do these things:

- **Deploy / Redeploy / Stop still work** unless `SOCKET_PROXY_POST=0`. They use
  the Docker API. They do not write to the project directory. A click can restart
  the full stack, including Pi-hole. Arcane has no `redeploy_disabled` schema
  column. Its buttons cannot be disabled. **Treat the page as read-only.** Or
  set `SOCKET_PROXY_POST=0` to enforce it.
- The mount is not a privilege boundary. Arcane API access gives host-root
  capability. The socket proxy, not this mount, limits that access.

`:ro` prevents web-editor changes from diverging from the git copy.

**Known-wrong field:** the API reports `hasBuildDirective: false` although the
caddy service has `build: ./caddy`. An Arcane deploy runs plain `up -d`. A Caddy
update then silently does nothing. `quarterly-update.sh` passes `--build`.

The DB row can cache `status=unknown, 0/0` with
`status_reason = "…status pending Docker service query"`. This value is stale.
The live API resolves status correctly.
