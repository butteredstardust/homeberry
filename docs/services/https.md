# Services — HTTPS

Use this runbook for Caddy, Let's Encrypt, and DuckDNS. See [OPERATIONS.md](../OPERATIONS.md) for host, recovery, and schedule details.

## HTTPS (Caddy + Let's Encrypt + DuckDNS)

Routing is defined in `Caddyfile`. **Read that file first.** See
[Decisions: HTTPS and the wildcard certificate](../DECISIONS.md#https-works-because-of-dns-01-not-because-anything-is-exposed)
for the design constraints. Use this section to resolve HTTPS faults.

| | |
|---|---|
| Image | **built here**, `caddy/Dockerfile` — official image has no DNS modules |
| Plugin | `github.com/caddy-dns/duckdns`, compiled in via `xcaddy` |
| Build time | ~6 min on a Pi 4 |
| Certificate | one wildcard, `*.${CADDY_DOMAIN}`, 90 days |
| ACME account | **no email registered** (owner's choice) |

**Build requirements:**

- Caddy is **not** in `quarterly-update.sh` digest `CHANNELS`. There is no digest
  to pin. The script updates the `CADDY_VERSION` build arg. It rebuilds through
  the same backup, health, and rollback gate.
- After you edit `caddy/Dockerfile`, run `docker compose up -d --build caddy`.
- Run `docker compose pull --ignore-buildable`. Without the flag, Docker looks
  for `pi-stack/caddy` on Docker Hub and the pull fails.

**The Dockerfile final `RUN caddy list-modules | grep -q dns.providers.duckdns`
is required.** Without it, a missing plugin fails at runtime after Caddy binds
`:80` and `:443`.

⚠ **Caddy uses its internal CA when ACME fails.** The site can remain available
with an untrusted certificate. Let's Encrypt has no account email for renewal
warnings. journald uses `Storage=volatile`, so reboot removes failure logs.
`disk-guard.sh` checks issuer and expiry daily. It gives a 21-day warning and
trips `systemctl --failed`.

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

**Known failure modes:**

- **`lookup acme-v02.api.letsencrypt.org on 127.0.0.11:53: server misbehaving`**
  means Caddy has no resolver. Use `dns: [1.1.1.1, 9.9.9.9]` on the caddy
  service. ⚠ **Do not use `depends_on` as the fix.** Caddy proxies the Pi-hole
  admin UI. If Caddy waits for Pi-hole, a failed Pi-hole can stop every name.
  The `dns:` key affects external queries only. Docker name resolution through
  `127.0.0.11` continues.
- **`resolvers 1.1.1.1 9.9.9.9` in the `tls` block is also required.** Caddy
  polls DNS after it writes the TXT record. Without these resolvers, it queries
  local Pi-hole. Pi-hole can cache the empty TXT for the full TTL. Caddy then
  waits for the record it already wrote.
- **Do not check DuckDNS propagation through a caching recursor.** Query the
  authoritative server: `dig TXT _acme-challenge.${CADDY_DOMAIN}
  @ns8.duckdns.org` (TTL is 60 s).
- **`caddy fmt` can report a hand-edit.** Check with
  `docker exec caddy caddy fmt /etc/caddy/Caddyfile | diff - /opt/pi-stack/Caddyfile`.
- **`/tmp` is tmpfs and reboot clears it.** Before `scp` after reboot, run
  `mkdir -p /tmp/deploy`. Otherwise the copy fails with `dest open ... Failure`.

⚠ **Never run the stock DuckDNS updater cron on this network.** A `/update` call
without `ip=` sets the A record to the caller address. Here, that address is the
public CGNAT address. Every name then fails. Verified 2026-08-26: the plugin
TXT-only writes did **not** change the A record. It stayed `<LAN_IP>`.
