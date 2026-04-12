#!/bin/bash

################################################################################
# aaPanel (BT Panel) Complete Uninstall Script
# Stops all services and removes all components installed by aaPanel:
#   - aaPanel core (bt service, panel files, cron jobs)
#   - Nginx / Apache / OpenLiteSpeed
#   - MySQL / MariaDB
#   - PHP (all versions: 5.2 – 8.x)
#   - Pure-FTPd
#   - phpMyAdmin
#   - Redis
#   - Memcached
#   - /www directory tree (server, wwwroot, backup, logs)
#
# Usage:
#   sudo ./aapanel_uninstall.sh              # Full interactive uninstall
#   sudo ./aapanel_uninstall.sh --force      # Skip confirmations (dangerous)
#   sudo ./aapanel_uninstall.sh --status     # Show what aaPanel components exist
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
LOG_FILE="/var/log/aapanel_uninstall.log"
BT_DIR="/www"
BT_PANEL_DIR="/www/server/panel"
BT_SERVER_DIR="/www/server"
BT_INIT="/etc/init.d/bt"

# ─── Runtime flags ────────────────────────────────────────────────────────────
MODE="${1:-}"   # --force | --status | (empty = interactive)
FORCE=false
[[ "$MODE" == "--force" ]] && FORCE=true

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
        sudo() { "$@"; }
        export -f sudo
        info "Running as root."
        return
    fi

    if groups 2>/dev/null | grep -qw sudo; then
        echo -e "${YELLOW}[WARN]${NC}  Not running as root, but user '$(whoami)' has sudo access."
        echo ""
        read -rp "$(echo -e "${CYAN}Re-run with sudo for best results? [Y/n]:${NC} ")" yn
        if [[ ! "$yn" =~ ^[Nn]$ ]]; then
            echo ""
            info "Re-launching with sudo..."
            exec sudo bash "$0" "$@"
        fi
        sudo -v || die "sudo authentication failed."
        ( while true; do sudo -v; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; exit' EXIT INT TERM
    else
        echo ""
        error "User '$(whoami)' is not root and has no sudo privileges."
        echo -e "  Run as root:       ${CYAN}sudo su - && ./$(basename "$0")${NC}"
        echo -e "  Or grant sudo:     ${CYAN}usermod -aG sudo $(whoami)${NC}  (run as root, then re-login)"
        echo ""
        die "Insufficient privileges. Exiting."
    fi
}

# ─── Utility functions ────────────────────────────────────────────────────────

# Confirm an action (skipped in --force mode)
confirm() {
    local prompt="$1"
    $FORCE && return 0
    read -rp "$(echo -e "${YELLOW}$prompt [y/N]:${NC} ")" yn
    [[ "$yn" =~ ^[Yy]$ ]]
}

# Stop and disable a systemd service if it exists
stop_service() {
    local svc="$1" label="${2:-$1}"
    if sudo systemctl list-units --full --all 2>/dev/null | grep -q "$svc"; then
        info "Stopping $label..."
        sudo systemctl stop "$svc" 2>/dev/null || true
        sudo systemctl disable "$svc" 2>/dev/null || true
        success "Stopped and disabled $label."
    else
        info "$label service not found — skipping."
    fi
}

# Stop an init.d service if it exists
stop_initd_service() {
    local svc="$1" label="${2:-$1}"
    if [[ -f "/etc/init.d/$svc" ]]; then
        info "Stopping $label (init.d)..."
        sudo /etc/init.d/"$svc" stop 2>/dev/null || true
        success "Stopped $label."
    fi
}

# Remove a directory tree safely
remove_dir() {
    local dir="$1" label="${2:-$1}"
    if [[ -d "$dir" ]]; then
        info "Removing $label: $dir"
        sudo rm -rf "$dir"
        success "Removed $dir"
    else
        info "$label not found at $dir — skipping."
    fi
}

# Remove a file safely
remove_file() {
    local file="$1" label="${2:-$1}"
    if [[ -f "$file" ]]; then
        info "Removing $label: $file"
        sudo rm -f "$file"
        success "Removed $file"
    fi
}

# ─── Status check ─────────────────────────────────────────────────────────────
run_status() {
    echo -e "${BOLD}${BLUE}aaPanel Component Status${NC}\n"

    # Panel
    echo -e "${BOLD}Panel:${NC}"
    if [[ -d "$BT_PANEL_DIR" ]]; then
        echo -e "  ${GREEN}● aaPanel${NC} — installed at $BT_PANEL_DIR"
        if [[ -f "$BT_INIT" ]]; then
            local bt_status
            bt_status=$(sudo $BT_INIT status 2>/dev/null || echo "unknown")
            echo -e "  ${CYAN}  Status: $bt_status${NC}"
        fi
    else
        echo -e "  ${RED}✗ aaPanel${NC} — not installed"
    fi
    echo ""

    # Web servers
    echo -e "${BOLD}Web Servers:${NC}"
    check_bt_component() {
        local name="$1" dir="$2"
        if [[ -d "$dir" ]]; then
            echo -e "  ${GREEN}● $name${NC} — found at $dir"
        else
            echo -e "  ${RED}✗ $name${NC} — not installed"
        fi
    }
    check_bt_component "Nginx"          "$BT_SERVER_DIR/nginx"
    check_bt_component "Apache"         "$BT_SERVER_DIR/apache"
    check_bt_component "OpenLiteSpeed"  "$BT_SERVER_DIR/openlitespeed"
    echo ""

    # Databases
    echo -e "${BOLD}Databases:${NC}"
    check_bt_component "MySQL"    "$BT_SERVER_DIR/mysql"
    check_bt_component "MariaDB"  "$BT_SERVER_DIR/mariadb"
    check_bt_component "MongoDB"  "$BT_SERVER_DIR/mongodb"
    echo ""

    # PHP
    echo -e "${BOLD}PHP Versions:${NC}"
    local php_found=false
    for v in 52 53 54 55 56 70 71 72 73 74 80 81 82 83 84; do
        if [[ -d "$BT_SERVER_DIR/php/$v" ]]; then
            echo -e "  ${GREEN}● PHP ${v:0:1}.${v:1}${NC} — $BT_SERVER_DIR/php/$v"
            php_found=true
        fi
    done
    $php_found || echo -e "  ${RED}✗ No PHP versions found${NC}"
    echo ""

    # Other services
    echo -e "${BOLD}Other Services:${NC}"
    check_bt_component "Pure-FTPd"  "$BT_SERVER_DIR/pure-ftpd"
    check_bt_component "phpMyAdmin" "$BT_SERVER_DIR/phpmyadmin"
    check_bt_component "Redis"      "$BT_SERVER_DIR/redis"
    check_bt_component "Memcached"  "$BT_SERVER_DIR/memcached"
    check_bt_component "Tomcat"     "$BT_SERVER_DIR/tomcat"
    check_bt_component "PM2"        "$BT_SERVER_DIR/nvm"
    echo ""

    # Data directories
    echo -e "${BOLD}Data Directories:${NC}"
    for dir in "$BT_DIR/wwwroot" "$BT_DIR/wwwlogs" "$BT_DIR/backup" "$BT_DIR/Recycle_bin"; do
        if [[ -d "$dir" ]]; then
            local size
            size=$(sudo du -sh "$dir" 2>/dev/null | awk '{print $1}')
            echo -e "  ${GREEN}● $dir${NC} — $size"
        else
            echo -e "  ${RED}✗ $dir${NC} — not found"
        fi
    done
    echo ""

    # Cron jobs
    echo -e "${BOLD}aaPanel Cron Jobs:${NC}"
    if sudo crontab -l 2>/dev/null | grep -qi "bt\|panel\|www/server"; then
        sudo crontab -l 2>/dev/null | grep -i "bt\|panel\|www/server"
    else
        echo "  No aaPanel cron entries found."
    fi
    echo ""
}

# ─── Uninstall steps ─────────────────────────────────────────────────────────

step_stop_all_services() {
    step "1 · Stopping all aaPanel services"

    # Stop bt panel first
    if [[ -f "$BT_INIT" ]]; then
        info "Stopping aaPanel (bt)..."
        sudo $BT_INIT stop 2>/dev/null || true
        success "aaPanel panel stopped."
    fi

    # Web servers
    stop_initd_service nginx   "Nginx"
    stop_initd_service httpd   "Apache"
    stop_service nginx         "Nginx (systemd)"
    stop_service httpd         "Apache (systemd)"
    stop_service apache2       "Apache2 (systemd)"
    stop_service lsws          "OpenLiteSpeed"

    # Databases
    stop_initd_service mysqld  "MySQL"
    stop_service mysqld        "MySQL (systemd)"
    stop_service mysql         "MySQL (systemd alt)"
    stop_service mariadb       "MariaDB"
    stop_service mongod        "MongoDB"

    # PHP-FPM (all versions)
    for v in 52 53 54 55 56 70 71 72 73 74 80 81 82 83 84; do
        stop_initd_service "php-fpm-$v" "PHP-FPM ${v:0:1}.${v:1}"
    done

    # Other services
    stop_initd_service pure-ftpd "Pure-FTPd"
    stop_service pure-ftpd       "Pure-FTPd (systemd)"
    stop_initd_service redis     "Redis"
    stop_service redis           "Redis (systemd)"
    stop_initd_service memcached "Memcached"
    stop_service memcached       "Memcached (systemd)"
    stop_service tomcat          "Tomcat"

    # Kill any remaining bt/panel processes
    info "Killing any remaining aaPanel processes..."
    sudo pkill -f "BT-Panel" 2>/dev/null || true
    sudo pkill -f "BT-Task"  2>/dev/null || true
    sudo pkill -f "/www/server/panel" 2>/dev/null || true

    success "All aaPanel services stopped."
}

step_remove_web_servers() {
    step "2 · Removing web servers"

    remove_dir "$BT_SERVER_DIR/nginx"          "Nginx"
    remove_dir "$BT_SERVER_DIR/apache"         "Apache"
    remove_dir "$BT_SERVER_DIR/openlitespeed"  "OpenLiteSpeed"

    # Remove init.d scripts
    remove_file "/etc/init.d/nginx"   "Nginx init script"
    remove_file "/etc/init.d/httpd"   "Apache init script"

    success "Web servers removed."
}

step_remove_databases() {
    step "3 · Removing databases"

    # Warn about data loss
    if [[ -d "$BT_SERVER_DIR/mysql" ]] || [[ -d "$BT_SERVER_DIR/mariadb" ]]; then
        echo ""
        warn "This will DELETE all MySQL/MariaDB databases permanently!"
        if ! confirm "Are you sure you want to remove all databases?"; then
            warn "Skipping database removal. Databases left intact."
            return
        fi
    fi

    remove_dir "$BT_SERVER_DIR/mysql"    "MySQL"
    remove_dir "$BT_SERVER_DIR/mariadb"  "MariaDB"
    remove_dir "$BT_SERVER_DIR/mongodb"  "MongoDB"
    remove_dir "$BT_SERVER_DIR/data"     "Database data directory"

    # Remove init.d scripts
    remove_file "/etc/init.d/mysqld"  "MySQL init script"

    success "Databases removed."
}

step_remove_php() {
    step "4 · Removing all PHP versions"

    if [[ -d "$BT_SERVER_DIR/php" ]]; then
        local php_versions=()
        for v in "$BT_SERVER_DIR/php"/*/; do
            [[ -d "$v" ]] && php_versions+=("$(basename "$v")")
        done

        if (( ${#php_versions[@]} > 0 )); then
            info "Found PHP versions: ${php_versions[*]}"
            for v in "${php_versions[@]}"; do
                remove_file "/etc/init.d/php-fpm-$v" "PHP-FPM $v init script"
            done
        fi

        remove_dir "$BT_SERVER_DIR/php" "All PHP versions"
    else
        info "No PHP installations found — skipping."
    fi

    success "PHP removed."
}

step_remove_other_services() {
    step "5 · Removing other services"

    remove_dir "$BT_SERVER_DIR/pure-ftpd"   "Pure-FTPd"
    remove_dir "$BT_SERVER_DIR/phpmyadmin"  "phpMyAdmin"
    remove_dir "$BT_SERVER_DIR/redis"       "Redis"
    remove_dir "$BT_SERVER_DIR/memcached"   "Memcached"
    remove_dir "$BT_SERVER_DIR/tomcat"      "Tomcat"
    remove_dir "$BT_SERVER_DIR/nvm"         "Node.js/PM2"
    remove_dir "$BT_SERVER_DIR/java"        "Java"
    remove_dir "$BT_SERVER_DIR/go"          "Go"
    remove_dir "$BT_SERVER_DIR/python"      "Python (bt-managed)"
    remove_dir "$BT_SERVER_DIR/docker"      "Docker (bt-managed)"

    # Remove init.d scripts
    remove_file "/etc/init.d/pure-ftpd"  "Pure-FTPd init script"
    remove_file "/etc/init.d/redis"      "Redis init script"
    remove_file "/etc/init.d/memcached"  "Memcached init script"

    success "Other services removed."
}

step_remove_panel() {
    step "6 · Removing aaPanel core"

    # Remove panel
    remove_dir "$BT_PANEL_DIR" "aaPanel panel"

    # Remove bt init script
    remove_file "$BT_INIT" "bt init script"

    # Remove bt CLI tool
    remove_file "/usr/bin/bt"    "bt command"
    remove_file "/usr/local/bin/bt" "bt command (local)"

    # Remove panel pip packages
    remove_dir "/www/server/panel/pyenv" "Panel Python environment"

    success "aaPanel core removed."
}

step_remove_cron_jobs() {
    step "7 · Removing aaPanel cron jobs"

    if sudo crontab -l 2>/dev/null | grep -qi "bt\|panel\|www/server"; then
        info "Removing aaPanel entries from root crontab..."
        sudo crontab -l 2>/dev/null \
            | grep -vi "bt\|panel\|www/server" \
            | sudo crontab - 2>/dev/null || true
        success "aaPanel cron entries removed."
    else
        info "No aaPanel cron entries found — skipping."
    fi

    # Remove bt cron scripts
    remove_file "/etc/cron.d/bt_crontab" "bt crontab file"

    # Clean cron spool
    if [[ -d "$BT_DIR/cron" ]]; then
        remove_dir "$BT_DIR/cron" "aaPanel cron scripts"
    fi

    success "Cron jobs cleaned."
}

step_remove_data_directories() {
    step "8 · Removing website data, logs, and backups"

    echo ""
    warn "This will permanently delete ALL website files, logs, and backups!"
    echo -e "  ${RED}$BT_DIR/wwwroot${NC}    — all website files"
    echo -e "  ${RED}$BT_DIR/wwwlogs${NC}    — all access/error logs"
    echo -e "  ${RED}$BT_DIR/backup${NC}     — all backups"
    echo -e "  ${RED}$BT_DIR/Recycle_bin${NC} — panel recycle bin"
    echo ""

    if ! confirm "DELETE all website data, logs, and backups?"; then
        warn "Skipping data directory removal. Files left intact at $BT_DIR/"
        return
    fi

    remove_dir "$BT_DIR/wwwroot"     "Website files"
    remove_dir "$BT_DIR/wwwlogs"     "Access/error logs"
    remove_dir "$BT_DIR/backup"      "Backups"
    remove_dir "$BT_DIR/Recycle_bin" "Recycle bin"

    success "Data directories removed."
}

step_remove_remaining_files() {
    step "9 · Cleaning up remaining files"

    # Remove the entire /www directory if it's now empty or only has leftovers
    if [[ -d "$BT_DIR" ]]; then
        echo ""
        warn "The /www directory still exists."
        local remaining
        remaining=$(sudo ls -A "$BT_DIR" 2>/dev/null | head -20)
        if [[ -n "$remaining" ]]; then
            echo -e "${BOLD}Remaining contents:${NC}"
            echo "$remaining" | sed 's/^/  /'
            echo ""
        fi

        if confirm "Remove the entire $BT_DIR directory?"; then
            sudo rm -rf "$BT_DIR"
            success "Removed $BT_DIR completely."
        else
            warn "$BT_DIR left intact."
        fi
    fi

    # Remove aaPanel systemd service files
    local svc_file
    for svc_file in /etc/systemd/system/bt.service \
                    /etc/systemd/system/btpanel.service \
                    /lib/systemd/system/bt.service \
                    /lib/systemd/system/btpanel.service; do
        remove_file "$svc_file" "$(basename "$svc_file")"
    done

    # Remove aaPanel logrotate config
    remove_file "/etc/logrotate.d/bt" "bt logrotate config"

    # Remove panel log
    remove_file "/tmp/panelBoot.pl"   "Panel boot lock"
    remove_file "/tmp/bt_panel.pid"   "Panel PID file"

    # Reload systemd to forget removed units
    sudo systemctl daemon-reload 2>/dev/null || true

    success "Cleanup complete."
}

# ─── Final summary ────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║           aaPanel Uninstall Complete!                ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BOLD}Removed components:${NC}"
    echo "  • aaPanel core (bt service, panel, CLI)"
    echo "  • Web servers (Nginx, Apache, OpenLiteSpeed)"
    echo "  • Databases (MySQL, MariaDB, MongoDB)"
    echo "  • PHP (all versions)"
    echo "  • FTP, Redis, Memcached, phpMyAdmin"
    echo "  • Cron jobs and init scripts"
    echo ""

    if [[ -d "$BT_DIR" ]]; then
        warn "$BT_DIR still exists (some items were kept by your choice)."
        echo ""
    fi

    echo -e "${BOLD}Post-uninstall checklist:${NC}"
    echo "  • Check for leftover firewall rules:  sudo ufw status numbered"
    echo "  • Check for leftover processes:        ps aux | grep -i bt"
    echo "  • Reboot to ensure clean state:        sudo reboot"
    echo ""
    echo -e "Full log: ${CYAN}$LOG_FILE${NC}"
}

# ─── Banner ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${BOLD}${RED}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       aaPanel (BT Panel) Complete Uninstaller        ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    print_banner

    setup_privileges "$@"

    # Init log file
    touch "$LOG_FILE" 2>/dev/null && chmod 644 "$LOG_FILE" \
        || LOG_FILE="/tmp/aapanel_uninstall.log"

    case "$MODE" in
        --status)
            run_status
            exit 0
            ;;
        --force|"")
            # Verify aaPanel is actually installed
            if [[ ! -d "$BT_PANEL_DIR" ]] && [[ ! -f "$BT_INIT" ]] && [[ ! -d "$BT_DIR" ]]; then
                warn "aaPanel does not appear to be installed on this system."
                if ! confirm "Continue anyway?"; then
                    info "Exiting. Nothing was changed."
                    exit 0
                fi
            fi

            # Final warning
            echo -e "${RED}${BOLD}WARNING: This will completely remove aaPanel and ALL its components.${NC}"
            echo -e "${RED}${BOLD}         All websites, databases, and configurations will be DELETED.${NC}"
            echo ""
            if ! confirm "Proceed with full aaPanel uninstall?"; then
                info "Aborted by user. Nothing was changed."
                exit 0
            fi
            echo ""

            step_stop_all_services
            step_remove_web_servers
            step_remove_databases
            step_remove_php
            step_remove_other_services
            step_remove_panel
            step_remove_cron_jobs
            step_remove_data_directories
            step_remove_remaining_files
            print_summary
            ;;
        *)
            die "Unknown argument: $MODE. Use --force or --status."
            ;;
    esac
}

main "$@"
