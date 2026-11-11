#!/bin/bash
# Installs the kit on a fresh Ubuntu/Debian VPS. Run as root from the repo:
#
#   EXTERNAL_URL=https://mcp.example.com \
#   VAULT_REPO=git@github.com:you/your-vault.git \
#   ./install.sh
#
# Safe to re-run: it never overwrites an existing .env, token file or vault.
# It does NOT set up the Cloudflare tunnel; see README step 4.
set -euo pipefail

EXTERNAL_URL="${EXTERNAL_URL:?EXTERNAL_URL is required, e.g. https://mcp.example.com}"
VAULT_REPO="${VAULT_REPO:-}"
VAULT_DIR="${VAULT_DIR:-/opt/vault}"
WITH_WRITER="${WITH_WRITER:-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/obsidian-mcp-vps

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

for bin in git docker openssl flock; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "missing: docker compose plugin"; exit 1; }

echo "==> vault"
if [ -d "$VAULT_DIR/.git" ]; then
  echo "    $VAULT_DIR already a git repo, leaving it alone"
elif [ -n "$VAULT_REPO" ]; then
  git clone "$VAULT_REPO" "$VAULT_DIR"
else
  echo "    $VAULT_DIR is not a git repo and VAULT_REPO is unset."
  echo "    Clone your vault there first (a deploy key works well), then re-run."
  exit 1
fi

echo "==> files"
mkdir -p "$DEST"
cp -r "$HERE/docker-compose.yml" "$HERE/scripts" "$HERE/vault-writer" "$DEST/"
chmod +x "$DEST/scripts/vault-sync.sh"

echo "==> secrets"
if [ ! -f "$DEST/.env" ]; then
  umask 077
  cat > "$DEST/.env" <<EOF
EXTERNAL_URL=$EXTERNAL_URL
VAULT_DIR=$VAULT_DIR
PASSWORD=$(openssl rand -base64 32)
EOF
  echo "    wrote $DEST/.env (mode 600). The PASSWORD in it is your login."
else
  echo "    $DEST/.env exists, keeping it"
fi

echo "==> MCP server + OAuth proxy"
(cd "$DEST" && docker compose up -d --build)

echo "==> sync cron (every 2 min)"
CRON_LINE="*/2 * * * * VAULT_DIR=$VAULT_DIR $DEST/scripts/vault-sync.sh >> /var/log/vault-sync.log 2>&1"
( crontab -l 2>/dev/null | grep -vF "$DEST/scripts/vault-sync.sh" || true; echo "$CRON_LINE" ) | crontab -

if [ "$WITH_WRITER" = "1" ]; then
  echo "==> vault-writer"
  command -v node >/dev/null || { echo "    node not found, skipping (set WITH_WRITER=0 to silence)"; WITH_WRITER=0; }
fi
if [ "$WITH_WRITER" = "1" ]; then
  if [ ! -f /etc/vault-writer.env ]; then
    ( umask 077; echo "WRITE_TOKEN=$(openssl rand -hex 32)" > /etc/vault-writer.env )
  fi
  sed -e "s#/opt/vault#$VAULT_DIR#g" \
      -e "s#/usr/bin/node#$(command -v node)#" \
      "$HERE/systemd/vault-writer.service" > /etc/systemd/system/vault-writer.service
  systemctl daemon-reload
  systemctl enable --now vault-writer
fi

cat <<EOF

Done.
  MCP (local):   http://127.0.0.1:8083/mcp
  MCP (public):  $EXTERNAL_URL/mcp   <- after you route the tunnel
  Login:         grep PASSWORD $DEST/.env
  Writer token:  cat /etc/vault-writer.env
  Sync log:      tail -f /var/log/vault-sync.log

Next: point a Cloudflare Tunnel hostname at http://localhost:8083 (README step 4).
EOF
