# Services — network

Use this runbook for DNS and remote access. See [OPERATIONS.md](../OPERATIONS.md) for host recovery and the schedule.

## Pi-hole: blocklists, and the encrypted-DNS bypass

**Use `gravity.db` as the adlist authority.** `/etc/pihole/adlists.list` is a v5
leftover. It shows one list, but `gravity.db` has **17 rows, 9 enabled**.
Query the database before you change an adlist:

```bash
docker exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db \
  'SELECT id,enabled,address,comment FROM adlist ORDER BY id;'
docker exec pihole pihole -g          # rebuild after any change, ~2 min
```

⚠ Use `pihole-FTL sqlite3`, not `sqlite3`. The container has no standalone
binary. Use **single quotes** for string literals. SQLite reads `"..."` as a
*column reference*, so a double-quoted INSERT fails with `no such column`.
For complex SQL, write a file and pipe it in (`sqlite3 db < file.sql`). Do not
nest quotes inside `ssh`/`docker exec`.

⚠ `sqlite3 -column /tmp/q.sql` **hangs**. Passing a `.sql` file as the first
argument opens it *as the database* and blocks on stdin. Always use `< file.sql`.

**Use `config/pihole-adlists.txt` as the repository source.** Apply it with
`sudo bash provision.sh adlists`. The import is additive and idempotent. An
existing address keeps its enabled state and comment. A list disabled by hand
stays disabled after another run. The import never removes a list. Add a list
there, not in the web UI, when it must survive a rebuild.

Current gravity: **1,172,601 unique domains** (1,301,928 rows) across 9 lists.

### The enabled set (reviewed 2026-08-26)

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

**Disabled, not removed:** use `enabled=0` and a dated `comment`. This keeps the
decision reversible and documented. Re-enable with an `UPDATE` and `pihole -g`.
Never `DELETE`; that removes the reason for the decision.

| id | List | Why disabled |
|---|---|---|
| 10 | GoodbyeAds-YouTube | 97,446 of its 97,645 entries are `googlevideo.com` — YouTube's **content** CDN, not ads. Upstream last commit 2024-11-22. |
| 2, 4 | Ultimate.Hosts.Blacklist `hosts0`,`hosts1` | See below. |
| 21 | SpotifyAdBlock | Blocks 746 `spotify.com`/`scdn.co` hosts including `*.video-ak.cdn.spotify.com` content CDNs. |
| 12 | AdAway | 6,540 domains, **10** unique. |
| 15 | yoyo.org | 3,518 domains, **2** unique. |
| 9 | AdguardMobileAds | 924 domains, **4** unique. |
| 3 | rolist-hosts | 97 domains, 19 unique. Upstream last commit 2020-01-20. |

### Why Ultimate.Hosts.Blacklist was dropped, and what replaced it

The list has 297,500 domains, including 174,354 unique domains. Do not enable
it. Two facts make it unsuitable:

1. **Only 2 of 6 shards were imported.** Upstream ships `hosts0`–`hosts5`; the
   config has `hosts0` and `hosts1`. That is an arbitrary third of the list.
2. **The 174,354 unique domains are not ad domains.** They are phishing and scam
   hosts on free platforms — `0ffice-resolving-l0gin-365.*`,
   `att-team-104712.weeblysite.com`, `*.workers.dev`, `*.000webhostapp.com`,
   IPFS-gateway phishing. This is threat coverage in the **wrong shape**: a
   static snapshot of *ephemeral* indicators. Phishing hosts live days to weeks.
   A frozen list is mostly dead domains, while live domains are absent.

Use **HaGeZi TIF Medium** (id 23) for this category. It is a maintained threat
feed. It has the same maintainer and Codeberg mirror as id 19. It adds **no new
dependency**.

⚠ **Medium tier deliberately.** Full `tif.txt` is 2,148,490 entries and upstream
warns that it over-blocks. `tif.mini` has 173,613 entries. Medium has 326,409.
Do not change to full without the false-positive sweep.

### Two results that look like regressions but are not

**DoH hostnames can answer `NOERROR` + `0.0.0.0` instead of `NXDOMAIN`.** This
does not indicate a failure. TIF Medium contains the DoH endpoints. A **gravity
hit takes precedence** over `server=/domain/` in `misc.dnsmasq_lines`. Gravity
answers `0.0.0.0`; `server=/x/` answers NXDOMAIN. Both stop bootstrap because a
client cannot open TLS to `0.0.0.0`. Verified 17/17 remain blocked. Keep
`dnsmasq_lines`; this layer does not depend on a third-party list.

**`scdn.co` and `open.scdn.co` return no address.** They have no A record at
`1.1.1.1` either. These are apex/CNAME-only names. This is not a false positive.
Before acting on an apparent over-block, **compare against a public resolver**.
`dig +short | tail -1` renders NODATA and NXDOMAIN identically.

### What DNS blocking cannot do — do not re-add lists for this

Verified 2026-08-26 after removing the YouTube, Spotify, and Romanian lists.
In all three cases, **do not find a replacement list**.

**YouTube ads: impossible via DNS.** Ads stream from `*.googlevideo.com` — the
the same hosts, often on the same connections, as video content. No hostname
serves ads without content. GoodbyeAds blocked 97,446 `googlevideo.com` names.
That broad block degrades playback. A 40-domain sample measured **0 blocked, 39
NXDOMAIN (already dead ephemeral CDN names), 1 live**. The live domain must
resolve because it serves video. Use uBlock Origin, SponsorBlock, ReVanced
(Android), `yt-dlp`, or Premium.

**Spotify audio ads: impossible via DNS.** Free-tier audio ads are injected into
the same stream and CDN as music. DNS can only block *named* ad and telemetry
hosts. These remain blocked without list 21:

| Host | Status | |
|---|---|---|
| `adeventtracker.spotify.com`, `ads-fa.spotify.com`, `analytics.spotify.com`, `adstudio.spotify.com` | `0.0.0.0` | still blocked |
| `pagead2.googlesyndication.com`, `googleads.g.doubleclick.net`, `s0.2mdn.net` | `0.0.0.0` | wildcard-covered by the general lists |
| `spclient.wg.spotify.com`, `partners.spotify.com`, `desktop.spotify.com` | resolves | **app-critical, must not be blocked** |

Fix client-side: SpotX-Bash / BlockTheSpot patch the desktop client, or Premium.

**Romanian ads: do not restore the stale list.** Of rolist's 97 domains, 75 are
still blocked by exact match and 8 by wildcard. **13 are dead upstream.** One is
live and unblocked: `zopim.com`. It is Zendesk Chat, a support widget. Leave it
resolving.

⚠ **Do not feed ROad Block (`tcptomato/ROad-Block`) to Pi-hole**, despite it
being the maintained Romanian list (last commit 2026-08-24). It is a **browser**
filter list. 350 of its 482 `||` rules have a URL path
(`||fanatik.ro/wp-content/.../netbet*.webp`), which DNS cannot express. Pi-hole
removes these non-domain entries. Any parsed rules can block legitimate news
sites (`fanatik.ro`, `luju.ro`, `stiridecluj.ro`). It covers one of 22 candidate
gap domains. Use it in **uBlock Origin**, where path matching works.

**General rule: a filter list full of URL paths or cosmetic (`##`) rules is a
browser list.** Run `grep '^||' list | grep -c '/'` before any import.

### Verifying after any adlist change

⚠ An adlist change takes LAN DNS down for the whole house during its rebuild.
Create the backup first. Then run this verification, including the labelled
false-positive sweep, after every change.

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

### Domain count is not the performance cost

Measured on this host: blocked lookup **3.1 ms mean / 4 ms max**. `pihole-FTL`
RSS is **61 MB** with 1.17M domains. RAM use is 913 MB of 3,795 MB. FTL stores
gravity in an indexed SQLite table. Lookup is O(log n). Moving from 1.1M to 3M
domains costs single-digit MB with no measurable latency.

⚠ **Do not trim lists for speed.** The real costs are **false positives**,
rebuild time, and maintenance surface. Judge a list by its *unique* contribution
and active upstream, never its size. The enabled count is 16 lists → 9. Unique
domains increased from **1.12M → 1.17M**. Removed lists were redundant; added
domains were not.

### Why the Pi cannot stop DNS bypass, only discourage it

```
default via <ROUTER_IP> dev eth0     ← the ROUTER is the gateway, not this Pi
```

**This Pi is a leaf node.** A device that sends DNS to `8.8.8.8` sends it to the
router. The packet never traverses this host. Therefore:

⚠ **The universal advice — an nftables/iptables `REDIRECT` of port 53 to
Pi-hole — is a NO-OP on this topology.** The rule loads, `nft list ruleset`
looks correct, but catches nothing. No traffic reaches this host. Do not add
this rule. Do not treat it as effective. (`net.ipv4.ip_forward = 1` comes from
Docker. It does not show that this host routes LAN traffic.)

Only the router can enforce this. It needs one rule that drops outbound `:53`
and `:853` from everything except <LAN_IP>. That work is out of scope.

### What is done instead: remove the bootstrap

A client that uses DoH with `dns.google` must first *resolve* `dns.google`
through Pi-hole. Return NXDOMAIN to prevent the upgrade.

| Layer | Where | Covers |
|---|---|---|
| 18 explicit `server=/domain/` lines | `FTLCONF_misc_dnsmasq_lines` in `docker-compose.yml` | the major providers: Google, Cloudflare, Quad9, NextDNS, AdGuard, OpenDNS DoH, CleanBrowsing, ControlD, Apple Private Relay, RFC 9462 DDR |
| `dibdot/DoH-IP-blocklists` adlist | `gravity.db`, id 22 | the ~1,400-domain long tail of public DoH servers |
| Firefox canary | **native to Pi-hole v6**, nothing to configure | Firefox auto-DoH |

`server=/domain/` with no address means "answer NXDOMAIN, do not forward" in
dnsmasq. Domain matching includes subdomains. `cloudflare-dns.com` also catches
`chrome.`, `mozilla.`, `security.`, and `family.`.

**Do not use a blocklist entry.** Gravity returns `NOERROR` + `0.0.0.0`. Some
clients treat that as a reachable host. NXDOMAIN is unambiguous. The Firefox
canary also cannot use a blocklist. `use-application-dns.net` must return
**NXDOMAIN specifically** or Firefox keeps DoH enabled. Verified 2026-08-26:
the canary returns NXDOMAIN; `doubleclick.net` returns `NOERROR` + `0.0.0.0`.

Measured 2026-08-26: a random 40-domain DoH sample was **7/40 blocked before,
40/40 after.**

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

⚠ **Never add `opendns.com` to this list.** `208.67.222.222` is the Pi upstream
(`PIHOLE_UPSTREAMS`). Block only the `doh.*` hostnames. A blocked *hostname*
does not affect an upstream set by *IP*. Caddy ACME `resolvers 1.1.1.1 9.9.9.9`
([HTTPS](https.md)) are unaffected. Do not conflate `one.one.one.one` with
`1.1.1.1`.

### What this does NOT catch — do not overestimate it

- A device with a **hardcoded resolver IP** and no hostname to look up.
- Android "Private DNS" pointed at an IP, or any DoH client with baked-in
  addresses.
- Any VPN.

This stops an **opportunistic** browser or OS upgrade. It also raises the cost of
a simple manual bypass. **It cannot stop a determined bypass. Nothing on this
Pi can stop one.**

**Accepted trade-offs, 2026-08-26:** Chrome "Secure DNS", iCloud Private Relay,
and NextDNS do not work for house users. To undo this, remove the
`FTLCONF_misc_dnsmasq_lines` key. Run `docker compose up -d pihole`. Disable
adlist 22. Run `pihole -g`.

**To detect an actual bypass** (not implemented), compare the LAN neighbour
table (`ip neigh show dev eth0`) with Pi-hole client history. A LAN device with
zero DNS queries in N hours bypasses DNS or is a dumb device. This is the only
comparison this host can use to detect a deliberate bypass.

---

## Tailscale (remote access)

Tailscale provides remote access under CGNAT. No inbound path to this host
exists, and no port can be forwarded.

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

### What was changed on the host

| Change | File | Why |
|---|---|---|
| `iifname "tailscale0" accept` in `input` **and** `forward` | `nftables.conf` | see below |
| `net.ipv4.ip_forward = 1`, `net.ipv6.conf.all.forwarding = 1` | `/etc/sysctl.d/99-tailscale.conf` | forwarding was runtime-only, set incidentally by Docker — not a guarantee it is set before `tailscaled` starts |
| `ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off` | `/etc/systemd/system/ethtool-udp-gro.service` | without it the kernel cannot coalesce forwarded UDP and WireGuard throughput through this box is capped. **ethtool settings do not survive reboot**, hence the unit |

⚠ **The firewall rule matches an interface name.** `nftables.conf` otherwise
forbids this. This is the deliberate exception. Tailnet peers use `100.64.0.0/10`.
The ISP router also queries from this CGNAT range. A source-address rule would
re-admit the ~230k junk DNS queries per day. Interface matching separates them.
`tailscaled` names `tailscale0`, so it cannot drift like `wlan0` or a
Compose-generated bridge name.

⚠ Keep `--accept-dns=false` on the Pi. This host uses `nameserver 127.0.0.1`
(Pi-hole). If tailscaled rewrites `/etc/resolv.conf` to `100.100.100.100`, it
points the host at the tailnet resolver. That resolver points back to this Pi.
This creates a loop.

**Do not open port 41641.** Under CGNAT with zero IPv6 (verified: no global v6
address and no off-net v6 route), no unsolicited inbound packet can arrive. NAT
traversal still works. Replies match the existing `ct state established,related`
accept. Add the port if the ISP provides a real address or IPv6. Direct paths
then become faster.

### Settings that live ONLY in the admin console

⚠ **These settings are outside this repository and do not survive a rebuild.**
If you reprovision the Pi, set them again by hand at
<https://login.tailscale.com/admin/machines>.

| Setting | Value | Consequence if missed |
|---|---|---|
| Subnet route `<LAN_SUBNET>` | **approved** | An advertised-but-unapproved route is **silently ignored** — no error anywhere. The classic hour-long debug. Now also covered by `autoApprovers` in the policy file, so a reprovisioned Pi approves itself. |
| Key expiry on `raspberrypi` | **disabled** | Default ~6 months, after which the Pi drops off the tailnet and there is no remote way back in. Non-negotiable for a server. |
| DNS → Nameservers | `<PI_TAILNET_IP>` + *Override DNS servers* | Without it the DuckDNS names do not resolve remotely and there is no ad-blocking off-LAN |
| Policy file (ACLs) | paste `tailscale-policy.hujson` | Default policy is **allow-all**. See [Access control (ACLs)](#access-control-acls). The repo copy and the console drift silently — the console is what enforces. |
| Device tags | `tag:mobile` / `tag:desktop` | An untagged new device lands in the **admin tier** with full LAN access. Tag it at join time ([Adding a device](#adding-a-device-iphone-ipad-windows)). |

**The DNS choice has a consequence.** *Override DNS servers* applies Pi-hole
filtering everywhere. If this Pi is unreachable, devices lose DNS instead of
failing over. The alternative is Split DNS (*Restrict to domain* `duckdns.org`).
It resolves own hostnames through Pi-hole and other names through the device
resolver. Change this setting only in the console. Nothing changes on the Pi.

### Why the existing certificate keeps working remotely

Caddy, the Caddyfile, and the wildcard certificate need no remote-access change:

```
remote device ─ tailnet ─► Pi (<PI_TAILNET_IP>) ─ subnet route ─► <LAN_SUBNET>
                            └─ Pi-hole answers DNS for the tailnet
```

Pi-hole resolves `*.${CADDY_DOMAIN}` to `<LAN_IP>`. The subnet route reaches
that address. Pi-hole gives the same answer on the LAN. One certificate and one
site block work without split-horizon DNS.

⚠ **`https://<PI_TAILNET_IP>/` fails, and that is correct.** Caddy serves only the
DuckDNS hostname. A bare-IP request matches no site block and closes. Always
test by hostname:

```bash
curl --resolve files.${CADDY_DOMAIN}:443:<PI_TAILNET_IP> \
     https://files.${CADDY_DOMAIN}/
```

### Verification

Run these checks after any Tailscale change. A failed ACL can remove your own
access, so verify from a client before you end the session.

```bash
tailscale status                                   # expect "active; direct ..." per peer
dig +short @<PI_TAILNET_IP> doubleclick.net          # 0.0.0.0  -> firewall + Pi-hole OK
dig +short @<PI_TAILNET_IP> google.com               # resolves -> upstream OK
ssh pi@<LAN_IP> 'tailscale status --json | grep -A3 PrimaryRoutes'   # route live
```

Verified 2026-08-26 end-to-end: DNS traverses the tunnel. All six published
ports are reachable. A valid Let's Encrypt wildcard serves over the tunnel
(`ssl_verify_result=0`). 9/9 containers are healthy. There are 0 failed units.

**If Tailscale fails, LAN service remains unaffected.** Its firewall rules only
*add* accepts. Run `systemctl stop tailscaled` to return the host to its prior
state. This is the rollback.

### Tailnet lock

Tailnet lock is enabled. Without it, a coordination-server controller can add a
trusted node. With it, a new node remains unreachable until a trusted node signs
it.

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

⚠ **The disablement secret is not in this repository, `.env`, or the Pi.**
Tailscale prints it once at `lock init` and never displays it again. It is the
only way to disable lock after both signing nodes are lost. A Pi copy defeats the
purpose because lock must survive loss of the Pi.

⚠ **The quorum is 2.** If you lose the Mac, Pi, and secret, this tailnet can
never accept another node. Sign a third durable node to resolve this risk. Until
then, the password-manager entry is required.

⚠ **Lock signs node *additions* only. It revokes nothing.** It does not affect
the Pi disabled key expiry ([Tailscale](#tailscale-remote-access) console table)
or already trusted keys. Do not use lock instead of rotating a leaked key.

Know these two behaviors before you change lock:

- `tailscale lock init` has **two steps**. It prints a command and changes
  nothing without `--confirm`. The first run is a dry run.
- A lock change can briefly show *"Tailscale can't reach the configured DNS
  servers"* while the Mac netmap re-syncs. **Do not act on this warning during
  the first minute.** Verify with `dig @<PI_TAILNET_IP>` first.

### Adding a device (iPhone, iPad, Windows)

Two gates control a new device. Both can look like broken networking. Sign the
device with lock. Tag it with ACLs.

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
   key.** This lets the device re-sign itself when its node key rotates. Without
   it, routine rotation strands the device until you reach a signing node. This
   matches the admin-console flow.

   ⚠ `tailscale lock status` on the Mac shows the trusted-key list but **does not
   list nodes awaiting signature**. Query the API above.

3. **Tag it**, in the console under *Machines → ⋯ → Edit ACL tags*:
   `tag:mobile` for iPhone/iPad, `tag:desktop` for Windows.
4. Verify a DuckDNS name over https and Plex from the device.

⚠ **Step 3 is not optional and its failure mode is silent-but-permissive.** An
untagged device is owned by the user, matches `autogroup:member`, and therefore
lands in the **admin tier**. It gets every Pi port and the full `<LAN_SUBNET>`
behind the subnet router. It appears to work normally, so the failure is easy to
miss.

⚠ **Tagging transfers ownership from the user to the tag.** Expected side
effects: the device stops matching `autogroup:member`. The tag controls key
expiry instead of the user. Both effects are intended.

⚠⚠ **NEVER tag the Mac or the Pi.** Untagged is the admin tier. Each admin grant
uses `autogroup:member` as its **source**. Tagging the Mac stops this match. It
immediately loses the Pi, LAN, and phones. No tag is a source except client-tier
tags. Recover by editing the console policy, which is outside the tailnet. Tags
**demote** new devices; they do not classify the Mac or Pi. Tagging the Pi also
needs re-auth and can strand the host over SSH.

⚠ **iOS devices register their hostname as `localhost`.** Two devices then show
as identical entries in `tailscale status`. Only the MagicDNS name differs.
Rename at join time. This changes the MagicDNS name, so do it before a user
bookmarks the old name:

```bash
curl -s -X POST -u "$(cat tailscale-apikey.txt):" -H "Content-Type: application/json" \
  -d '{"name":"iphone"}' https://api.tailscale.com/api/v2/device/<id>/name
```

Tailscale derives the machine name from the device hostname. Phones and tablets
can join under an arbitrary iOS name. Rename each device once here. ACL rules
then continue to match after iOS changes its hostname.

⚠ **iOS and iPadOS cannot sign.** Signing is a CLI operation, so those devices
must be signed *from* the Mac or Pi. If you are away from both, a new phone
cannot work until you reach a signer.

### Access control (ACLs)

Policy file: **`tailscale-policy.hujson`** in this repository. Paste it into
<https://login.tailscale.com/admin/acls/file>. The default policy is **allow-all**.
Do not use it when a phone or Windows host joins.

| Tier | Members | Gets |
|---|---|---|
| Admin (untagged) | Mac, Pi | Everything on the Pi, the whole LAN, **and the tagged client devices** |
| `tag:mobile` | iPhone, iPad | 53, 80, 443, 32400, 445, icmp — **on the Pi only** |
| `tag:desktop` | Windows | the above, plus 139 — **on the Pi only** |

⚠ **The admin → client grant is deliberately ONE-directional.** The Mac can
reach the iPad for Taildrop, ping, and screen sharing. The iPad cannot reach the
Mac. A policy test enforces this. A symmetric change fails to save. Tagging
removes a device from `autogroup:member`. Without this grant it disappears from
the Mac netmap, and `tailscale status` stops listing it. This looks like a device
failure, but it is a policy result.

**Restrict client tiers to :443.** Caddy fronts each admin UI on 443
([HTTPS](https.md)). A phone that reaches `pihole.${CADDY_DOMAIN}` does not need
8080. The Mac handles break-glass access. Container UIs bind to loopback
(`BIND_ADDR`), so use an ssh tunnel ([HTTPS broken](../OPERATIONS.md#28-https-broken)), not a raw tailnet port. Only
`8080` and `8581` stay directly reachable from `ADMIN_SOURCES` or the tailnet.
Plex is unproxied by design, so it uses `tcp:32400`.

⚠ **The Pi has two addresses and every rule must name BOTH.** `<PI_TAILNET_IP>`
and `<LAN_IP>` identify the same host. `<LAN_IP>` is in the `<LAN_SUBNET>` subnet
route. A rule that restricts the tailnet address but allows the LAN range is
**ineffective**. A client can connect to the LAN IP instead. Use the `pi-ts` /
`pi-lan` host pair. Do not grant the LAN range to client tiers.

⚠ **Grants are allow-only; there is no deny.** A broader rule always wins. Never
resolve a connectivity problem by adding a wide grant. Update the specific tier.
A wide grant silently restores allow-all.

The main protection is against lateral movement, not port hygiene. This policy
keeps a compromised phone or malware-hosting Windows host off the router admin
page, other hosts, and SSH.

The `tests` block enforces this. The console **refuses to save** a policy where
`tag:mobile` reaches `:22`, the raw Arcane port, the router, or another LAN host.
A careless grant edit fails at save time.

⚠ An ACL change can remove your own access. Run the client checks first. Validate
the policy before you apply it. Keep an authenticated console session open until
the checks succeed.

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

Tailnet addresses use `100.64.0.0/10`, the **same CGNAT range the ISP uses**
([Tailscale](#tailscale-remote-access); this is why the firewall matches the interface). If a tailnet IP is absent
from the route table, an ACL can be denying that peer. macOS then sends the
packet through `en0` to the default gateway. *The ISP CGNAT infrastructure can
answer it.* Measured on one link: a denied iPad "replied" in **15 ms with 0%
loss**. The real tunnel showed 100% loss when denied and 260 ms when permitted.
**The fast, healthy-looking reply was false.**

⚠ `192.0.2.50` in the test block is a **placeholder for "some other LAN
host"**, not a real device. If DHCP assigns it, the test still makes the correct
assertion. If you replace it, use an address that is not the Pi.

---
