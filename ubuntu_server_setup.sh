#!/bin/bash

################################################################################
# Ubuntu Server Setup Script
# Configures Ubuntu as a production-ready server with:
#   - SSH (port 2222 by default, root login enabled)
#   - UFW Firewall (SSH + HTTP + HTTPS always open)
#   - Fail2Ban (brute-force protection)
#   - Admin user creation (webadmin or custom name)
#   - Static local IP via Netplan (auto-detected, confirmation only)
#
# Usage:
#   sudo ./ubuntu_server_setup.sh              # Full interactive setup
#   sudo ./ubuntu_server_setup.sh --repair     # Re-run only failed/broken components
#   sudo ./ubuntu_server_setup.sh --status     # Check status of all components
#
# Run as root or any user with sudo privileges.
################################################################################

set -uo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Configuration ────────────────────────────────────────────────────────────
SSH_PORT=2222
SSH_CONFIG="/etc/ssh/sshd_config"
LOG_FILE="/var/log/ubuntu_server_setup.log"
MAX_RETRIES=3
RETRY_DELAY=5  # seconds between retries

# ─── Runtime flags ────────────────────────────────────────────────────────────
MODE="${1:-}"   # --repair | --status | (empty = full setup)
ADMIN_USERNAME="webadmin"

# ─── Logging & output helpers ─────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE" 2>/dev/null || true
}

info()    { echo -e "${BLUE}[INFO]${NC}  $*";  log INFO    "$*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*";  log OK      "$*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*";  log WARN    "$*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; log ERROR  "$*"; }
step()    { echo -e "\n${BOLD}${CYAN}──── $* ────${NC}"; log STEP "$*"; }
die()     { error "$*"; exit 1; }

# ─── Privilege setup ──────────────────────────────────────────────────────────
setup_privileges() {
    if [[ $EUID -eq 0 ]]; then
        # Already root — make sudo a transparent passthrough
        sudo() { "$@"; }
        export -f sudo
        info "Running as root."
        return
    fi

    # Not root — check if user is in the sudo group
    if groups 2>/dev/null | grep -qw sudo; then
        echo -e "${YELLOW}[WARN]${NC}  Not running as root, but user '$(whoami)' has sudo access."
        echo ""
        read -rp "$(echo -e "${CYAN}Re-run with sudo for best results? [Y/n]:${NC} ")" yn
        if [[ ! "$yn" =~ ^[Nn]$ ]]; then
            echo ""
            info "Re-launching with sudo..."
            exec sudo bash "$0" "$@"
        fi
        # User chose to continue without sudo — keep token alive
        sudo -v || die "sudo authentication failed."
        ( while true; do sudo -v; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; exit' EXIT INT TERM
    else
        # Not root and no sudo access at all
        echo ""
        error "User '$(whoami)' is not root and has no sudo privileges."
        echo -e "  Run as root:       ${CYAN}sudo su - && ./$(basename "$0")${NC}"
        echo -e "  Or grant sudo:     ${CYAN}usermod -aG sudo $(whoami)${NC}  (run as root, then re-login)"
        echo ""
        die "Insufficient privileges. Exiting."
    fi
}

# ─── Utility functions ────────────────────────────────────────────────────────

# Retry a command up to N times
retry_run() {
    local retries="$1"; shift
    local delay="$1";   shift
    local desc="$1";    shift
    local attempt=1
    while (( attempt <= retries )); do
        if "$@"; then return 0; fi
        warn "$desc failed (attempt $attempt/$retries). Retrying in ${delay}s..."
        sleep "$delay"
        (( attempt++ ))
    done
    error "$desc failed after $retries attempts."
    return 1
}

# Check if a .deb package is installed
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Install packages only if not already present
ensure_pkg() {
    local pkg
    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            info "Package '$pkg' already installed — skipping."
        else
            info "Installing '$pkg'..."
            retry_run $MAX_RETRIES $RETRY_DELAY "apt install $pkg" \
                sudo apt-get install -y "$pkg" \
                || die "Could not install '$pkg'. Check network/apt sources."
            success "Installed '$pkg'."
        fi
    done
}

# Write or update a single directive in sshd_config
# Removes any existing (commented or not) line for the key, then appends the new value.
ssh_set_option() {
    local key="$1" value="$2"
    sudo sed -i -E "/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+/d" "$SSH_CONFIG"
    echo "${key} ${value}" | sudo tee -a "$SSH_CONFIG" > /dev/null
}

# Check that a systemd service is active; try to restart if not
ensure_service_active() {
    local svc="$1" label="${2:-$1}"
    if sudo systemctl is-active --quiet "$svc"; then
        success "$label is running."
    else
        warn "$label is not running — attempting restart..."
        retry_run $MAX_RETRIES $RETRY_DELAY "start $label" \
            sudo systemctl restart "$svc" \
            || { error "$label could not be started. Check: journalctl -u $svc"; return 1; }
        success "$label started."
    fi
}

# ─── Interactive option gathering ─────────────────────────────────────────────
gather_options() {
    echo -e "${YELLOW}This script will set up:${NC}"
    echo "  • OpenSSH on port $SSH_PORT (root login enabled)"
    echo "  • UFW firewall (SSH + HTTP + HTTPS)"
    echo "  • Fail2Ban brute-force protection"
    echo "  • Admin user with full sudo access"
    echo ""

    read -rp "$(echo -e "${CYAN}Admin username [webadmin]:${NC} ")" input_user
    [[ -n "$input_user" ]] && ADMIN_USERNAME="$input_user"

    echo ""
}

# ─── Setup steps ──────────────────────────────────────────────────────────────

step_update_system() {
    step "1 · Updating system packages"
    retry_run $MAX_RETRIES $RETRY_DELAY "apt update" \
        sudo apt-get update \
        || die "apt update failed — check network/DNS."
    retry_run $MAX_RETRIES $RETRY_DELAY "apt upgrade" \
        sudo apt-get upgrade -y \
        || warn "apt upgrade had errors (non-fatal — continuing)."
    sudo apt-get autoremove -y > /dev/null 2>&1 || true
    success "System packages up to date."
}

step_install_openssh() {
    step "2 · Installing OpenSSH"
    ensure_pkg openssh-server openssh-client curl wget ufw

    sudo systemctl enable ssh --quiet
    ensure_service_active ssh "OpenSSH"
}

step_configure_ssh() {
    step "3 · Configuring SSH (port $SSH_PORT)"

    # Backup original config (once only)
    if [[ ! -f "${SSH_CONFIG}.bak" ]]; then
        sudo cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
        success "Original config backed up to ${SSH_CONFIG}.bak"
    else
        info "Backup already exists — skipping."
    fi

    ssh_set_option "Port"                   "$SSH_PORT"
    ssh_set_option "PermitRootLogin"        "yes"
    ssh_set_option "PasswordAuthentication" "yes"
    ssh_set_option "PubkeyAuthentication"   "yes"
    ssh_set_option "AuthorizedKeysFile"     ".ssh/authorized_keys"
    ssh_set_option "UsePAM"                 "yes"
    ssh_set_option "X11Forwarding"          "no"
    ssh_set_option "MaxAuthTries"           "4"
    ssh_set_option "LoginGraceTime"         "30"
    ssh_set_option "ClientAliveInterval"    "300"
    ssh_set_option "ClientAliveCountMax"    "2"

    # Validate before restarting — restore backup if broken
    if ! sudo sshd -t; then
        error "sshd_config has syntax errors. Restoring backup..."
        sudo cp "${SSH_CONFIG}.bak" "$SSH_CONFIG"
        die "Original config restored. Fix sshd_config manually."
    fi

    sudo systemctl restart ssh
    ensure_service_active ssh "OpenSSH (port $SSH_PORT)"
    success "SSH configured on port $SSH_PORT."
}

step_setup_ufw() {
    step "4 · Configuring UFW Firewall"
    ensure_pkg ufw

    # Fresh rules only on initial setup, not repair
    if [[ "$MODE" != "--repair" ]]; then
        sudo ufw --force reset > /dev/null
    fi

    sudo ufw default deny incoming  > /dev/null
    sudo ufw default allow outgoing > /dev/null
    sudo ufw allow "$SSH_PORT/tcp" comment "SSH"   > /dev/null
    sudo ufw allow 80/tcp          comment "HTTP"  > /dev/null
    sudo ufw allow 443/tcp         comment "HTTPS" > /dev/null

    sudo ufw --force enable > /dev/null
    success "UFW enabled. Active rules:"
    sudo ufw status numbered
}

step_install_fail2ban() {
    step "5 · Installing Fail2Ban"
    ensure_pkg fail2ban

    local jail_local="/etc/fail2ban/jail.local"
    if [[ ! -f "$jail_local" ]]; then
        sudo tee "$jail_local" > /dev/null <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
filter   = sshd
logpath  = %(sshd_log)s
maxretry = 4
EOF
        success "Fail2Ban jail.local created."
    else
        info "jail.local already exists — updating SSH port only."
        sudo sed -i "s/^port\s*=.*/port     = $SSH_PORT/" "$jail_local"
    fi

    sudo systemctl enable fail2ban --quiet
    retry_run $MAX_RETRIES $RETRY_DELAY "start fail2ban" \
        sudo systemctl restart fail2ban \
        || warn "Fail2Ban failed to start — check: journalctl -u fail2ban"
    ensure_service_active fail2ban "Fail2Ban"
}

step_create_admin_user() {
    step "6 · Creating admin user: $ADMIN_USERNAME"

    if id "$ADMIN_USERNAME" &>/dev/null; then
        info "User '$ADMIN_USERNAME' already exists — skipping creation."
    else
        sudo useradd -m -s /bin/bash "$ADMIN_USERNAME"
        success "User '$ADMIN_USERNAME' created."
    fi

    # Add to sudo group (full sudo access)
    sudo usermod -aG sudo "$ADMIN_USERNAME"
    success "Added '$ADMIN_USERNAME' to sudo group."

    # Grant passwordless sudo for convenience on a personal server
    local sudoers_file="/etc/sudoers.d/$ADMIN_USERNAME"
    if [[ ! -f "$sudoers_file" ]]; then
        echo "$ADMIN_USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" > /dev/null
        sudo chmod 440 "$sudoers_file"
        success "Passwordless sudo granted to '$ADMIN_USERNAME'."
    fi

    # Set password interactively (max 3 attempts)
    echo ""
    warn "Set a password for '$ADMIN_USERNAME' (you will be prompted twice):"
    local passwd_attempts=0
    until sudo passwd "$ADMIN_USERNAME"; do
        (( passwd_attempts++ ))
        if (( passwd_attempts >= 3 )); then
            warn "Password setup failed after 3 attempts — skipping. Set it manually: passwd $ADMIN_USERNAME"
            break
        fi
        warn "Try again ($passwd_attempts/3)..."
    done
    (( passwd_attempts < 3 )) && success "Password set for '$ADMIN_USERNAME'."

    # Ensure .ssh dir exists for key-based login later
    local ssh_dir="/home/$ADMIN_USERNAME/.ssh"
    if [[ ! -d "$ssh_dir" ]]; then
        sudo mkdir -p "$ssh_dir"
        sudo chmod 700 "$ssh_dir"
        sudo touch "$ssh_dir/authorized_keys"
        sudo chmod 600 "$ssh_dir/authorized_keys"
        sudo chown -R "$ADMIN_USERNAME:$ADMIN_USERNAME" "$ssh_dir"
        info "~/.ssh directory prepared for '$ADMIN_USERNAME'."
    fi

    echo ""
    echo -e "${BOLD}Admin user summary:${NC}"
    echo "  Username : $ADMIN_USERNAME"
    echo "  Groups   : $(id "$ADMIN_USERNAME")"
    echo "  SSH dir  : $ssh_dir"
    echo ""
    echo -e "${YELLOW}Root login is also enabled. You can SSH as root OR as $ADMIN_USERNAME.${NC}"
}


step_setup_static_local_ip() {
    step "7 · Configuring static local IP via Netplan"

    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
    [[ -z "$iface" ]] && { warn "Could not detect network interface — skipping."; return; }

    local current_ip gateway
    current_ip=$(ip -4 addr show "$iface" | grep -oP '(?<=inet )\S+')
    gateway=$(ip route | grep default | awk '{print $3}' | head -1)

    if [[ -z "$current_ip" || -z "$gateway" ]]; then
        warn "Could not detect current IP or gateway — skipping."
        return
    fi

    echo ""
    echo -e "${BOLD}Detected network settings:${NC}"
    echo "  Interface : $iface"
    echo "  IP        : $current_ip"
    echo "  Gateway   : $gateway"
    echo "  DNS       : 8.8.8.8, 8.8.4.4, 1.1.1.1"
    echo ""
    read -rp "$(echo -e "${CYAN}Lock these as a static IP via Netplan? [y/N]:${NC} ")" yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { info "Skipping static IP."; return; }

    local netplan_file="/etc/netplan/99-static-server.yaml"
    sudo tee "$netplan_file" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: no
      addresses:
        - ${current_ip}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4, 1.1.1.1]
EOF
    sudo chmod 600 "$netplan_file"

    local netplan_err
    if netplan_err=$(sudo netplan generate 2>&1); then
        sudo netplan apply
        success "Static IP locked: $current_ip on $iface"
    else
        warn "Netplan config error — removing to avoid breaking network."
        warn "Error: $netplan_err"
        sudo rm -f "$netplan_file"
    fi
}

# ─── Status check ─────────────────────────────────────────────────────────────
run_status() {
    echo -e "${BOLD}${BLUE}Server Component Status${NC}\n"

    check_svc() {
        if sudo systemctl is-active --quiet "$1" 2>/dev/null; then
            echo -e "  ${GREEN}● $2${NC} — active"
        else
            echo -e "  ${RED}✗ $2${NC} — inactive / not installed"
        fi
    }

    check_svc ssh       "OpenSSH"
    check_svc ufw       "UFW Firewall"
    check_svc fail2ban  "Fail2Ban"
    echo ""

    echo -e "${BOLD}Network:${NC}"
    local local_ip public_ip
    local_ip=$(hostname -I | awk '{print $1}')
    public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unavailable")
    echo "  Local IP  : $local_ip"
    echo "  Public IP : $public_ip"
    echo ""

    echo -e "${BOLD}UFW Rules:${NC}"
    sudo ufw status 2>/dev/null || echo "  UFW not active"
    echo ""

    echo -e "${BOLD}SSH Effective Settings:${NC}"
    sudo sshd -T 2>/dev/null \
        | grep -E "^(port|passwordauthentication|permitrootlogin|pubkeyauthentication|maxauthtries)" \
        || true
}

# ─── Repair mode ──────────────────────────────────────────────────────────────
run_repair() {
    step "Repair mode — re-checking all components"

    step_install_openssh
    step_configure_ssh
    step_setup_ufw
    step_install_fail2ban

    run_status
    success "Repair complete."
}

# ─── Final summary ────────────────────────────────────────────────────────────
print_summary() {
    local local_ip public_ip
    local_ip=$(hostname -I | awk '{print $1}')
    public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unavailable")

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║              Setup Complete!                         ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}SSH — local network:${NC}"
    echo -e "  ${CYAN}ssh -p $SSH_PORT \$USER@$local_ip${NC}"
    echo ""
    echo -e "${BOLD}SSH — from internet (after port forwarding):${NC}"
    echo -e "  ${CYAN}ssh -p $SSH_PORT \$USER@$public_ip${NC}"
    echo ""
    echo -e "${BOLD}Your static public IP (BSNL):${NC} ${YELLOW}$public_ip${NC}"
    echo -e "${BOLD}Local IP:${NC}                      ${YELLOW}$local_ip${NC}"
    echo ""
    echo -e "${BOLD}${YELLOW}Router Port Forwarding — configure once on your BSNL router:${NC}"
    echo "  Port $SSH_PORT (TCP)  →  $local_ip:$SSH_PORT   [SSH]"
    echo "  Port 80   (TCP)  →  $local_ip:80     [HTTP]"
    echo "  Port 443  (TCP)  →  $local_ip:443    [HTTPS]"
    echo ""
    echo -e "${BOLD}Admin user:${NC} ${YELLOW}$ADMIN_USERNAME${NC} (sudo, passwordless, SSH-ready)"
    echo -e "  ${CYAN}ssh -p $SSH_PORT $ADMIN_USERNAME@$public_ip${NC}"
    echo ""
    echo -e "${BOLD}Security:${NC}"
    echo "  • Root login: enabled (personal server)"
    echo "  • Max auth tries: 4"
    echo "  • Fail2Ban: bans after 4 failed SSH attempts for 1h"
    echo "  • UFW firewall: active (all ports closed except listed above)"
    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  ./ubuntu_server_setup.sh --status    # check everything"
    echo "  ./ubuntu_server_setup.sh --repair    # fix broken components"
    echo "  sudo fail2ban-client status sshd     # see banned IPs"
    echo "  sudo ufw status numbered             # firewall rules"
    echo ""
    echo -e "Full log: ${CYAN}$LOG_FILE${NC}"
}

# ─── Banner ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         Ubuntu Server Setup (BSNL Static IP)        ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    print_banner

    setup_privileges "$@"

    # Init log file (works for both root and sudo user after privilege setup)
    touch "$LOG_FILE" 2>/dev/null && chmod 644 "$LOG_FILE" \
        || LOG_FILE="/tmp/ubuntu_server_setup.log"

    case "$MODE" in
        --status)
            run_status
            exit 0
            ;;
        --repair)
            run_repair
            exit 0
            ;;
        "")
            gather_options
            step_update_system
            step_install_openssh
            step_configure_ssh
            step_setup_ufw
            step_install_fail2ban
            step_create_admin_user
            step_setup_static_local_ip
            print_summary
            ;;
        *)
            die "Unknown argument: $MODE. Use --repair or --status."
            ;;
    esac
}

main "$@"
