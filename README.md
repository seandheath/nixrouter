# NixOS Router

Hardened NixOS router configuration with ephemeral root, automatic security updates, and declarative firewall.

## Features

- **Ephemeral root**: tmpfs root filesystem resets on every boot
- **Automatic updates**: Daily flake updates + system upgrades with scheduled reboots
- **nftables firewall**: Stateful NAT with logging
- **DHCP/DNS**: dnsmasq serving 10.0.0.0/24 with DNSSEC
- **Hardened kernel**: sysctl hardening, BBR congestion control, module blacklisting
- **Fast reboots**: kexec for ~10 second restarts
- **Secrets management**: sops-nix with age encryption

## Requirements

- x86_64 system with UEFI boot
- 2+ network interfaces (WAN + LAN)
- 2GB+ RAM, 8GB+ storage
- NixOS live ISO for installation

## Installation

### 1. Prepare Secrets

Generate an age keypair and encrypt it with a password:

```bash
# Generate keypair
age-keygen

# Save the public key to .sops.yaml (already done, update if regenerating)
# Encrypt the private key with a password
echo 'AGE-SECRET-KEY-...' | age -p -a -o secrets/age-key.enc
```

Add your SSH public key to the secrets file:

```bash
# Decrypt age key temporarily
age -d secrets/age-key.enc > /tmp/age-key.txt

# Edit secrets (opens $EDITOR)
SOPS_AGE_KEY_FILE=/tmp/age-key.txt sops secrets/secrets.yaml

# Add your SSH public key:
# admin-ssh-keys: |
#   ssh-ed25519 AAAAC3... your-key

# Clean up
rm /tmp/age-key.txt
```

### 2. Install from Live ISO

Boot the target machine from a NixOS live ISO, then:

```bash
# Clone the repository
git clone https://github.com/yourusername/nixrouter.git
cd nixrouter

# Run the installer
sudo ./install.sh
```

The installer will:
1. Prompt for WAN and LAN interface selection
2. Write interface configuration to `hosts/router/interfaces.nix`
3. Prompt for disk selection and partition it
4. Decrypt the age key (prompts for password)
5. Install NixOS

### 3. Post-Install

After reboot:
- Connect WAN interface to modem/ISP
- Connect LAN interface to switch/network
- SSH to `admin@10.0.0.1` from the LAN

## Network Configuration

| Interface | Network | Description |
|-----------|---------|-------------|
| WAN | DHCP | Upstream internet connection |
| LAN | 10.0.0.1/24 | Local network gateway |

### DHCP

- Range: 10.0.0.100 - 10.0.0.254
- Lease time: 12 hours
- DNS/Router: 10.0.0.1

### Firewall Rules

- **Input**: SSH/DHCP/DNS from LAN only, all WAN traffic dropped
- **Forward**: LAN->WAN allowed, WAN->LAN only if established
- **NAT**: Masquerade on WAN interface

## Directory Structure

```
nixrouter/
├── flake.nix                 # Flake definition
├── config.nix                # Static configuration values
├── install.sh                # Installation script
├── hosts/router/
│   ├── default.nix           # Host configuration
│   ├── hardware.nix          # Hardware-specific config
│   ├── disko.nix             # Disk partitioning
│   └── interfaces.nix        # Network interfaces (generated)
├── modules/
│   ├── default.nix           # Module imports
│   ├── auto-upgrade.nix      # Automatic updates
│   ├── scheduled-reboot.nix  # Reboot scheduling
│   ├── impermanence.nix      # Ephemeral root + persistence
│   ├── hardening.nix         # Kernel security
│   ├── firewall.nix          # nftables NAT
│   ├── dnsmasq.nix           # DHCP/DNS server
│   ├── ssh.nix               # SSH hardening
│   ├── sops.nix              # Secrets management
│   └── ddclient.nix          # Dynamic DNS (optional)
├── users/
│   └── admin.nix             # Admin user
├── secrets/
│   ├── secrets.yaml          # Encrypted secrets (sops)
│   └── age-key.enc           # Password-encrypted age key
└── .sops.yaml                # Sops configuration
```

## Persistence

With ephemeral root, only explicitly listed paths survive reboots:

| Path | Purpose |
|------|---------|
| `/nix/persist/etc/nixos` | Configuration |
| `/nix/persist/etc/ssh/ssh_host_*` | SSH host keys |
| `/nix/persist/etc/machine-id` | Machine identity |
| `/nix/persist/var/lib/nixos` | NixOS state |
| `/nix/persist/var/log` | Logs |
| `/nix/persist/var/lib/dnsmasq` | DHCP leases |
| `/nix/persist/var/lib/sops-nix` | Age key |

## Automatic Updates

Updates run daily at 03:00:

1. `flake-update` service pulls latest flake inputs
2. `nixos-upgrade` builds new configuration
3. System reboots between 03:30-05:00 if needed

Additionally:
- Weekly conditional reboot (Sun 04:00) - only if kernel changed
- Monthly unconditional reboot (1st of month 04:30)

## Development

```bash
# Build without installing
make build

# Check configuration
make check

# Update flake inputs
make update

# Format Nix files
make fmt
```

## License

MIT
