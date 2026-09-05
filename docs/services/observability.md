# Services — observability

Use this runbook for Dozzle, Diun, and Beszel. See [OPERATIONS.md](../OPERATIONS.md) for host recovery and the schedule.

## Observability (Dozzle, Diun, Beszel)

These services answer three questions: what a container reports, whether an image is outdated, and past resource use. Their combined cost, including the native agent, is **~42 MB RSS**. The host has 2.7 Gi available.

| Service | Answers | URL | Port | Auth |
|---|---|---|---|---|
| Dozzle | live + historical container logs | `https://logs.${CADDY_DOMAIN}` | 8085 | simple auth, `admin` / see `.env` → `DOZZLE_PASSWORD` |
| Diun | "is a newer image published?" | none — log output only | none | n/a |
| Beszel | CPU/mem/disk/net history + charts | `https://metrics.${CADDY_DOMAIN}` | 8086 | own account, created at first run |

Beszel has two parts: the `beszel` hub container and the native `beszel-agent.service` collector. Measured footprint: Dozzle 11 MB, Diun 15 MB, Beszel hub 10 MB, and native agent 6 MB.

### Dozzle

Use Dozzle when several containers can cause a fault. It tails all twelve containers and searches their logs.

⚠ **A Dozzle session is equivalent to reading `.env`.** Container logs can contain environment dumps, tokens in stack traces, and full file paths.

- Keep `DOZZLE_AUTH_PROVIDER: simple`. It requires a login. Do not remove it.
- Keep `DOZZLE_ENABLE_ACTIONS: "false"`. It removes start, stop, and restart buttons. Arcane manages containers behind its own password.
- **Do not mount the socket.** Dozzle uses `socket-proxy-ro` (`DOCKER_HOST=tcp://socket-proxy-ro:2375`). The proxy allows `CONTAINERS`, `IMAGES`, `EVENTS`, `PING`, `VERSION`, and `INFO`. It refuses `POST` and `EXEC`. Dozzle cannot write. A `:ro` socket mount cannot guarantee that. This is not a confidentiality boundary. Container metadata reveals every container environment. Keep the login.
- **Never forward 8085.** `BIND_ADDR` binds it to loopback. `(adminonly)` also protects it. Keep all three layers.

The password is generated on the Pi. Do not print it to a terminal. It is `DOZZLE_PASSWORD` in `/opt/pi-stack/.env` (mode 600). Its bcrypt hash is in `appdata/dozzle/users.yml`. To rotate it, regenerate both. The regeneration command is beside the variable in `.env`.

`https://logs.…` returns **307** when authentication works. It redirects to the login form. A 200 requires investigation.

### Diun

Diun checks whether a newer image is published. **It writes a log line. It does not pull. It does not restart services.** The host has no automatic backup before an image change. It has no automatic health gate or rollback. An unattended update can stop household DNS. Diun reports update availability. A person chooses the timing and runs `quarterly-update.sh`.

⚠ **Do not add a notifier that depends on this Pi.** `No notifier available` is expected. Read the log through Dozzle.

The schedule is `0 6 * * *` (daily, 06:00). `DIUN_WATCH_FIRSTCHECKNOTIF: "false"` suppresses twelve first-start "new image found" lines. Those lines record a baseline. They do not report updates.

**Diun watches digest pins correctly.** Every `docker-compose.yml` image is `tag@sha256:…`. Diun follows the tag. It reports when the tag digest changes. Verified at first run: 11 images analyzed, all resolved.

⚠ **Exclude Caddy with `labels: diun.enable: "false"`.** `pi-stack/caddy` is built locally and has no registry. Diun resolves it to `docker.io/pi-stack/caddy`. It then fails with *"requested access to the resource is denied"*. This daily failure makes Diun output unreliable. `CADDY_VERSION` in the build args tracks the upstream version. `quarterly-update.sh` updates it. Confirmed after the fix: `failed=0`, `unchanged=11`.

⚠ **Diun records its first observed tag digest. It does not record your pinned digest.** Diun compares a remote tag with its own database. An image already outdated at installation becomes the baseline. Diun does not report it. Confirmed at install: Arcane's pin is `sha256:2425b5a…`. `ghcr.io/getarcaneapp/manager:latest` already resolved to `sha256:f10f95d…`. The second run still reported `unchanged=11`. Diun reports drift **from its baseline forward**. Use a direct digest comparison to check whether a pin is outdated now:

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

The `docker inspect` command lists deployed image values only. It does not resolve a remote tag. Use a separate registry query to make a live comparison.

### Beszel

The `beszel` container stores history and draws charts. The collector is a pinned host binary under `beszel-agent.service`. The host run gives it native `smartctl` without a custom image or libc bind mounts.

⚠ **Do not provision the agent before the hub creates its `KEY` and `TOKEN`.** The hub issues them when its UI adds a system. Follow this procedure after each rebuild:

1. Open the hub. Create the admin account. Beszel has **no default login — the first visitor becomes the owner**. Do this before another LAN user opens it.
2. *Add System* → the UI issues a `KEY` (public ed25519) and a `TOKEN`.
3. Put `BESZEL_KEY` and `BESZEL_TOKEN` in `.env`. The key is public. The token authorizes registration and is secret. Re-run `sudo ./provision.sh beszelagent` after either value changes.

**The agent connects out. It does not listen.** With `HUB_URL` and `TOKEN`, the agent opens a WebSocket to the hub. Verified: `ss -lntp` shows **nothing on 45876**. Hub polling needs a port bound to `0.0.0.0`. The hub arrives through the Docker bridge gateway, not loopback. Do not add `LISTEN`. `DISABLE_SSH=true` prevents a fallback listener while the hub restarts. Beszel needs no nftables rule.

The dedicated `beszel` user belongs to `docker` for container metrics. It belongs to `disk` for `/dev/sda` access. The unit grants only the two capabilities needed for SMART. It restricts device access to `/dev/sda`. Docker group membership still gives effective host-root access.

`EXTRA_FILESYSTEMS=/mnt/rpidata` adds the HDD beside the SD root. `SMART_DEVICES=/dev/sda:sat` explicitly handles the USB-SATA bridge. The bridge returns smartctl status bit 2 because one ATA status opcode is unsupported. Beszel 0.18.8 still parses the valid attribute payload. Verified in the hub DB: model string, state `PASSED`, temperature, and 17 attributes.

```bash
sudo journalctl -u beszel-agent -n 50 | grep -E "Detected disk|SMART|WebSocket"
# must list BOTH sda1 (mount=/mnt/rpidata) and mmcblk0p2 (root=true)
sudo sqlite3 /opt/pi-stack/appdata/beszel/data.db \
  'select name,model,state,temp,updated from smart_devices;'
```

Only Caddy proxies the hub. The agent uses the host network. Do not reverse-proxy the agent.

⚠ **Update hub and agent in the same run.** Upstream versions them together and they share a protocol. A newer hub can silently stop recording with an older agent. `quarterly-update.sh` manages the hub digest and native `beszel-agent-version` pin. It also verifies checksums, checks health, and rolls back the binary.

### Verification after any change to these three

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
