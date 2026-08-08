#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_ENV="${IPPONTIPP_BOOTSTRAP_ENV:-/root/ippontipp-bootstrap.env}"
DEFAULT_INSTALLER_BASE_URL="https://raw.githubusercontent.com/1OAdTZXI/IpponTipp-Proxmox/main"
UPDATER_BIN="/usr/local/sbin/ippontipp-deploy"
UV_VERSION="0.12.1"

# Debian's minimal LXC template provides C.UTF-8, but not necessarily the
# locale inherited from the Proxmox host (commonly en_US.UTF-8).
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

log() {
  printf '[IpponTipp installer] %s\n' "$*"
}

fail() {
  printf '[IpponTipp installer] ERROR: %s\n' "$*" >&2
  exit 1
}

decode_base64() {
  printf '%s' "$1" | base64 --decode
}

prompt_missing_configuration() {
  local token
  printf 'Deployment channel [release-candidate/production]: '
  read -r DEPLOYMENT_CHANNEL
  printf 'Private GitHub repository [1OAdTZXI/IpponTipp]: '
  read -r GITHUB_REPOSITORY
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-1OAdTZXI/IpponTipp}"
  read -r -s -p 'Fine-grained GitHub token (Contents: read): ' token
  printf '\n'
  GITHUB_TOKEN_B64="$(printf '%s' "$token" | base64 -w 0)"
  EMAIL_MODE="console"
  REVERSE_PROXY="false"
  PUBLIC_URL=""
}

load_bootstrap_configuration() {
  if [[ -r "$BOOTSTRAP_ENV" ]]; then
    # The host creates this root-only file and transfers it without command-line secrets.
    # shellcheck disable=SC1090
    source "$BOOTSTRAP_ENV"
  else
    prompt_missing_configuration
  fi

  : "${GITHUB_TOKEN_B64:?Missing GitHub token}"
  : "${DEPLOYMENT_CHANNEL:?Missing deployment channel}"
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-1OAdTZXI/IpponTipp}"
  INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-$DEFAULT_INSTALLER_BASE_URL}"
  REVERSE_PROXY="${REVERSE_PROXY:-false}"
  EMAIL_MODE="${EMAIL_MODE:-console}"

  [[ "$DEPLOYMENT_CHANNEL" == "release-candidate" || "$DEPLOYMENT_CHANNEL" == "production" ]] ||
    fail "Invalid deployment channel: $DEPLOYMENT_CHANNEL"
}

install_os_dependencies() {
  log "Installing operating-system dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    default-libmysqlclient-dev \
    gettext-base \
    gnupg \
    mariadb-client \
    mariadb-server \
    nginx \
    openssl \
    pkg-config \
    python3 \
    redis-server

  install -d -m 0755 /etc/apt/keyrings
  local nodesource_key="/tmp/nodesource-repo.gpg.key"
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o "$nodesource_key"
  gpg --dearmor --yes --output /etc/apt/keyrings/nodesource.gpg "$nodesource_key"
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
  printf '%s\n' \
    'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' \
    >/etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y --no-install-recommends nodejs

  local uv_installer="/tmp/uv-install.sh"
  curl -fsSL "https://astral.sh/uv/$UV_VERSION/install.sh" -o "$uv_installer"
  export PATH="/usr/local/bin:$PATH"
  UV_UNMANAGED_INSTALL=/usr/local/bin sh "$uv_installer"

  node --version
  npm --version
  if [[ ! -x /usr/local/bin/uv ]]; then
    fail "uv was installed to /usr/local/bin, but the binary is missing"
  fi
  /usr/local/bin/uv --version
}

escape_env_value() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "Environment values cannot contain newlines"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

write_env() {
  local file="$1"
  local key="$2"
  local value="$3"
  printf '%s=%s\n' "$key" "$(escape_env_value "$value")" >>"$file"
}

enable_and_start_service() {
  local service="$1"
  if systemctl enable --now "$service"; then
    return 0
  fi

  systemctl --no-pager --full status "$service" >&2 || true
  journalctl --no-pager -u "$service" -n 50 >&2 || true
  fail "Could not start required service: $service"
}

configure_database_and_filesystem() {
  log "Creating service account and MariaDB database"
  enable_and_start_service mariadb.service
  enable_and_start_service redis-server.service
  [[ "$(redis-cli ping)" == "PONG" ]] || fail "Redis did not respond to PING"

  if ! id ippontipp >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/ippontipp --create-home --shell /usr/sbin/nologin ippontipp
  fi

  install -d -o ippontipp -g ippontipp -m 0750 /opt/ippontipp/releases /var/lib/ippontipp
  install -d -o root -g root -m 0700 /etc/ippontipp /usr/local/lib/ippontipp

  local database_password django_secret
  database_password="$(openssl rand -hex 24)"
  django_secret="$(openssl rand -hex 48)"

  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ippontipp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'ippontipp'@'localhost' IDENTIFIED BY '$database_password';
ALTER USER 'ippontipp'@'localhost' IDENTIFIED BY '$database_password';
GRANT ALL PRIVILEGES ON ippontipp.* TO 'ippontipp'@'localhost';
FLUSH PRIVILEGES;
SQL

  local container_ip public_url public_host
  container_ip="$(hostname -I | awk '{print $1}')"
  [[ -n "$container_ip" ]] || fail "The container has no IPv4 address"
  public_url="${PUBLIC_URL:-http://$container_ip}"
  public_host="$(python3 -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).hostname or "")' "$public_url")"
  [[ -n "$public_host" ]] || fail "Invalid public URL: $public_url"

  local app_env="/etc/ippontipp/app.env"
  : >"$app_env"
  write_env "$app_env" DJANGO_SECRET_KEY "$django_secret"
  write_env "$app_env" IPPONTIPP_PUBLIC_URL "$public_url"
  write_env "$app_env" IPPONTIPP_ALLOWED_HOSTS "$public_host,$container_ip,localhost,127.0.0.1"
  write_env "$app_env" IPPONTIPP_CSRF_TRUSTED_ORIGINS "$public_url"
  write_env "$app_env" IPPONTIPP_BEHIND_REVERSE_PROXY "$REVERSE_PROXY"
  write_env "$app_env" IPPONTIPP_FORCE_HTTPS "false"
  write_env "$app_env" MARIA_DBNAME "ippontipp"
  write_env "$app_env" MARIA_DBUSER "ippontipp"
  write_env "$app_env" MARIA_DBPASS "$database_password"
  write_env "$app_env" MARIA_DBHOST "localhost"
  write_env "$app_env" MARIA_DBPORT "3306"
  write_env "$app_env" CELERY_BROKER_URL "redis://localhost:6379/0"
  write_env "$app_env" CELERY_RESULT_BACKEND "redis://localhost:6379/0"
  write_env "$app_env" IPPONTIPP_SYNC_LOCK_FILE "/var/lib/ippontipp/sync-competitions.lock"

  if [[ "$EMAIL_MODE" == "smtp" ]]; then
    write_env "$app_env" EMAIL_BACKEND "django.core.mail.backends.smtp.EmailBackend"
    write_env "$app_env" EMAIL_HOST "${EMAIL_HOST:?Missing EMAIL_HOST}"
    write_env "$app_env" EMAIL_PORT "${EMAIL_PORT:-587}"
    write_env "$app_env" EMAIL_USE_TLS "${EMAIL_USE_TLS:-true}"
    write_env "$app_env" EMAIL_HOST_USER "$(decode_base64 "${EMAIL_HOST_USER_B64:?Missing SMTP user}")"
    write_env "$app_env" EMAIL_HOST_PASSWORD "$(decode_base64 "${EMAIL_HOST_PASSWORD_B64:?Missing SMTP password}")"
    write_env "$app_env" DEFAULT_FROM_EMAIL "${DEFAULT_FROM_EMAIL:?Missing default sender}"
  else
    write_env "$app_env" EMAIL_BACKEND "django.core.mail.backends.console.EmailBackend"
    write_env "$app_env" DEFAULT_FROM_EMAIL "ippontipp@localhost"
  fi
  chmod 0600 "$app_env"

  local updater_env="/etc/ippontipp/updater.env"
  : >"$updater_env"
  write_env "$updater_env" GITHUB_TOKEN "$(decode_base64 "$GITHUB_TOKEN_B64")"
  write_env "$updater_env" GITHUB_REPOSITORY "$GITHUB_REPOSITORY"
  write_env "$updater_env" GITHUB_API_VERSION "2026-03-10"
  write_env "$updater_env" DEPLOYMENT_CHANNEL "$DEPLOYMENT_CHANNEL"
  chmod 0600 "$updater_env"

  printf '%s' "$public_url" >/var/lib/ippontipp/access-url
  chown ippontipp:ippontipp /var/lib/ippontipp/access-url
}

download_public_asset() {
  local relative_path="$1"
  local destination="$2"
  curl -fsSL "$INSTALLER_BASE_URL/$relative_path" -o "$destination"
}

install_runtime_assets() {
  log "Installing updater, systemd units, and Nginx configuration"
  download_public_asset bin/ippontipp-deploy "$UPDATER_BIN"
  download_public_asset lib/release_selector.py /usr/local/lib/ippontipp/release_selector.py
  chmod 0755 "$UPDATER_BIN" /usr/local/lib/ippontipp/release_selector.py

  local service
  for service in ippontipp-web ippontipp-worker ippontipp-beat; do
    download_public_asset \
      "runtime/systemd/$service.service" "/etc/systemd/system/$service.service"
  done

  download_public_asset runtime/nginx/ippontipp.conf /etc/nginx/sites-available/ippontipp.conf
  rm -f /etc/nginx/sites-enabled/default
  ln -sfn /etc/nginx/sites-available/ippontipp.conf /etc/nginx/sites-enabled/ippontipp.conf

  nginx -t
  systemctl daemon-reload
  systemctl enable nginx.service ippontipp-web.service ippontipp-worker.service ippontipp-beat.service
  systemctl restart nginx.service
}

main() {
  [[ "$EUID" -eq 0 ]] || fail "Run this installer as root"
  load_bootstrap_configuration
  install_os_dependencies
  configure_database_and_filesystem
  install_runtime_assets
  "$UPDATER_BIN" update

  rm -f "$BOOTSTRAP_ENV"
  log "Installation completed: $(cat /var/lib/ippontipp/access-url)"
  log "Manual updates: ippontipp-deploy check && ippontipp-deploy update"
}

main "$@"
