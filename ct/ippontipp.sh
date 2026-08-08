#!/usr/bin/env bash
set -Eeuo pipefail

APP="IpponTipp"
DEFAULT_INSTALLER_BASE_URL="https://raw.githubusercontent.com/1OAdTZXI/IpponTipp-Proxmox/main"
INSTALLER_BASE_URL="${IPPONTIPP_INSTALLER_BASE_URL:-$DEFAULT_INSTALLER_BASE_URL}"

info() {
  printf '\033[1;36m[IpponTipp]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[IpponTipp] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

prompt() {
  local variable="$1"
  local label="$2"
  local default="$3"
  local value
  read -r -p "$label [$default]: " value
  printf -v "$variable" '%s' "${value:-$default}"
}

yes_no() {
  local label="$1"
  local default="${2:-no}"
  local suffix='[y/N]'
  [[ "$default" == "yes" ]] && suffix='[Y/n]'
  local answer
  read -r -p "$label $suffix: " answer
  answer="${answer:-$default}"
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

first_active_storage() {
  local content="$1"
  pvesm status -content "$content" 2>/dev/null |
    awk 'NR > 1 && $3 == "active" {print $1; exit}'
}

validate_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive integer"
}

preflight() {
  [[ "$EUID" -eq 0 ]] || fail "Run this script as root on the Proxmox host"
  command -v pveversion >/dev/null 2>&1 || fail "This is not a Proxmox VE host"
  command -v pct >/dev/null 2>&1 || fail "pct is not installed"
  command -v pveam >/dev/null 2>&1 || fail "pveam is not installed"
  command -v pvesm >/dev/null 2>&1 || fail "pvesm is not installed"
  command -v curl >/dev/null 2>&1 || fail "curl is not installed"

  local pve_major architecture
  pve_major="$(pveversion | sed -n 's#^pve-manager/\([0-9][0-9]*\).*#\1#p')"
  [[ "$pve_major" =~ ^[0-9]+$ && "$pve_major" -ge 9 ]] ||
    fail "This installer supports Proxmox VE 9 or newer"
  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == "amd64" ]] || fail "This first installer version supports Intel/AMD64 only"
}

select_channel() {
  printf '\nDeployment channel:\n  1) release-candidate\n  2) production\n'
  local selection
  read -r -p 'Selection [1]: ' selection
  case "${selection:-1}" in
    1)
      DEPLOYMENT_CHANNEL="release-candidate"
      DEFAULT_HOSTNAME="ippontipp-rc"
      ;;
    2)
      DEPLOYMENT_CHANNEL="production"
      DEFAULT_HOSTNAME="ippontipp-prod"
      ;;
    *) fail "Invalid deployment channel selection" ;;
  esac
}

collect_container_configuration() {
  CTID="$(pvesh get /cluster/nextid)"
  HOSTNAME="$DEFAULT_HOSTNAME"
  CORES=2
  MEMORY=3072
  DISK=16
  BRIDGE=vmbr0
  IP_CONFIG=dhcp
  GATEWAY=""
  ROOT_STORAGE="$(first_active_storage rootdir)"
  TEMPLATE_STORAGE="$(first_active_storage vztmpl)"

  [[ -n "$ROOT_STORAGE" ]] || fail "No active Proxmox storage with rootdir content found"
  [[ -n "$TEMPLATE_STORAGE" ]] || fail "No active Proxmox storage with vztmpl content found"

  printf '\nSetup mode:\n  1) Default (2 CPU, 3 GiB RAM, 16 GiB disk, DHCP)\n  2) Advanced\n'
  local setup_mode
  read -r -p 'Selection [1]: ' setup_mode
  if [[ "${setup_mode:-1}" == "2" ]]; then
    prompt CTID "Container ID" "$CTID"
    prompt HOSTNAME "Hostname" "$HOSTNAME"
    prompt CORES "CPU cores" "$CORES"
    prompt MEMORY "Memory in MiB" "$MEMORY"
    prompt DISK "Root disk in GiB" "$DISK"
    prompt ROOT_STORAGE "Rootfs storage" "$ROOT_STORAGE"
    prompt TEMPLATE_STORAGE "Template storage" "$TEMPLATE_STORAGE"
    prompt BRIDGE "Network bridge" "$BRIDGE"
    if ! yes_no "Use DHCP" yes; then
      prompt IP_CONFIG "IPv4 address with CIDR" "192.168.1.50/24"
      prompt GATEWAY "IPv4 gateway" "192.168.1.1"
    fi
  elif [[ "${setup_mode:-1}" != "1" ]]; then
    fail "Invalid setup mode"
  fi

  validate_positive_integer "Container ID" "$CTID"
  validate_positive_integer "CPU cores" "$CORES"
  validate_positive_integer "Memory" "$MEMORY"
  validate_positive_integer "Disk size" "$DISK"
  [[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "Invalid hostname"
  ip link show "$BRIDGE" >/dev/null 2>&1 || fail "Network bridge does not exist: $BRIDGE"
  pvesm status --storage "$ROOT_STORAGE" >/dev/null 2>&1 || fail "Unknown root storage: $ROOT_STORAGE"
  pvesm status --storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || fail "Unknown template storage: $TEMPLATE_STORAGE"
  [[ ! -e "/etc/pve/lxc/$CTID.conf" && ! -e "/etc/pve/qemu-server/$CTID.conf" ]] ||
    fail "Container ID $CTID is already in use"
}

collect_application_configuration() {
  GITHUB_REPOSITORY="1OAdTZXI/IpponTipp"
  prompt GITHUB_REPOSITORY "Private GitHub repository" "$GITHUB_REPOSITORY"

  local github_token
  read -r -s -p 'Fine-grained GitHub token (repository Contents: read): ' github_token
  printf '\n'
  [[ "$github_token" =~ ^[A-Za-z0-9_]+$ ]] || fail "The GitHub token has an unexpected format"
  GITHUB_TOKEN_B64="$(printf '%s' "$github_token" | base64 -w 0)"
  unset github_token

  REVERSE_PROXY=false
  PUBLIC_URL=""
  if yes_no "Will an existing reverse proxy access this container" no; then
    REVERSE_PROXY=true
    prompt PUBLIC_URL "External URL seen by browsers" "https://ippontipp.example.test"
    [[ "$PUBLIC_URL" =~ ^https?://[^[:space:]]+$ ]] || fail "The external URL must use http:// or https://"
  fi

  EMAIL_MODE=console
  if yes_no "Configure an SMTP server now" no; then
    EMAIL_MODE=smtp
    prompt EMAIL_HOST "SMTP host" "smtp.gmail.com"
    prompt EMAIL_PORT "SMTP port" "587"
    EMAIL_USE_TLS=true
    if ! yes_no "Use SMTP STARTTLS" yes; then
      EMAIL_USE_TLS=false
    fi
    local email_user email_password
    read -r -p 'SMTP user: ' email_user
    read -r -s -p 'SMTP password: ' email_password
    printf '\n'
    EMAIL_HOST_USER_B64="$(printf '%s' "$email_user" | base64 -w 0)"
    EMAIL_HOST_PASSWORD_B64="$(printf '%s' "$email_password" | base64 -w 0)"
    prompt DEFAULT_FROM_EMAIL "Default sender" "$email_user"
    unset email_user email_password
  fi
}

download_template() {
  info "Locating the latest Debian 13 LXC template"
  pveam update >/dev/null
  TEMPLATE="$(
    pveam available --section system |
      awk '$2 ~ /^debian-13-standard_.*_amd64.tar.zst$/ {print $2}' |
      sort -V |
      tail -n 1
  )"
  [[ -n "$TEMPLATE" ]] || fail "No Debian 13 amd64 template is available"

  TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/$TEMPLATE"
  if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $1}' | grep -Fxq "$TEMPLATE_REF"; then
    info "Downloading $TEMPLATE"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi
}

create_container() {
  local net0="name=eth0,bridge=$BRIDGE,type=veth,ip=$IP_CONFIG"
  [[ -n "$GATEWAY" ]] && net0+=",gw=$GATEWAY"

  info "Creating unprivileged Debian 13 container $CTID"
  pct create "$CTID" "$TEMPLATE_REF" \
    --arch amd64 \
    --cores "$CORES" \
    --features nesting=1 \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --net0 "$net0" \
    --onboot 1 \
    --ostype debian \
    --rootfs "$ROOT_STORAGE:$DISK" \
    --start 1 \
    --swap 512 \
    --unprivileged 1

  local attempt
  for attempt in {1..30}; do
    if pct exec "$CTID" -- hostname -I 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
      return 0
    fi
    sleep 1
  done
  fail "Container $CTID did not receive an IPv4 address"
}

write_bootstrap_environment() {
  local output="$1"
  umask 077
  {
    printf 'DEPLOYMENT_CHANNEL=%q\n' "$DEPLOYMENT_CHANNEL"
    printf 'GITHUB_REPOSITORY=%q\n' "$GITHUB_REPOSITORY"
    printf 'GITHUB_TOKEN_B64=%q\n' "$GITHUB_TOKEN_B64"
    printf 'INSTALLER_BASE_URL=%q\n' "$INSTALLER_BASE_URL"
    printf 'REVERSE_PROXY=%q\n' "$REVERSE_PROXY"
    printf 'PUBLIC_URL=%q\n' "$PUBLIC_URL"
    printf 'EMAIL_MODE=%q\n' "$EMAIL_MODE"
    if [[ "$EMAIL_MODE" == "smtp" ]]; then
      printf 'EMAIL_HOST=%q\n' "$EMAIL_HOST"
      printf 'EMAIL_PORT=%q\n' "$EMAIL_PORT"
      printf 'EMAIL_USE_TLS=%q\n' "$EMAIL_USE_TLS"
      printf 'EMAIL_HOST_USER_B64=%q\n' "$EMAIL_HOST_USER_B64"
      printf 'EMAIL_HOST_PASSWORD_B64=%q\n' "$EMAIL_HOST_PASSWORD_B64"
      printf 'DEFAULT_FROM_EMAIL=%q\n' "$DEFAULT_FROM_EMAIL"
    fi
  } >"$output"
}

run_container_installer() {
  local bootstrap_file installer_file
  bootstrap_file="$HOST_TEMP_DIR/bootstrap.env"
  installer_file="$HOST_TEMP_DIR/ippontipp-install.sh"

  write_bootstrap_environment "$bootstrap_file"
  curl -fsSL "$INSTALLER_BASE_URL/install/ippontipp-install.sh" -o "$installer_file"

  pct push "$CTID" "$bootstrap_file" /root/ippontipp-bootstrap.env --perms 0600
  pct push "$CTID" "$installer_file" /root/ippontipp-install.sh --perms 0700
  info "Installing IpponTipp inside container $CTID"
  if ! pct exec "$CTID" -- bash /root/ippontipp-install.sh; then
    fail "Installation failed; container $CTID was kept for inspection"
  fi

  local container_ip
  container_ip="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
  info "$APP installation completed"
  info "Container: $CTID ($HOSTNAME)"
  info "Direct HTTP endpoint: http://$container_ip"
  [[ -n "$PUBLIC_URL" ]] && info "Browser-facing URL: $PUBLIC_URL"
  info "Manual updates inside the LXC: ippontipp-deploy update"
}

main() {
  HOST_TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$HOST_TEMP_DIR"' EXIT
  preflight
  select_channel
  collect_container_configuration
  collect_application_configuration
  download_template
  create_container
  run_container_installer
}

main "$@"
