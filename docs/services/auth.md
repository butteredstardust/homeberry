# Services — authentication and Docker access

Use this runbook for Authelia and the Docker socket proxies. See [OPERATIONS.md](../OPERATIONS.md) for host recovery and the schedule.

## Docker socket proxies

**No application container on this host mounts `/var/run/docker.sock`.** Only the two proxy containers mount it read-only. Arcane, Dozzle, and Diun use TCP to reach [`docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy). Two proxy instances enforce different API access:

| | `socket-proxy-ro` | `socket-proxy-rw` |
|---|---|---|
| Used by | Dozzle, Diun | Arcane |
| Allowed | `CONTAINERS` `IMAGES` `EVENTS` `PING` `VERSION` `INFO` | the above plus `NETWORKS` `VOLUMES` `DISTRIBUTION` |
| `POST` | **0** — cannot change anything | `${SOCKET_PROXY_POST:-1}` |
| `EXEC` | **0** | **0** |
| Everything else | 0 | 0 |

**The proxies enforce the API boundary.** The Docker API has one socket for reads and writes. A `:ro` mount sets a file permission only. It does not restrict Docker API actions. Enforce read and write access in front of the API. The proxy provides that control. `POST: 0` makes Dozzle read-only.

**Set `EXEC: 0` on both proxies, including the read-write proxy.** The upstream example enables it. `EXEC` can open a shell in any container, including Pi-hole and Caddy. Arcane cannot use its terminal feature. This is intentional.

The pinned `0.3.0` image matches `POST /containers/<id>/exec` through its generic `CONTAINERS` ACL before it checks `EXEC`. Both proxies mount `config/docker-socket-proxy-haproxy.cfg`. This upstream-derived template denies exec creation first. Keep the mount. In `0.3.0`, `EXEC=0` alone does **not** block this request. The image renders `haproxy.cfg` beside its template at start. Its root filesystem cannot be `read_only`. The socket and patched template mounts stay read-only.

⚠ **`docker-socket-proxy` uses unauthenticated plain HTTP.** Network reachability is its only protection. The read-only and read-write planes use separate `internal: true` networks. `socketproxy_ro` contains Dozzle, Diun, and `socket-proxy-ro`. `socketproxy_rw` contains Arcane and `socket-proxy-rw`. A compromised read-only consumer could call the read-write proxy on a shared network. Neither proxy publishes a port. Never publish `2375`. Any reachable client then has host-root access.

⚠ **Both socket-proxy networks are `internal: true` and have no outbound route.** Consumers explicitly list `default` and their proxy network. Naming networks removes a service from `default` unless it is listed. Without `default`, Arcane cannot reach Caddy or the internet.

To make Arcane read-only, set `SOCKET_PROXY_POST=0` in `.env`. Recreate it. The UI buttons remain and fail. Arcane cannot hide them ([Arcane](apps.md#arcane)).

Verify the proxy controls:

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

## Authelia (forward-auth and TOTP)

Caddy sends each admin vhost through Authelia after the `(adminonly)` source-IP check. The controls answer different questions. Each `route` uses this fixed order:

```
client → ADMIN_SOURCES allowlist → Authelia password + TOTP → backend login
```

| | |
|---|---|
| Image | `authelia/authelia:4.39`, digest-pinned to v4.39.20 linux/arm64 |
| Portal | `https://auth.${CADDY_DOMAIN}/` |
| Break-glass | `127.0.0.1:8087` → container `:9091`; 9091 on the host remains Transmission |
| User backend | `appdata/authelia/users_database.yml`, Argon2id |
| State | `appdata/authelia/db.sqlite3` — SQLite, including TOTP enrolments |
| Session | memory; a container restart requires a fresh login |
| Notification | `appdata/authelia/notification.txt`; no SMTP or external DNS |
| Policy | default `deny`; `auth.` / `home.` / `paste.` bypass; the seven admin names `two_factor` |

**First TOTP enrolment requires a person:**

1. Open `https://auth.${CADDY_DOMAIN}/`.
2. Sign in as `pi`.
3. Read `AUTHELIA_PASSWORD` from `/opt/pi-stack/.env`. Its default is `raspberry` by the LAN-login decision.
4. Register a TOTP device in Authelia. It writes a confirmation link to the filesystem notifier.
5. Print the notification. Open the newest link. Scan its QR code:

   ```bash
   ssh pi 'sudo cat /opt/pi-stack/appdata/authelia/notification.txt'
   ```

6. Open a protected name. Complete password and TOTP. The service login still appears.

⚠ **Until step 6 succeeds, Caddy cannot serve an admin vhost.** This is the intended fail-closed state. Use SSH and a tunnel to the loopback ports:

```bash
ssh -N -L 8087:127.0.0.1:8087 -L 8082:127.0.0.1:8082 \
       -L 8085:127.0.0.1:8085 pi@<LAN_IP>
# portal: http://127.0.0.1:8087
# files:  http://127.0.0.1:8082
# logs:   http://127.0.0.1:8085
```

**Lost TOTP device:**

```bash
cd /opt/pi-stack
sudo docker compose exec authelia authelia storage user totp delete pi
```

Repeat the enrolment procedure. This removes only user `pi`'s TOTP record. It does not change the password or storage key. If the database is lost, restore the newest core backup. SQLite's online backup API copies `db.sqlite3`. The backup does not exclude it. Database loss removes every enrolled factor.

**Password change:** Edit `AUTHELIA_PASSWORD` in `.env`. Run `sudo bash provision.sh authelia`. Recreate Authelia. The phase generates an Argon2id hash with the digest-pinned binary. It atomically replaces the users file. Each run applies `.env`. A portal password change is temporary.

```bash
sudo bash /opt/pi-stack/provision.sh authelia
cd /opt/pi-stack && sudo docker compose up -d authelia
sudo docker compose exec authelia authelia config validate
```

**Deliberate controls:**

- v4.39 uses `/api/authz/forward-auth`. It copies `Remote-User`, `Remote-Groups`, `Remote-Email`, and `Remote-Name`. Do not use `/api/verify`.
- `session.cookies` is a list. The stable Go-template filter renders its domain and URL values (`X_AUTHELIA_CONFIG_FILTERS=template`). Environment overrides cannot represent object lists.
- Do not assume curl or wget exists in the image. Use its supported health check: `/app/healthcheck.sh`. A shell probe causes a watchdog restart loop.
- Argon2id uses 65,536 KiB per concurrent hash, not per lane. The 512 MiB limit allocates 320 MiB for five hashes. It reserves about 192 MiB for the daemon, SQLite, and retained Go allocations.
- Secrets are environment variables. Docker API inspection can read them. This matches the Arcane and Dozzle posture. It is not Docker secrets.
- Caddy and Authelia have no `depends_on`. If Authelia stops, protected names return 502. Caddy, the Pi-hole UI route, household names, and certificate management remain independently startable.
- **rsync replaces a file atomically. Docker keeps the old inode for a single-file bind mount until the container starts again.** After an rsync deployment, `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` can validate the old file. It can report false success. Validate and reload the new host copy over stdin. Do not recreate Caddy:

  ```bash
  cd /opt/pi-stack
  sudo docker exec -i caddy caddy validate --config - --adapter caddyfile < Caddyfile
  sudo docker exec -i caddy caddy reload --config - --adapter caddyfile < Caddyfile
  ```

  The current container runs the new active config. Its next normal start mounts the new host inode. Do not force-recreate it to refresh the mount. That adds unnecessary ACME risk.
- **`authn_strategies` is pinned to `CookieSession`. Removing it breaks Transmission.** Authelia defaults also include `HeaderAuthorization` and `HeaderProxyAuthorization`. Those strategies claim browser `Authorization: Basic` headers. Transmission uses its own RPC password. The browser sends those credentials with later requests. Authelia consumes them. A Basic header cannot meet a `two_factor` policy. The result is an unusable password prompt on `torrents.` and a return to the portal. Reproduce either state from the Pi:

  ```bash
  cd /opt/pi-stack; set -a; . ./.env; set +a
  B=$(printf 'pi:%s' "$TRANSMISSION_PASSWORD" | base64)
  curl -s -o /dev/null -D- -H 'X-Forwarded-Method: GET' -H 'X-Forwarded-Proto: https' \
    -H "X-Forwarded-Host: torrents.$CADDY_DOMAIN" -H 'X-Forwarded-Uri: /transmission/web/' \
    -H "Authorization: Basic $B" http://127.0.0.1:8087/api/authz/forward-auth | head -1
  # 302 to the portal = correct. 401 = the header strategies are back.
  ```

- No nftables change is required. `:8087` binds only to loopback. Authelia uses a bridge. Caddy reaches it on the Compose network.
- Do not add the portal as a dashboard tile. It is a login and enrolment workflow. Protected links reach it automatically.

---
