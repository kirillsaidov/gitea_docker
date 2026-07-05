#!/usr/bin/env bash
# =============================================================================
#  setup.sh — interactive .env generator for the Gitea production deployment.
#  Asks a handful of questions, generates all secrets, writes ./.env
#  Re-runnable: it backs up any existing .env before overwriting.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_ylw" "$c_off" "$*"; }

# --- prompt helpers ---------------------------------------------------------
# ask VAR "Question" "default"
ask() {
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [ -n "$__def" ]; then
    read -r -p "$__q ${c_dim}[$__def]${c_off}: " __ans || true
    __ans="${__ans:-$__def}"
  else
    while true; do
      read -r -p "$__q: " __ans || true
      [ -n "$__ans" ] && break
      warn "This one is required."
    done
  fi
  printf -v "$__var" '%s' "$__ans"
}

# ask_yn VAR "Question" "Y|N"   -> sets VAR to true/false
ask_yn() {
  local __var="$1" __q="$2" __def="${3:-N}" __ans __hint
  case "$__def" in [Yy]*) __hint="Y/n";; *) __hint="y/N";; esac
  read -r -p "$__q ${c_dim}[$__hint]${c_off}: " __ans || true
  __ans="${__ans:-$__def}"
  case "$__ans" in [Yy]*) printf -v "$__var" 'true';; *) printf -v "$__var" 'false';; esac
}

# --- secret generators ------------------------------------------------------
gen_pass() {  # url/db-safe alphanumeric (hex)
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Read a value from the current (old) .env, if present. Used to REUSE existing
# secrets on a re-run — regenerating DB passwords would not match the already-
# initialized MySQL data dir (a bind mount that survives `docker compose down -v`).
prev() { [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true; }

# Prefer Gitea's own generator (proper format); fall back to a long hex secret.
GITEA_VERSION="$(grep -oE 'gitea/gitea:[0-9]+\.[0-9]+\.[0-9]+' "$COMPOSE_FILE" | head -n1 | cut -d: -f2 || true)"
GITEA_VERSION="${GITEA_VERSION:-latest}"
gen_gitea_secret() {  # $1 = SECRET_KEY | INTERNAL_TOKEN
  local out=""
  if command -v docker >/dev/null 2>&1; then
    out="$(docker run --rm "gitea/gitea:${GITEA_VERSION}" gitea generate secret "$1" 2>/dev/null || true)"
  fi
  [ -n "$out" ] && { printf '%s' "$out"; return; }
  # fallback
  if [ "$1" = "SECRET_KEY" ]; then gen_pass; else printf '%s%s' "$(gen_pass)" "$(gen_pass)"; fi
}

# ===========================================================================
head "Gitea production setup  ${c_dim}(image: gitea/gitea:${GITEA_VERSION})${c_off}"
say  "Answer the prompts; secrets are generated for you. Ctrl-C to abort."

if [ -f "$ENV_FILE" ]; then
  BACKUP="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo old)"
  warn "$ENV_FILE already exists — it will be backed up to $BACKUP"
fi

# --- questions --------------------------------------------------------------
head "1) Container & network"
ask   CONTAINER_NAME "Container name" "gitea"
ask   GITEA_DOMAIN   "Public domain served via Cloudflare Tunnel / proxy (e.g. git.example.com)"
ask_yn BEHIND_PROXY  "Serve HTTPS via a Cloudflare Tunnel or reverse proxy? (recommended)" "Y"
ask   GITEA_FRONTEND_PORT "Web UI port (host side)" "8989"
ask   GITEA_SSH_PORT      "Git SSH port (host side)" "222"
#  SSH bypasses the tunnel, so its clone URL needs a directly-reachable host.
#  Default to this machine's first LAN IP (keep SSH LAN-only).
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
ask   GITEA_SSH_DOMAIN "Host for SSH clone URLs (LAN IP / direct host)" "${LAN_IP:-$GITEA_DOMAIN}"

if [ "$BEHIND_PROXY" = "true" ]; then
  GITEA_WEB_BIND="127.0.0.1"
  DEF_ROOT_URL="https://${GITEA_DOMAIN}/"
else
  GITEA_WEB_BIND="0.0.0.0"
  DEF_ROOT_URL="http://${GITEA_DOMAIN}:${GITEA_FRONTEND_PORT}/"
fi
ask   GITEA_ROOT_URL "External root URL" "$DEF_ROOT_URL"

head "2) Storage"
ask   GITEA_VOLUME    "Gitea data volume (host path)" "/gitea"
ask   GITEA_DB_VOLUME "Database volume (host path)" "${GITEA_VOLUME}/mysql"

head "3) Access policy"
say   "${c_dim}Self-registration and the install wizard are always locked.${c_off}"
ask_yn REQUIRE_SIGNIN "Require visitors to sign in even to VIEW repos?" "N"
GITEA_REQUIRE_SIGNIN_VIEW="$REQUIRE_SIGNIN"

head "4) Database"
ask   DB_NAME "Database name" "gitea"
ask   DB_USER "Database user" "gitea"

head "5) Actions runner (optional)"
ask_yn WITH_RUNNER "Configure an Actions runner now?" "N"
if [ "$WITH_RUNNER" = "true" ]; then
  ask RUNNER_NAME       "Runner name" "main-runner"
  ask RUNNER_GITEA_URL  "URL the runner uses to reach Gitea (server IP, not localhost)" "http://${GITEA_DOMAIN}:${GITEA_FRONTEND_PORT}"
  ask RUNNER_TOKEN      "Runner registration token (leave blank to add later)" " "
  RUNNER_TOKEN="$(printf '%s' "$RUNNER_TOKEN" | tr -d '[:space:]')"
else
  RUNNER_NAME="main-runner"
  RUNNER_GITEA_URL="http://<server-ip>:${GITEA_FRONTEND_PORT}"
  RUNNER_TOKEN=""
fi

# --- secrets: REUSE if an .env already has them, else generate --------------
head "Secrets…"
secret() {  # secret VAR_LABEL  ENV_KEY  GENERATOR_CMD…
  local label="$1" key="$2"; shift 2
  local existing; existing="$(prev "$key")"
  if [ -n "$existing" ] && [ "$existing" != "changeme" ] && [ "${existing#changeme}" = "$existing" ]; then
    printf '%s' "$existing"; printf '%s (reused from existing .env)\n' "$label" >&2
  else
    "$@"; printf '%s (generated)\n' "$label" >&2
  fi
}
DB_PASSWORD="$(secret 'DB password'        GITEA__database__PASSWD          gen_pass)"
DB_ROOT_PASSWORD="$(secret 'DB root pass'  MYSQL_ROOT_PASSWORD             gen_pass)"
SECRET_KEY="$(secret 'SECRET_KEY'          GITEA__security__SECRET_KEY     gen_gitea_secret SECRET_KEY)"
INTERNAL_TOKEN="$(secret 'INTERNAL_TOKEN'  GITEA__security__INTERNAL_TOKEN gen_gitea_secret INTERNAL_TOKEN)"

# --- write .env -------------------------------------------------------------
[ -f "$ENV_FILE" ] && cp "$ENV_FILE" "$BACKUP" && warn "backed up old .env -> $BACKUP"

cat > "$ENV_FILE" <<EOF
# =============================================================================
#  Gitea — production environment (generated by setup.sh)
#  Secret file. Do NOT commit.
# =============================================================================

#  --- Gitea container ---
CONTAINER_NAME=${CONTAINER_NAME}
GITEA_FRONTEND_PORT=${GITEA_FRONTEND_PORT}
GITEA_WEB_BIND=${GITEA_WEB_BIND}
GITEA_SSH_PORT=${GITEA_SSH_PORT}
GITEA_VOLUME=${GITEA_VOLUME}
GITEA_DB_VOLUME=${GITEA_DB_VOLUME}

#  --- Public address ---
GITEA_DOMAIN=${GITEA_DOMAIN}
GITEA_SSH_DOMAIN=${GITEA_SSH_DOMAIN}
GITEA_ROOT_URL=${GITEA_ROOT_URL}

#  --- Access policy ---
GITEA_REQUIRE_SIGNIN_VIEW=${GITEA_REQUIRE_SIGNIN_VIEW}

#  --- Security secrets ---
GITEA__security__SECRET_KEY=${SECRET_KEY}
GITEA__security__INTERNAL_TOKEN=${INTERNAL_TOKEN}

#  --- Database ---
GITEA__database__DB_TYPE=mysql
GITEA__database__HOST=db:3306
GITEA__database__NAME=${DB_NAME}
GITEA__database__USER=${DB_USER}
GITEA__database__PASSWD=${DB_PASSWORD}

MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
MYSQL_USER=${DB_USER}
MYSQL_PASSWORD=${DB_PASSWORD}
MYSQL_DATABASE=${DB_NAME}

#  --- Actions runner ---
RUNNER_CONTAINER_NAME=gitea-runner
RUNNER_NAME=${RUNNER_NAME}
RUNNER_GITEA_URL=${RUNNER_GITEA_URL}
RUNNER_TOKEN=${RUNNER_TOKEN}
EOF

chmod 600 "$ENV_FILE" 2>/dev/null || true
ok "wrote $ENV_FILE (permissions 600)"

# --- next steps -------------------------------------------------------------
head "Next steps"
cat <<EOF
1. Make sure the data dir exists and is owned by UID/GID 1000:
     ${c_dim}sudo mkdir -p ${GITEA_VOLUME} ${GITEA_DB_VOLUME} && sudo chown -R 1000:1000 ${GITEA_VOLUME}${c_off}

2. Start the stack:
     ${c_dim}docker compose up -d${c_off}

3. Registration is disabled, so create YOUR admin account from the CLI.
   ('server' = compose service name; '-u git' because Gitea won't run as root):
     ${c_dim}docker compose exec -u git server gitea admin user create \\
       --admin --username YOURNAME --email you@${GITEA_DOMAIN} \\
       --password 'PICK-A-PASSWORD' --must-change-password=false${c_off}
   (You can change this password on the server anytime.)

EOF
if [ "$BEHIND_PROXY" = "true" ]; then
cat <<EOF
4. Point your reverse proxy (Caddy/nginx/Traefik) at 127.0.0.1:${GITEA_FRONTEND_PORT}
   and terminate TLS for ${GITEA_DOMAIN}. Open only 443 and ${GITEA_SSH_PORT} in the firewall.
EOF
else
warn "You chose NO reverse proxy: the web UI is exposed on ${GITEA_WEB_BIND}:${GITEA_FRONTEND_PORT} over plain HTTP."
warn "Logins and tokens will travel unencrypted — add TLS before real use."
fi
if [ "$WITH_RUNNER" = "true" ] && [ -z "$RUNNER_TOKEN" ]; then
  warn "Runner token is blank — get one at ${GITEA_ROOT_URL%/}/-/admin/runners and set RUNNER_TOKEN in .env, then: docker compose up -d runner"
fi
say ""
ok "Done."
