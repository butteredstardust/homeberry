#!/usr/bin/env bash
# Install one pinned Beszel Agent release after verifying its upstream checksum.
# Does not restart the service; provision/quarterly-update owns that decision.
set -euo pipefail

STACK="${STACK:-/opt/pi-stack}"
VERSION="${1:-$(tr -d '[:space:]' < "$STACK/beszel-agent-version")}"
INSTALL_DIR="/opt/beszel-agent"
ASSET="beszel-agent_linux_arm64.tar.gz"
BASE_URL="https://github.com/henrygd/beszel/releases/download/v${VERSION}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "Invalid Beszel Agent version: $VERSION" >&2; exit 1; }
[[ "$(uname -m)" == "aarch64" ]] \
  || { echo "Unsupported architecture: $(uname -m), expected aarch64" >&2; exit 1; }

current="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || true)"
if [[ "$current" == "$VERSION" && -x "$INSTALL_DIR/beszel-agent" ]]; then
  echo "Beszel Agent $VERSION already installed"
  exit 0
fi

tmp="$(mktemp -d -p /var/tmp beszel-agent-install.XXXXXX)"
transaction_started=0
had_previous=0
cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && transaction_started == 1 )); then
    echo "Beszel Agent install failed after replacement began; restoring previous binary." >&2
    if (( had_previous == 1 )); then
      cp -a "$INSTALL_DIR/beszel-agent.prev" "$INSTALL_DIR/beszel-agent" \
        || echo "Could not restore previous Beszel Agent binary." >&2
      if [[ -f "$INSTALL_DIR/VERSION.prev" ]]; then
        cp -a "$INSTALL_DIR/VERSION.prev" "$INSTALL_DIR/VERSION" \
          || echo "Could not restore previous Beszel Agent version file." >&2
      fi
    else
      rm -f -- "$INSTALL_DIR/beszel-agent" "$INSTALL_DIR/VERSION"
    fi
  fi
  rm -f -- "$INSTALL_DIR/.beszel-agent.new" "$INSTALL_DIR/.VERSION.new"
  rm -rf -- "$tmp"
  exit "$rc"
}
trap cleanup EXIT

curl -fsSL --retry 3 --connect-timeout 10 \
  "$BASE_URL/beszel_${VERSION}_checksums.txt" -o "$tmp/checksums.txt"
curl -fsSL --retry 3 --connect-timeout 10 \
  "$BASE_URL/$ASSET" -o "$tmp/$ASSET"

expected="$(awk -v asset="$ASSET" '$2 == asset {print $1; exit}' "$tmp/checksums.txt")"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] \
  || { echo "No valid checksum found for $ASSET" >&2; exit 1; }
echo "$expected  $tmp/$ASSET" | sha256sum -c -
tar -tzf "$tmp/$ASSET" beszel-agent >/dev/null
tar -xzf "$tmp/$ASSET" -C "$tmp" beszel-agent

install -d -m 0755 "$INSTALL_DIR"
install -o root -g root -m 0755 "$tmp/beszel-agent" "$INSTALL_DIR/.beszel-agent.new"
printf '%s\n' "$VERSION" > "$INSTALL_DIR/.VERSION.new"

if [[ -x "$INSTALL_DIR/beszel-agent" ]]; then
  had_previous=1
  cp -a "$INSTALL_DIR/beszel-agent" "$INSTALL_DIR/beszel-agent.prev"
  [[ -f "$INSTALL_DIR/VERSION" ]] && cp -a "$INSTALL_DIR/VERSION" "$INSTALL_DIR/VERSION.prev"
fi

# Both replacements are renames within one filesystem. If the second rename
# fails after the binary moved, the EXIT trap restores the predecessor.
transaction_started=1
mv -f "$INSTALL_DIR/.beszel-agent.new" "$INSTALL_DIR/beszel-agent"
mv -f "$INSTALL_DIR/.VERSION.new" "$INSTALL_DIR/VERSION"
transaction_started=0
echo "Installed Beszel Agent $VERSION"
