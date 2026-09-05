# Decisions

Five choices in this stack are non-obvious and expensive to reverse. Read them before you build.

See [OPERATIONS.md](OPERATIONS.md) for day-to-day operation.

## HTTPS works because of DNS-01, not because anything is exposed

The ISP uses CGNAT. This host has **no inbound connectivity**. It still receives a publicly trusted certificate through two controls:

1. `*.yourdomain.duckdns.org` is a **public DNS record pointing at a private address**. Publishing a name exposes nothing. Only household devices can reach its destination.
2. **DNS-01** proves control of the name through a TXT record. It does not prove a reachable server. Let's Encrypt never connects to the Pi. **HTTP-01 cannot work here.**

**Use DuckDNS or another provider with a TXT API.** DynDNS, No-IP, and most ISP DDNS providers expose only an A record. They cannot provide this control.

**A different DNS provider is an architecture change.** Change the plugin in `caddy/Dockerfile`. xcaddy compiles it into Caddy. Change `tls dns <provider>` in the `Caddyfile`. The Dockerfile checks that the plugin is linked. Without this check, failure occurs at runtime after `:80` and `:443` bind.

## One wildcard certificate, one Caddyfile site block

**Do not give each service its own site block.** DuckDNS stores exactly **one TXT record per account**. Seven site blocks make Caddy order seven certificates. Their DNS-01 challenges overwrite each other's TXT record. They fail and retry. They can exhaust Let's Encrypt's **5 failed validations per hour** limit. Keep every service in a `handle` inside one `*.DOMAIN` block.

Read the inline `Caddyfile` reasoning before you edit it.

## TLS is not authorisation — never forward these ports

A trusted certificate encrypts a connection. It provides **no access control**. This rule has no exceptions:

| Port | Why forwarding it is unrecoverable |
|---|---|
| `3552` Arcane | controls every container → **root-equivalent on the host**. Can stop DNS for the house, read `.env`, delete backups |
| `8082` Filebrowser | whole drive at `/srv`, **including the backups** |
| `9091` Transmission | RPC whitelist is disabled; a shared password is all that stands there |
| `8083` MicroBin | `/raw/<id>` returns full content with **no credentials** — upstream behaviour, not configurable |
| `8085` Dozzle | container logs contain environment dumps and tokens in stack traces — a session here is **equivalent to reading `.env`** |
| `8086` Beszel | **the first visitor becomes the owner** until an admin account exists, and it inventories the whole host |
| `80` `443` Caddy | the front door to all of the above |

Two controls reduce the effect of a mistake. Neither is the primary control. nftables drops non-RFC1918 sources. `BIND_ADDR` means most table ports do not listen on the LAN. A forward of `8082` reaches a closed port. Only `80`/`443` (Caddy), `8080`, `8581`, `32400`, and `51413` bind LAN-wide. **Forwarding `443` still exposes every table service.**

Narrow `ADMIN_SOURCES` to defend against a compromised LAN device. By default, that device is in the allowed set ([README security posture](../README.md#6-security-posture--read-this-before-you-deploy)).

CGNAT also prevents a forward from working. **Do not rely on CGNAT to keep ports closed.** The ISP can change that condition.

## Updates are gated, never continuous

`quarterly-update.sh` takes a full backup. It simulates the apt upgrade. It skips an upgrade that would *remove* a package. It re-pins each image to its channel tag's current digest. It health-checks services for 5 minutes. **It automatically restores the previous compose file and images after any failure.**

**Do not add Watchtower.** It pulls continuously. It has no backup, health gate, or rollback. A bad image can leave the house without DNS until a person notices.

## DNS bypass cannot be enforced from the Pi

If the Pi is **not** the LAN gateway, it never sees a packet addressed to `8.8.8.8`. The router is usually the gateway.

⚠ **An nftables or iptables `REDIRECT` of port 53 to Pi-hole does nothing on this topology.** The rule loads. The ruleset looks correct. It catches nothing. Enforce this at the router or do not enforce it.

This stack removes the *bootstrap*. Eighteen `server=/domain/` lines in `FTLCONF_misc_dnsmasq_lines` return NXDOMAIN for major DoH and DoT rendezvous hostnames. An adlist covers the long tail. A client cannot resolve `dns.google` before it uses DoH.

This stops the **opportunistic** case, such as a browser or OS automatic upgrade. It does **not** stop a hardcoded resolver IP. Nothing on the Pi can stop that. Chrome's "Secure DNS", iCloud Private Relay, and NextDNS stop working for all users. See [services/network.md](services/network.md#pi-hole-blocklists-and-the-encrypted-dns-bypass) for reasoning and reversal steps.
