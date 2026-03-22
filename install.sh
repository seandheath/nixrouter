#!/usr/bin/env bash
#
# NixOS Router Installation Script
#
# This script automates the installation of the NixOS router configuration.
# It supports three modes:
#   - Fresh install: Boot from ISO, partition disk, install NixOS
#   - Migration: Running on existing NixOS router, backup state, repartition, restore
#   - Upgrade: Running on already-deployed ephemeral router, nixos-rebuild switch
#
# Prerequisites:
#   - For install/migrate: Boot from NixOS installer ISO or existing NixOS
#   - Network connectivity (for downloading packages)
#   - At least two network interfaces
#   - Target disk for installation
#
# Usage:
#   ./install.sh              # Auto-detect mode
#   ./install.sh --migrate    # Force migration mode
#   ./install.sh --upgrade    # Force upgrade mode
#   ./install.sh --check      # Dry-run: show detected mode

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
BACKUP_DIR="/tmp/nixos-migration-backup"
SKIP_SSH_KEYGEN=false
MODE=""
CONFIG_DIR=""

# Print functions
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect which mode we should run in
# Returns: "install", "migrate", or "upgrade"
detect_mode() {
    # Check if already on ephemeral root (upgrade mode)
    # Ephemeral system has tmpfs root and persisted sops key
    if [[ -f "/nix/persist/var/lib/sops-nix/key.txt" ]] && \
       [[ "$(findmnt -no FSTYPE /)" == "tmpfs" ]]; then
        echo "upgrade"
        return
    fi

    # Check if on existing NixOS router (migration mode)
    # Has NixOS marker and hostname is router
    if [[ -f "/etc/NIXOS" ]] && [[ "$(hostname)" == "router" ]]; then
        echo "migrate"
        return
    fi

    # Default: fresh install (probably from ISO)
    echo "install"
}

# Display detected mode and planned actions
show_mode_info() {
    local mode="$1"
    echo ""
    case "$mode" in
        install)
            info "Mode: FRESH INSTALL"
            echo "  - Running from installer ISO or non-NixOS system"
            echo "  - Will partition disk and install NixOS from scratch"
            echo "  - Generates new SSH keys, age key, etc."
            ;;
        migrate)
            info "Mode: MIGRATION"
            echo "  - Running on existing NixOS router"
            echo "  - Will backup state (SSH keys, DHCP leases, etc.)"
            echo "  - Will repartition disk (DESTRUCTIVE)"
            echo "  - Will restore backed-up state"
            echo "  - Will prompt for sops age key"
            ;;
        upgrade)
            info "Mode: UPGRADE"
            echo "  - Running on deployed ephemeral router"
            echo "  - Will update configuration and nixos-rebuild switch"
            echo "  - No repartitioning, preserves /nix/persist"
            ;;
    esac
    echo ""
}

# Confirm migration mode (destructive operation)
confirm_migration() {
    warn "=============================================="
    warn "         MIGRATION MODE DETECTED              "
    warn "=============================================="
    echo ""
    warn "This will REPARTITION your disk and DESTROY all data!"
    echo ""
    info "Critical state will be backed up and restored:"
    echo "  - SSH host keys"
    echo "  - DHCP leases"
    echo "  - ddclient cache"
    echo "  - Machine ID"
    echo ""
    warn "You will need to provide: sops age key (backup or generate new)"
    echo ""
    read -rp "Type 'migrate' to confirm: " confirm
    [[ "$confirm" == "migrate" ]] || { error "Aborted"; exit 1; }
}

# Backup state from existing system before repartitioning
backup_state() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR/ddclient"

    info "Backing up state from existing system..."

    # SSH host keys - critical for preserving host identity
    if cp -a /etc/ssh/ssh_host_* "$BACKUP_DIR/" 2>/dev/null; then
        success "SSH host keys backed up"
    else
        warn "No SSH host keys found"
    fi

    # DHCP leases - nice to have, clients will re-request anyway
    if cp /var/lib/dnsmasq/dnsmasq.leases "$BACKUP_DIR/" 2>/dev/null; then
        success "DHCP leases backed up"
    else
        info "No DHCP leases found (or dnsmasq not configured)"
    fi

    # ddclient cache - preserves dynamic DNS state
    if cp -a /var/lib/ddclient/* "$BACKUP_DIR/ddclient/" 2>/dev/null; then
        success "ddclient state backed up"
    else
        info "No ddclient state found"
    fi

    # Machine ID - preserves system identity
    if cp /etc/machine-id "$BACKUP_DIR/" 2>/dev/null; then
        success "Machine ID backed up"
    else
        warn "No machine-id found"
    fi

    echo ""
    info "Backup location: $BACKUP_DIR"
    ls -la "$BACKUP_DIR"
    echo ""
}

# Restore backed-up state after disko partitioning
restore_state() {
    info "Restoring backed-up state..."

    # SSH host keys
    if [[ -f "$BACKUP_DIR/ssh_host_ed25519_key" ]]; then
        mkdir -p /mnt/nix/persist/etc/ssh
        cp -a "$BACKUP_DIR"/ssh_host_* /mnt/nix/persist/etc/ssh/
        chmod 600 /mnt/nix/persist/etc/ssh/ssh_host_*_key
        chmod 644 /mnt/nix/persist/etc/ssh/ssh_host_*_key.pub
        success "SSH host keys restored"
        SKIP_SSH_KEYGEN=true
    else
        warn "SSH keys not found in backup"
    fi

    # DHCP leases
    if [[ -f "$BACKUP_DIR/dnsmasq.leases" ]]; then
        mkdir -p /mnt/nix/persist/var/lib/dnsmasq
        cp "$BACKUP_DIR/dnsmasq.leases" /mnt/nix/persist/var/lib/dnsmasq/
        success "DHCP leases restored"
    fi

    # ddclient state
    if [[ -d "$BACKUP_DIR/ddclient" ]] && [[ -n "$(ls -A "$BACKUP_DIR/ddclient" 2>/dev/null)" ]]; then
        mkdir -p /mnt/nix/persist/var/lib/ddclient
        cp -a "$BACKUP_DIR/ddclient/"* /mnt/nix/persist/var/lib/ddclient/
        success "ddclient state restored"
    fi

    # Machine ID
    if [[ -f "$BACKUP_DIR/machine-id" ]]; then
        mkdir -p /mnt/nix/persist/etc
        cp "$BACKUP_DIR/machine-id" /mnt/nix/persist/etc/
        success "Machine ID restored"
    fi
}

# Prompt for and restore age key (for sops secrets)
restore_age_key() {
    echo ""
    info "sops age key required for secrets decryption"
    echo ""
    echo "Options:"
    echo "  1) Enter path to backed-up key.txt file"
    echo "  2) Type 'generate' to create a new key (requires re-encrypting secrets)"
    echo ""
    read -rp "Path to key.txt (or 'generate'): " age_key_path

    mkdir -p /mnt/nix/persist/var/lib/sops-nix

    if [[ "$age_key_path" == "generate" ]]; then
        if command -v age-keygen &>/dev/null; then
            age-keygen -o /mnt/nix/persist/var/lib/sops-nix/key.txt
            chmod 600 /mnt/nix/persist/var/lib/sops-nix/key.txt
            echo ""
            warn "New age key generated. You MUST re-encrypt secrets.yaml!"
            info "New public key:"
            age-keygen -y /mnt/nix/persist/var/lib/sops-nix/key.txt
            echo ""
        else
            error "age-keygen not found in PATH"
            exit 1
        fi
    elif [[ -f "$age_key_path" ]]; then
        cp "$age_key_path" /mnt/nix/persist/var/lib/sops-nix/key.txt
        chmod 600 /mnt/nix/persist/var/lib/sops-nix/key.txt
        success "Age key restored from $age_key_path"
    else
        error "File not found: $age_key_path"
        exit 1
    fi
}

# Try to detect interfaces from existing config
detect_interfaces_from_existing() {
    local existing_config="/etc/nixos/interfaces.nix"

    if [[ -f "$existing_config" ]]; then
        local existing_wan existing_lan
        existing_wan=$(grep -oP 'wan\s*=\s*"\K[^"]+' "$existing_config" 2>/dev/null || true)
        existing_lan=$(grep -oP 'lan\s*=\s*"\K[^"]+' "$existing_config" 2>/dev/null || true)

        if [[ -n "$existing_wan" ]] && [[ -n "$existing_lan" ]]; then
            echo ""
            info "Detected existing interface configuration:"
            echo "  WAN: $existing_wan"
            echo "  LAN: $existing_lan"
            read -rp "Use these interfaces? [Y/n] " use_existing
            if [[ ! "$use_existing" =~ ^[Nn]$ ]]; then
                WAN_IF="$existing_wan"
                LAN_IF="$existing_lan"
                return 0
            fi
        fi
    fi
    return 1
}

# Check if running on NixOS installer
check_installer() {
    if ! grep -q "nixos" /etc/os-release 2>/dev/null; then
        warn "This doesn't appear to be a NixOS system"
        read -rp "Continue anyway? [y/N] " response
        [[ "$response" =~ ^[Yy]$ ]] || exit 1
    fi
}

# List network interfaces and let user select
select_interface() {
    local prompt="$1"
    local exclude="$2"
    local interfaces

    # Get list of physical network interfaces (exclude lo, virtual, etc.)
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E '^(lo|veth|br-|docker|virbr)' | grep -v "$exclude" || true)

    if [[ -z "$interfaces" ]]; then
        error "No network interfaces found"
        exit 1
    fi

    echo ""
    info "$prompt"
    echo "Available interfaces:"
    echo ""

    local i=1
    local iface_array=()
    while IFS= read -r iface; do
        # Get MAC address and driver info
        local mac driver state
        mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo "unknown")
        driver=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")

        printf "  %d) %-12s MAC: %-17s Driver: %-12s State: %s\n" "$i" "$iface" "$mac" "$driver" "$state"
        iface_array+=("$iface")
        ((i++))
    done <<< "$interfaces"

    echo ""
    read -rp "Select interface number: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#iface_array[@]})); then
        error "Invalid selection"
        exit 1
    fi

    echo "${iface_array[$((selection-1))]}"
}

# List block devices and let user select
select_disk() {
    echo ""
    info "Select installation disk:"
    echo "Available block devices:"
    echo ""

    lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E "disk|nvme" | head -20

    echo ""
    warn "ALL DATA ON THE SELECTED DISK WILL BE DESTROYED!"
    read -rp "Enter device name (e.g., sda, nvme0n1): " disk

    # Validate disk exists
    if [[ ! -b "/dev/$disk" ]]; then
        error "Device /dev/$disk does not exist"
        exit 1
    fi

    # Confirm destructive operation
    echo ""
    error "You are about to ERASE /dev/$disk"
    read -rp "Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        error "Aborted by user"
        exit 1
    fi

    echo "/dev/$disk"
}

# Validate persist state exists (for upgrade mode)
validate_persist_state() {
    local errors=0

    info "Validating persistent state..."

    if [[ ! -f "/nix/persist/var/lib/sops-nix/key.txt" ]]; then
        error "Missing: /nix/persist/var/lib/sops-nix/key.txt"
        ((errors++))
    fi

    if [[ ! -f "/nix/persist/etc/ssh/ssh_host_ed25519_key" ]]; then
        warn "Missing: SSH host keys (will regenerate on next boot)"
    fi

    if [[ $errors -gt 0 ]]; then
        error "Cannot proceed with upgrade: missing critical state"
        exit 1
    fi

    success "Persistent state validated"
}

# Fresh install flow
do_install() {
    info "Starting fresh installation..."

    # Locate configuration
    locate_config

    # Select interfaces
    WAN_IF=$(select_interface "Select WAN interface (connects to ISP/modem):" "^$")
    success "WAN interface: $WAN_IF"

    LAN_IF=$(select_interface "Select LAN interface (connects to local network):" "$WAN_IF")
    success "LAN interface: $LAN_IF"

    # Select disk
    DISK=$(select_disk)
    success "Installation disk: $DISK"

    # Generate interfaces.nix
    generate_interfaces_config

    # Partition disk
    partition_disk "$DISK"

    # Create directory structure
    create_persist_dirs

    # Copy configuration
    copy_config

    # Generate hardware config
    generate_hardware_config

    # Generate SSH keys
    generate_ssh_keys

    # Generate age key
    generate_age_key

    # Generate machine-id
    generate_machine_id

    # Check for SSH key in admin.nix
    check_admin_ssh_key

    # Run nixos-install
    run_nixos_install

    # Show completion message
    show_completion_message
}

# Migration flow
do_migrate() {
    info "Starting migration..."

    # Confirm destructive operation
    confirm_migration

    # Backup state before repartitioning
    backup_state

    # Locate configuration
    locate_config

    # Try to use existing interfaces, or select new ones
    if ! detect_interfaces_from_existing; then
        WAN_IF=$(select_interface "Select WAN interface (connects to ISP/modem):" "^$")
        success "WAN interface: $WAN_IF"

        LAN_IF=$(select_interface "Select LAN interface (connects to local network):" "$WAN_IF")
        success "LAN interface: $LAN_IF"
    else
        success "WAN interface: $WAN_IF"
        success "LAN interface: $LAN_IF"
    fi

    # Select disk
    DISK=$(select_disk)
    success "Installation disk: $DISK"

    # Generate interfaces.nix
    generate_interfaces_config

    # Partition disk (DESTRUCTIVE)
    partition_disk "$DISK"

    # Create directory structure
    create_persist_dirs

    # Restore backed-up state
    restore_state

    # Restore or generate age key
    restore_age_key

    # Copy configuration
    copy_config

    # Generate hardware config
    generate_hardware_config

    # Generate SSH keys only if not restored
    if [[ "$SKIP_SSH_KEYGEN" != "true" ]]; then
        generate_ssh_keys
    else
        info "Skipping SSH key generation (restored from backup)"
    fi

    # Generate machine-id only if not restored
    if [[ ! -f "/mnt/nix/persist/etc/machine-id" ]]; then
        generate_machine_id
    else
        info "Skipping machine-id generation (restored from backup)"
    fi

    # Check for SSH key in admin.nix
    check_admin_ssh_key

    # Run nixos-install
    run_nixos_install

    # Show completion message
    show_completion_message
}

# Upgrade flow (nixos-rebuild switch)
do_upgrade() {
    info "Starting upgrade..."

    # Validate persistent state
    validate_persist_state

    # Locate configuration
    locate_config

    # Update configuration if needed
    if [[ "$CONFIG_DIR" != "/etc/nixos" ]]; then
        info "Updating configuration from $CONFIG_DIR..."
        # rsync would be better but may not be available
        cp -r "$CONFIG_DIR"/* /etc/nixos/
        success "Configuration updated"
    fi

    # Run nixos-rebuild switch
    info "Running nixos-rebuild switch..."
    nixos-rebuild switch --flake /etc/nixos#router

    echo ""
    success "Upgrade complete!"
    echo ""
}

# Locate configuration directory
locate_config() {
    # Configuration source
    CONFIG_REPO="https://github.com/yourusername/nixrouter.git"  # Update this!

    # Check if we're already in the config directory
    if [[ -f "./flake.nix" ]] && grep -q "nixosConfigurations.router" ./flake.nix 2>/dev/null; then
        info "Using configuration from current directory"
        CONFIG_DIR="$(pwd)"
    elif [[ -d "/tmp/nixrouter" ]]; then
        info "Using existing configuration at /tmp/nixrouter"
        CONFIG_DIR="/tmp/nixrouter"
    else
        info "Cloning configuration repository..."
        nix-shell -p git --run "git clone $CONFIG_REPO /tmp/nixrouter" || {
            error "Failed to clone repository. If running locally, cd to the config directory first."
            exit 1
        }
        CONFIG_DIR="/tmp/nixrouter"
    fi

    cd "$CONFIG_DIR"
}

# Generate interfaces.nix
generate_interfaces_config() {
    info "Generating interface configuration..."
    cat > "$CONFIG_DIR/interfaces.nix" << EOF
# Auto-generated during installation
# WAN: upstream internet connection
# LAN: local network (10.0.0.0/24)
{
  wan = "$WAN_IF";
  lan = "$LAN_IF";
}
EOF
    success "Created interfaces.nix"
}

# Partition disk with disko
partition_disk() {
    local disk="$1"
    info "Partitioning disk with disko..."
    nix run github:nix-community/disko -- \
        --mode disko \
        "$CONFIG_DIR/hosts/router/disko.nix" \
        --arg device "\"$disk\""
    success "Disk partitioned"
}

# Create persistent directory structure
create_persist_dirs() {
    info "Creating directory structure..."
    mkdir -p /mnt/nix/persist/etc/nixos
    mkdir -p /mnt/nix/persist/etc/ssh
    mkdir -p /mnt/nix/persist/var/lib/sops-nix
    mkdir -p /mnt/nix/persist/var/lib/nixos
    mkdir -p /mnt/nix/persist/var/lib/dnsmasq
    mkdir -p /mnt/nix/persist/var/lib/ddclient
    mkdir -p /mnt/nix/persist/var/lib/systemd/timers
    mkdir -p /mnt/nix/persist/var/log
}

# Copy configuration to target
copy_config() {
    info "Copying configuration to /mnt/nix/persist/etc/nixos..."
    cp -r "$CONFIG_DIR"/* /mnt/nix/persist/etc/nixos/
    # Also copy interfaces.nix to where NixOS expects it
    mkdir -p /mnt/etc/nixos
    cp "$CONFIG_DIR/interfaces.nix" /mnt/etc/nixos/interfaces.nix 2>/dev/null || true
    success "Configuration copied"
}

# Generate hardware configuration
generate_hardware_config() {
    info "Generating hardware configuration..."
    nixos-generate-config --root /mnt --show-hardware-config > /mnt/nix/persist/etc/nixos/hosts/router/hardware.nix
    success "Hardware configuration generated"
}

# Generate SSH host keys
generate_ssh_keys() {
    info "Generating SSH host keys..."
    ssh-keygen -t ed25519 -f /mnt/nix/persist/etc/ssh/ssh_host_ed25519_key -N ""
    ssh-keygen -t rsa -b 4096 -f /mnt/nix/persist/etc/ssh/ssh_host_rsa_key -N ""
    success "SSH host keys generated"
}

# Generate sops age key
generate_age_key() {
    info "Generating sops age key..."
    if command -v age-keygen &>/dev/null; then
        age-keygen -o /mnt/nix/persist/var/lib/sops-nix/key.txt
        chmod 600 /mnt/nix/persist/var/lib/sops-nix/key.txt
        AGE_PUBKEY=$(age-keygen -y /mnt/nix/persist/var/lib/sops-nix/key.txt)
        success "Age key generated"
        info "Age public key: $AGE_PUBKEY"
        echo "Add this to your .sops.yaml for encrypting secrets"
    else
        warn "age-keygen not found, skipping age key generation"
        warn "You'll need to create /nix/persist/var/lib/sops-nix/key.txt manually"
    fi
}

# Generate machine-id
generate_machine_id() {
    info "Generating machine-id..."
    systemd-machine-id-setup --root=/mnt
    mkdir -p /mnt/nix/persist/etc
    cp /mnt/etc/machine-id /mnt/nix/persist/etc/machine-id 2>/dev/null || true
    success "Machine ID generated"
}

# Check for SSH key in admin.nix
check_admin_ssh_key() {
    if ! grep -q "ssh-" /mnt/nix/persist/etc/nixos/users/admin.nix 2>/dev/null; then
        echo ""
        warn "WARNING: No SSH public key found in users/admin.nix"
        warn "You won't be able to log in via SSH without adding a key!"
        echo ""
        read -rp "Enter your SSH public key (or press Enter to skip): " ssh_key
        if [[ -n "$ssh_key" ]]; then
            # Add the key to admin.nix
            sed -i "s|openssh.authorizedKeys.keys = \[|openssh.authorizedKeys.keys = [\n      \"$ssh_key\"|" \
                /mnt/nix/persist/etc/nixos/users/admin.nix
            success "SSH key added to admin.nix"
        else
            warn "Skipping SSH key. Remember to add one before rebooting!"
        fi
    fi
}

# Run nixos-install
run_nixos_install() {
    info "Running nixos-install..."
    echo ""
    nixos-install --flake /mnt/nix/persist/etc/nixos#router --no-root-passwd
}

# Show completion message
show_completion_message() {
    echo ""
    echo "=============================================="
    echo "           Installation Complete!             "
    echo "=============================================="
    echo ""
    success "NixOS router has been installed"
    echo ""
    info "Post-installation steps:"
    echo "  1. Verify SSH key is in users/admin.nix"
    echo "  2. Reboot into the new system"
    echo "  3. Connect LAN port to your network"
    echo "  4. Connect WAN port to your ISP/modem"
    echo "  5. SSH to admin@10.0.0.1 from a LAN client"
    echo ""
    info "Network configuration:"
    echo "  WAN: $WAN_IF (DHCP from upstream)"
    echo "  LAN: $LAN_IF (10.0.0.1/24)"
    echo "  DHCP range: 10.0.0.100-254"
    echo ""
    read -rp "Reboot now? [y/N] " reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --migrate)
                MODE="migrate"
                shift
                ;;
            --upgrade)
                MODE="upgrade"
                shift
                ;;
            --check)
                MODE="check"
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --migrate    Force migration mode (backup, repartition, restore)"
                echo "  --upgrade    Force upgrade mode (nixos-rebuild switch)"
                echo "  --check      Dry-run: detect mode and show plan"
                echo "  --help       Show this help message"
                echo ""
                echo "Without options, mode is auto-detected based on system state."
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    echo ""
    echo "=============================================="
    echo "       NixOS Router Installation Script       "
    echo "=============================================="
    echo ""

    parse_args "$@"

    check_root

    # Auto-detect mode if not specified
    if [[ -z "$MODE" ]]; then
        MODE=$(detect_mode)
    fi

    show_mode_info "$MODE"

    # Check mode and run appropriate flow
    case "$MODE" in
        check)
            info "Dry-run complete. No changes made."
            exit 0
            ;;
        install)
            check_installer
            do_install
            ;;
        migrate)
            do_migrate
            ;;
        upgrade)
            do_upgrade
            ;;
        *)
            error "Unknown mode: $MODE"
            exit 1
            ;;
    esac
}

main "$@"
