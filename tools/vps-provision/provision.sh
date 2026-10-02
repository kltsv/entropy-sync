#!/usr/bin/env bash
#
# Provision an entropy-sync hub on a bare VPS, from this machine, in one run.
#
# What it does:
#   1. checks the server is reachable and the domain points at it;
#   2. runs `remote-setup.sh` there — docker, CouchDB 3 + Caddy with automatic
#      TLS, the server settings the sync layer needs, one database and its own
#      non-admin user;
#   3. mints the **setup-URI + transfer secret** with the local `entropyd`
#      binary, so the values can be pasted straight into the app's setup form.
#
# Nothing secret is written to disk here: the generated passwords are printed
# once, and the setup-URI carries the server credentials encrypted under the
# transfer secret (the E2EE passphrase is never in it — it is invented on the
# device, see `vault_crypto` RV3).
#
# Usage:
#   tools/vps-provision/provision.sh --host root@203.0.113.10 \
#       --domain sync.example.com --email you@example.com [--db vault]
#
# Re-running against the same server is safe: existing data, users and
# databases are left alone.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOST=""; DOMAIN=""; EMAIL=""; DATABASE="vault"; SYNC_USER="entropy"
SYNC_PASS=""; ADMIN_PASS=""; TRANSFER_SECRET=""

usage() {
  cat <<USAGE
usage: provision.sh --host <user@host> --domain <fqdn> --email <address>
                    [--db <name>] [--sync-user <name>] [--sync-password <pw>]
                    [--admin-password <pw>] [--transfer-secret <s>]

  --host             SSH target of the VPS (must allow root or passwordless sudo)
  --domain           hostname whose DNS A/AAAA record points at that VPS
  --email            address for the Let's Encrypt certificate
  --db               database for this vault (default: vault; one per vault)
  --sync-password    reuse an existing sync user's password instead of a new one
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --db) DATABASE="$2"; shift 2 ;;
    --sync-user) SYNC_USER="$2"; shift 2 ;;
    --sync-password) SYNC_PASS="$2"; shift 2 ;;
    --admin-password) ADMIN_PASS="$2"; shift 2 ;;
    --transfer-secret) TRANSFER_SECRET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

# (macOS ships bash 3.2 — no ${var,,}; keep this script portable.)
for required in HOST DOMAIN EMAIL; do
  if [[ -z "${!required}" ]]; then
    flag="$(echo "$required" | tr '[:upper:]' '[:lower:]')"
    echo "error: --$flag is required" >&2; usage; exit 64
  fi
done

say() { echo "==> $*"; }
gen() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# --- preflight ----------------------------------------------------------------
say "checking SSH access to $HOST"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true \
  || { echo "error: cannot ssh to $HOST (key-based access required)" >&2; exit 1; }

say "checking that $DOMAIN points at the server"
server_ip="$(ssh "$HOST" "curl -fsS --max-time 10 https://api.ipify.org || hostname -I | awk '{print \$1}'")"
domain_ip="$(dig +short "$DOMAIN" A | tail -1)"
if [[ -z "$domain_ip" ]]; then
  echo "warning: $DOMAIN has no A record yet — Caddy cannot get a certificate" >&2
elif [[ "$domain_ip" != "$server_ip" ]]; then
  echo "warning: $DOMAIN resolves to $domain_ip but the server is $server_ip" >&2
  echo "         fix the DNS record, then re-run (TLS will fail otherwise)" >&2
fi

ADMIN_PASS="${ADMIN_PASS:-$(gen)}"
SYNC_PASS="${SYNC_PASS:-$(gen)}"

# --- server side --------------------------------------------------------------
say "provisioning $HOST"
scp -q "$SCRIPT_DIR/remote-setup.sh" "$HOST:/tmp/entropy-remote-setup.sh"
ssh "$HOST" "chmod +x /tmp/entropy-remote-setup.sh && \
  DOMAIN='$DOMAIN' ACME_EMAIL='$EMAIL' \
  COUCH_ADMIN_PASS='$ADMIN_PASS' SYNC_USER='$SYNC_USER' \
  SYNC_USER_PASS='$SYNC_PASS' DATABASE='$DATABASE' \
  sudo -E /tmp/entropy-remote-setup.sh; rm -f /tmp/entropy-remote-setup.sh"

ENDPOINT="https://$DOMAIN"

say "checking the public endpoint (TLS may take a minute on first run)"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 10 -u "$SYNC_USER:$SYNC_PASS" "$ENDPOINT/$DATABASE" \
       >/dev/null 2>&1; then
    reachable=1; break
  fi
  sleep 4
done
if [[ "${reachable:-0}" != "1" ]]; then
  echo "warning: $ENDPOINT/$DATABASE did not answer yet — check DNS/ports 80,443" >&2
fi

# --- the values for the app ---------------------------------------------------
find_daemon() {
  local candidates=(
    "${ENTROPY_SYNCD:-}"
    "$REPO_ROOT/tools/entropyd/entropyd"
    "$HOME/.entropy-sync/bin/entropyd"
    "/Applications/Entropy Sync.app/Contents/Resources/entropyd"
    "/Applications/entropy.app/Contents/Resources/entropyd"
  )
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

echo
echo "────────────────────────────────────────────────────────────────────"
echo "Сервер готов."
echo
if daemon="$(find_daemon)"; then
  "$daemon" setup-uri \
    --endpoint "$ENDPOINT" --database "$DATABASE" \
    --server-user "$SYNC_USER" --server-password "$SYNC_PASS" \
    ${TRANSFER_SECRET:+--transfer-secret "$TRANSFER_SECRET"}
else
  echo "Бинарь entropyd не найден — setup-URI не сгенерирован."
  echo "В приложении выберите режим «Вручную» и введите:"
fi
echo
echo "Подключение (на случай ручного ввода):"
echo "  Адрес сервера:       $ENDPOINT"
echo "  База данных:         $DATABASE"
echo "  Пользователь:        $SYNC_USER"
echo "  Пароль пользователя: $SYNC_PASS"
echo
echo "Админ CouchDB (для обслуживания, в приложение не вводится):"
echo "  admin / $ADMIN_PASS"
echo
echo "Парольную фразу (E2EE) придумайте сами при настройке первого"
echo "устройства — она нигде здесь не хранится и не восстанавливается."
echo "────────────────────────────────────────────────────────────────────"
