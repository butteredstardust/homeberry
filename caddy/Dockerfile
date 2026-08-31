# Caddy, rebuilt with the DuckDNS ACME plugin.
#
# WHY BUILD AT ALL, when every other image here is just pulled and pinned:
# the official `caddy` image has no DNS provider modules. Caddy loads plugins by
# compiling them in, not at runtime — there is no `caddy add-plugin`. So getting
# a Let's Encrypt certificate via DNS-01 requires our own binary.
#
# WHY DNS-01 AND NOT THE USUAL HTTP-01: this house is behind CGNAT (confirmed
# 2026-08-23 and again 2026-08-25 — traceroute hops 2-4 are RFC1918 while the
# world sees a shared address). Let's Encrypt cannot reach port 80 here from the
# outside, and no amount of router configuration will change that. DNS-01 proves
# control of the name by writing a TXT record instead, which needs no inbound
# connection at all. DuckDNS is used because it exposes TXT updates over a plain
# HTTP API; DynDNS/No-IP/Digi's own DDNS give you an A record only and are
# therefore useless for this.
#
# WHY NOT A THIRD-PARTY PRE-BUILT IMAGE (serfriz/caddy-duckdns and friends):
# they would keep the digest-pinning workflow uniform, but they are one person's
# rebuild of a TLS-terminating proxy that sees every request to every service on
# this box. Building from Caddy's own official builder image is a shorter trust
# chain for ~2 minutes of compile time per quarter.
#
# The version is passed in from docker-compose.yml so there is ONE place to
# change it, and quarterly-update.sh rewrites it there.
ARG CADDY_VERSION=2.11.4

FROM caddy:${CADDY_VERSION}-builder AS builder
# xcaddy resolves the plugin against the Caddy version of this builder image, so
# builder and runtime tags must match — hence the shared ARG below.
RUN xcaddy build --with github.com/caddy-dns/duckdns

FROM caddy:${CADDY_VERSION}-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Proves the plugin actually made it in. Without this the image builds fine and
# then fails at RUNTIME with "unrecognized directive: dns", after Caddy has
# already bound :80 and :443 — i.e. exactly when the dashboard is unreachable.
RUN caddy list-modules | grep -q '^dns.providers.duckdns$'
