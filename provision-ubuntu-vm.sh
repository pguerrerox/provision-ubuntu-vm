#!/usr/bin/env bash
set -euo pipefail

# =========================
# Ubuntu VM Provision Script
# =========================
# Features:
# 1. Change hostname
# 2. Configure static IP using netplan
# 3. Optionally install:
#    - nvm
#    - latest Node LTS
#    - fish shell
#    - oh-my-posh
#    - oh-my-posh atomic theme for fish
#
# Run with:
#   chmod +x provision-ubuntu-vm.sh
#   sudo ./provision-ubuntu-vm.sh
#
# Notes:
# - Must run with sudo/root because hostname and netplan require it.
# - nvm installs per-user, so it is installed for the original sudo user.

# ---------- Helpers ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET='\033[0m'
  C_INFO='\033[1;34m'
  C_WARN='\033[1;33m'
  C_ERR='\033[1;31m'
  C_QUESTION='\033[1;36m'
  C_EXAMPLE='\033[0;32m'
  C_SUCCESS='\033[1;32m'
else
  C_RESET=''
  C_INFO=''
  C_WARN=''
  C_ERR=''
  C_QUESTION=''
  C_EXAMPLE=''
  C_SUCCESS=''
fi

log()  { printf "\n%b[INFO]%b %s\n" "$C_INFO" "$C_RESET" "$*"; }
warn() { printf "\n%b[WARN]%b %s\n" "$C_WARN" "$C_RESET" "$*" >&2; }
err()  { printf "\n%b[ERROR]%b %s\n" "$C_ERR" "$C_RESET" "$*" >&2; }
example_text() { printf "%b%s%b" "$C_EXAMPLE" "$*" "$C_RESET"; }

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local reply
  local prefix

  prefix="${C_QUESTION}[QUESTION]${C_RESET}"

  while true; do
    if [[ "$default" == "y" ]]; then
      read -r -p "${prefix} ${prompt} [Y/n]: " reply || true
      reply="${reply:-y}"
    else
      read -r -p "${prefix} ${prompt} [y/N]: " reply || true
      reply="${reply:-n}"
    fi

    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run this script with sudo or as root."
    exit 1
  fi
}

get_target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  else
    # fallback if root directly launched the script
    logname 2>/dev/null || echo "root"
  fi
}

run_as_user() {
  local target_user="$1"
  shift
  sudo -u "$target_user" -H bash -lc "$*"
}

append_if_missing() {
  local file="$1"
  local line="$2"

  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '\n%s\n' "$line" >> "$file"
  fi
}

# ---------- Validation ----------
validate_hostname() {
  local h="$1"
  [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

validate_cidr() {
  local ipcidr="$1"
  local ip prefix

  [[ "$ipcidr" == */* ]] || return 1
  ip="${ipcidr%/*}"
  prefix="${ipcidr#*/}"

  validate_ip "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 ))
}

validate_ip() {
  local ip="$1"
  local a b c d extra
  IFS=. read -r a b c d extra <<< "$ip"
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -z "${extra:-}" ]] || return 1

  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

# ---------- Hostname ----------
change_hostname() {
  local current_hostname new_hostname
  current_hostname="$(hostnamectl --static status 2>/dev/null || hostname)"
  echo "Current hostname: ${current_hostname}"

  while true; do
    read -r -p "${C_QUESTION}[QUESTION]${C_RESET} Enter new hostname (example: $(example_text "ubuntu-dev")): " new_hostname
    if validate_hostname "$new_hostname"; then
      break
    fi
    echo "Invalid hostname. Use letters, numbers, and hyphens only."
  done

  log "Setting hostname to ${new_hostname}"
  if ! hostnamectl set-hostname "$new_hostname"; then
    err "Failed to set hostname with hostnamectl."
    exit 1
  fi

  if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${new_hostname}/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$new_hostname" >> /etc/hosts
  fi

  log "Hostname updated."
}

# ---------- Network / Netplan ----------
choose_interface() {
  mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|virbr|tun|tap)')
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    err "No network interfaces found."
    exit 1
  fi

  echo
  echo "Available network interfaces:"
  local i=1
  for iface in "${ifaces[@]}"; do
    echo "  ${i}) ${iface}"
    ((i++))
  done

  while true; do
    read -r -p "${C_QUESTION}[QUESTION]${C_RESET} Select interface number to configure: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#ifaces[@]} )); then
      echo "${ifaces[$((idx-1))]}"
      return
    fi
    echo "Invalid selection."
  done
}

backup_netplan() {
  local backup_dir="/etc/netplan/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a /etc/netplan/*.yaml "$backup_dir/" 2>/dev/null || true
  log "Netplan backup saved to: $backup_dir"
}

configure_static_ip() {
  local iface ipcidr gateway dns_input dns_list existing_gateway existing_dns
  iface="$(choose_interface)"

  echo "Selected interface: $iface"

  while true; do
    read -r -p "${C_QUESTION}[QUESTION]${C_RESET} Enter new static IP in CIDR format (example $(example_text "192.168.1.50/24")): " ipcidr
    if validate_cidr "$ipcidr"; then
      break
    fi
    echo "Invalid CIDR format."
  done

  if ! ip link show "$iface" >/dev/null 2>&1; then
    err "Selected interface '$iface' no longer exists."
    exit 1
  fi

  existing_gateway="$(ip route | awk '/default/ {print $3; exit}')"
  existing_dns="$(resolvectl dns "$iface" 2>/dev/null | awk '{$1=""; print $0}' | xargs || true)"

  gateway="${existing_gateway:-}"
  dns_list="${existing_dns:-1.1.1.1 8.8.8.8}"

  echo "Detected gateway: ${gateway:-<none detected>}"
  if ask_yes_no "Override gateway?" "n"; then
    while true; do
      read -r -p "${C_QUESTION}[QUESTION]${C_RESET} Enter gateway IP (example: $(example_text "192.168.1.1")): " gateway
      if validate_ip "$gateway"; then
        break
      fi
      echo "Invalid IP."
    done
  else
    if [[ -z "$gateway" ]]; then
      while true; do
        read -r -p "${C_QUESTION}[QUESTION]${C_RESET} No gateway detected. Enter gateway IP (example: $(example_text "192.168.1.1")): " gateway
        if validate_ip "$gateway"; then
          break
        fi
        echo "Invalid IP."
      done
    fi
  fi

  echo "Detected DNS servers: ${dns_list}"
  if ask_yes_no "Override DNS servers?" "n"; then
    local all_valid
    while true; do
      read -r -p "${C_QUESTION}[QUESTION]${C_RESET} Enter DNS servers separated by spaces (example: $(example_text "1.1.1.1 8.8.8.8")): " dns_input
      all_valid=1

      if [[ -z "${dns_input// }" ]]; then
        all_valid=0
      else
        for d in $dns_input; do
          if ! validate_ip "$d"; then
            all_valid=0
            break
          fi
        done
      fi

      if [[ "$all_valid" -eq 1 ]]; then
        dns_list="$dns_input"
        break
      fi

      echo "Invalid DNS input. Enter one or more valid IPv4 addresses."
    done
  fi

  local dns_yaml=""
  for d in $dns_list; do
    if validate_ip "$d"; then
      if [[ -n "$dns_yaml" ]]; then
        dns_yaml+=", "
      fi
      dns_yaml+="$d"
    fi
  done

  if [[ -z "$dns_yaml" ]]; then
    warn "No valid DNS servers provided. Falling back to 1.1.1.1, 8.8.8.8"
    dns_yaml="1.1.1.1, 8.8.8.8"
  fi

  backup_netplan

  cat > /etc/netplan/99-custom-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${ipcidr}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses: [${dns_yaml}]
EOF

  log "Validating netplan configuration..."
  if ! netplan generate; then
    err "Netplan validation failed. Backup remains available in /etc/netplan."
    exit 1
  fi

  if ask_yes_no "Apply new network settings now?" "y"; then
    log "Applying netplan..."
    if ! netplan apply; then
      err "Failed to apply netplan configuration."
      exit 1
    fi
    log "Static IP configuration applied."
  else
    warn "Skipped 'netplan apply'. Config saved to /etc/netplan/99-custom-static.yaml"
  fi
}

# ---------- Package install ----------
update_and_upgrade_system() {
  log "Running apt update..."
  apt-get update

  log "Running apt upgrade (this may take a while)..."
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is recommended before heavy use: /var/run/reboot-required exists."
  fi
}

install_base_packages() {
  log "Installing base packages..."
  apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    ca-certificates \
    build-essential \
    software-properties-common \
    realpath
}

install_fish() {
  log "Installing fish..."
  apt-get install -y fish
}

install_nvm_and_node() {
  local target_user="$1"
  log "Installing nvm for user: $target_user"

  if ! run_as_user "$target_user" '
    set -euo pipefail
    export PROFILE="$HOME/.bashrc"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
  '; then
    err "Failed to install nvm for ${target_user}."
    exit 1
  fi

  if ask_yes_no "Install latest Node LTS with nvm?" "y"; then
    log "Installing latest Node LTS via nvm..."
    if ! run_as_user "$target_user" '
      set -euo pipefail
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install --lts
      nvm alias default "lts/*"
      nvm use default
      node -v
      npm -v
    '; then
      err "Failed to install Node LTS via nvm."
      exit 1
    fi
  fi
}

install_oh_my_posh() {
  local target_user="$1"
  log "Installing oh-my-posh for user: $target_user"

  if ! run_as_user "$target_user" '
    set -euo pipefail
    mkdir -p "$HOME/.local/bin"
    curl -s https://ohmyposh.dev/install.sh | bash -s -- -d "$HOME/.local/bin"
  '; then
    err "Failed to install oh-my-posh for ${target_user}."
    exit 1
  fi

  # ensure bash can find it too
  local user_home
  user_home="$(eval echo "~${target_user}")"

  append_if_missing "${user_home}/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'
  chown "${target_user}:${target_user}" "${user_home}/.bashrc"
}

configure_oh_my_posh_atomic_for_fish() {
  local target_user="$1"
  local user_home
  user_home="$(eval echo "~${target_user}")"

  log "Configuring oh-my-posh atomic theme for fish..."

  if ! run_as_user "$target_user" '
    set -euo pipefail
    mkdir -p "$HOME/.config/fish"
    mkdir -p "$HOME/.poshthemes"
    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v oh-my-posh >/dev/null 2>&1; then
      echo "oh-my-posh not found in PATH"
      exit 1
    fi

    # Export built-in atomic theme to a local file
    oh-my-posh config export --config atomic --output "$HOME/.poshthemes/atomic.omp.json"

    CONFIG_LINE='\''oh-my-posh init fish --config "$HOME/.poshthemes/atomic.omp.json" | source'\''
    touch "$HOME/.config/fish/config.fish"

    if ! grep -Fqx "$CONFIG_LINE" "$HOME/.config/fish/config.fish"; then
      printf "\n%s\n" "$CONFIG_LINE" >> "$HOME/.config/fish/config.fish"
    fi
  '; then
    err "Failed to configure oh-my-posh atomic theme for fish."
    exit 1
  fi

  chown -R "${target_user}:${target_user}" "${user_home}/.config" "${user_home}/.poshthemes"
}

offer_set_default_shell_to_fish() {
  local target_user="$1"
  if ask_yes_no "Set fish as default shell for ${target_user}?" "n"; then
    local fish_path
    fish_path="$(command -v fish)"

    if ! grep -Fxq "$fish_path" /etc/shells; then
      echo "$fish_path" >> /etc/shells
    fi

    chsh -s "$fish_path" "$target_user"
    log "Default shell changed to fish for ${target_user}"
  fi
}

# ---------- Main ----------
main() {
  require_root

  local target_user
  target_user="$(get_target_user)"

  log "Target user for per-user installs: ${target_user}"

  update_and_upgrade_system
  install_base_packages
  change_hostname
  configure_static_ip

  local do_nvm=0
  local do_fish=0
  local do_omp=0
  local do_atomic=0

  if ask_yes_no "Install nvm?" "y"; then
    do_nvm=1
  fi

  if ask_yes_no "Install fish shell?" "y"; then
    do_fish=1
  fi

  if ask_yes_no "Install oh-my-posh?" "y"; then
    do_omp=1
  fi

  if [[ "$do_omp" -eq 1 ]]; then
    if ask_yes_no "Configure oh-my-posh atomic theme?" "y"; then
      do_atomic=1
    fi
  fi

  if [[ "$do_fish" -eq 1 ]]; then
    install_fish
    offer_set_default_shell_to_fish "$target_user"
  fi

  if [[ "$do_nvm" -eq 1 ]]; then
    install_nvm_and_node "$target_user"
  fi

  if [[ "$do_omp" -eq 1 ]]; then
    install_oh_my_posh "$target_user"
  fi

  if [[ "$do_atomic" -eq 1 ]]; then
    if [[ "$do_fish" -eq 0 ]]; then
      warn "Atomic theme for fish requested, but fish was not installed. Skipping fish prompt config."
    else
      configure_oh_my_posh_atomic_for_fish "$target_user"
    fi
  fi

  echo
  printf "%b========================================%b\n" "$C_SUCCESS" "$C_RESET"
  printf "%bProvisioning complete.%b\n" "$C_SUCCESS" "$C_RESET"
  echo "Hostname: $(hostnamectl --static status 2>/dev/null || hostname)"
  echo "Target user: ${target_user}"
  printf "%b========================================%b\n" "$C_SUCCESS" "$C_RESET"
  echo
  echo "Recommended next steps:"
  echo "1. Log out and back in if you changed the default shell."
  echo "2. Open a new terminal session."
  echo "3. Verify:"
  echo "   - hostnamectl"
  echo "   - ip addr"
  echo "   - fish --version"
  echo "   - oh-my-posh version"
  echo "   - bash -lc 'source ~/.bashrc && command -v nvm && node -v'"
  echo
}

main "$@"
