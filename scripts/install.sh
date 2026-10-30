#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/CamelBruh/Motorsport-Session-Countdown.git"
REPO_BRANCH="${REPO_BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/motorsport}"
SERVICE_NAME="motorsport"
APP_USER="motorsport"
NODE_MAJOR=22

log() {
    echo -e "\n[MSCountdown] $*"
}

fail() {
    echo "[MSCountdown] ERROR: $*" >&2
    exit 1
}

[[ "$EUID" -eq 0 ]] || fail "Run this installer as root."

if [[ ! -f /etc/os-release ]]; then
    fail "Cannot identify operating system."
fi

. /etc/os-release

case "${ID}:${VERSION_ID}" in
    debian:12|debian:13|ubuntu:24.04)
        ;;
    *)
        fail "Unsupported operating system: ${PRETTY_NAME}"
        ;;
esac

command -v systemctl >/dev/null || fail "systemd is required."
[[ "$(ps -p 1 -o comm= | tr -d ' ')" == "systemd" ]] \
    || fail "systemd must be running as PID 1."

# Bootstrap: clone the public GitHub repository.
if [[ ! -f "$APP_DIR/WebServer/server.js" ]]; then
    if [[ -e "$APP_DIR" ]] && [[ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
        fail "$APP_DIR exists and is not an MSCountdown installation."
    fi

    log "Installing Git and prerequisites."
    apt-get update
    apt-get install -y ca-certificates curl git

    log "Cloning MSCountdown from GitHub."
    mkdir -p "$(dirname "$APP_DIR")"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"

    log "Starting installer from the cloned repository."
    export APP_DIR REPO_BRANCH
    exec bash "$APP_DIR/scripts/install.sh"
fi

# Validate the application checkout.
for required_file in \
    "$APP_DIR/package.json" \
    "$APP_DIR/package-lock.json" \
    "$APP_DIR/WebServer/server.js"
do
    [[ -f "$required_file" ]] || fail "Required file missing: $required_file"
done

log "Installing system dependencies."
apt-get update
apt-get install -y ca-certificates curl git build-essential python3

log "Checking Node.js."
if ! command -v node >/dev/null || \
   [[ "$(node -p 'process.versions.node.split(".")[0]')" != "$NODE_MAJOR" ]]; then
    log "Installing Node.js ${NODE_MAJOR}."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
fi

NODE_VERSION="$(node -p 'process.versions.node')"
log "Using Node.js ${NODE_VERSION}."

if ! getent group "$APP_USER" >/dev/null; then
    groupadd --system "$APP_USER"
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --gid "$APP_USER" \
        --home-dir /nonexistent --shell /usr/sbin/nologin "$APP_USER"
fi

log "Installing application dependencies."
cd "$APP_DIR"
npm ci --omit=dev --no-audit --no-fund

log "Setting application permissions."
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 755 "$APP_DIR"
chmod 755 "$APP_DIR/WebServer"

log "Creating systemd service."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE
[Unit]
Description=Motorsport Session Countdown
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/node WebServer/server.js
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=3000

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

log "Installation complete."
echo
echo "Application: http://localhost:3000/"
echo "Display:     http://localhost:3000/display.html"
echo "API:         http://localhost:3000/events"
echo
echo "Service: systemctl status ${SERVICE_NAME}"
echo "Logs:    journalctl -u ${SERVICE_NAME} -f"
