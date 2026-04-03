# NixOS Router

Hardened NixOS router configuration with VLAN segmentation, ephemeral root, automatic security updates, and declarative firewall.

## Features

- **VLAN segmentation**: Guest, Kids, and IoT networks with per-VLAN isolation
- **DNS-based content filtering**: Tiered blocklists with automatic daily updates
- **Ephemeral root**: tmpfs root filesystem resets on every boot
- **Automatic updates**: Daily flake updates + system upgrades with scheduled reboots
- **iptables firewall**: Stateful NAT with inter-VLAN isolation and connection logging
- **DHCP/DNS**: dnsmasq with per-network DHCP ranges and DNSSEC validation
- **Hardened kernel**: 40+ sysctl settings, BBR congestion control, module blacklisting
- **Fast reboots**: kexec for ~10 second restarts
- **Secrets management**: sops-nix with age encryption

## Requirements

- x86_64 system with UEFI boot
- 2+ network interfaces (WAN + LAN)
- 2GB+ RAM, 8GB+ storage
- NixOS live ISO for installation
- Wireless AP with 802.1Q VLAN tagging (for VLAN features)
- 3+ NICs (WAN + trunk to AP + wired LAN)

## Network Topology

```
Internet <---> [ISP Modem] <---> WAN [Router] br-lan (10.0.0.1/24)
                                 eth0           ├── eth1 (trunk) <---> [AP]
                              (DHCP)            │     ├── untagged -> br-lan
                                                │     ├── eth1.10 (Guest)
                                                │     ├── eth1.20 (Kids)
                                                │     └── eth1.30 (IoT)
                                                └── eth2 <---> [Unmanaged Switch]
```

### Networks

| Network | VLAN ID | Subnet | DHCP Range | Description |
|---------|---------|--------|------------|-------------|
| Main LAN | — | 10.0.0.0/24 | .100–.254 | Trusted devices, SSH to router |
| Guest | 10 | 10.10.0.0/24 | .100–.254 | Internet only, fully isolated |
| Kids | 20 | 10.20.0.0/24 | .100–.254 | Filtered internet, DNS bypass blocked |
| IoT | 30 | 10.30.0.0/24 | .100–.254 | Internet with connection logging |

All DHCP leases are 12 hours. DNS/gateway per-network points to the router's VLAN interface address.

### Firewall Policy

| Source | Destination | Policy |
|--------|-------------|--------|
| LAN | WAN | Allow |
| LAN | Router | SSH, DNS, DHCP |
| VLANs | WAN | Allow |
| VLANs | Router | DNS, DHCP only |
| VLANs | LAN / other VLANs | **Blocked** |
| Kids | External DNS (53, 853) | **Blocked** (bypass prevention) |
| IoT | WAN | Allow + log all new connections |
| WAN | Any | Drop (established/related only) |

### DNS Filtering

Two tiers of DNS blocklists from [StevenBlack/hosts](https://github.com/StevenBlack/hosts):

- **Base** (Main LAN): ads, trackers, malware
- **Extended** (Kids VLAN): base + adult content, gambling, social media, fake news

Blocklists update daily at 04:00 with automatic reload. The Kids network runs a dedicated dnsmasq instance with the extended blocklist.

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
git clone https://github.com/seandheath/nixrouter.git
cd nixrouter

# Run the installer
sudo ./install.sh
```

The installer will:
1. Prompt for WAN, trunk (AP), and wired LAN interface selection
2. Write interface configuration to `hosts/router/interfaces.nix`
3. Prompt for disk selection and partition it
4. Decrypt the age key (prompts for password)
5. Install NixOS

### 3. Post-Install

After reboot:
- Connect WAN interface to modem/ISP
- Connect trunk interface to wireless AP (carries VLANs 10, 20, 30 + untagged)
- Connect wired LAN interface to unmanaged switch
- SSH to `admin@10.0.0.1` from the LAN

## Directory Structure

```
nixrouter/
├── flake.nix                 # Flake definition
├── config.nix                # Static configuration (networks, VLANs, DNS)
├── install.sh                # Installation script
├── Makefile                  # Build/deploy targets
├── hosts/router/
│   ├── default.nix           # Host configuration
│   ├── hardware.nix          # Hardware-specific config
│   ├── disko.nix             # Disk partitioning
│   └── interfaces.nix        # Network interfaces (generated at install)
├── modules/
│   ├── default.nix           # Module imports
│   ├── vlans.nix             # 802.1Q VLAN interfaces
│   ├── firewall.nix          # NAT + inter-VLAN isolation
│   ├── dnsmasq.nix           # DHCP/DNS server
│   ├── dns-blocklist.nix     # Tiered DNS content filtering
│   ├── auto-upgrade.nix      # Automatic updates
│   ├── scheduled-reboot.nix  # Reboot scheduling (kexec)
│   ├── impermanence.nix      # Ephemeral root + persistence
│   ├── hardening.nix         # Kernel security
│   ├── ssh.nix               # SSH hardening
│   ├── sops.nix              # Secrets management
│   └── ddclient.nix          # Dynamic DNS (optional)
├── users/
│   └── admin.nix             # Admin user
├── secrets/
│   ├── secrets.yaml          # Encrypted secrets (sops)
│   └── age-key.enc           # Password-encrypted age key
├── docs/
│   ├── specification.md      # Project specification
│   └── log.md                # Decision log
└── .sops.yaml                # Sops configuration
```

## Persistence

With ephemeral root, only explicitly listed paths survive reboots:

| Path | Purpose |
|------|---------|
| `/nix/persist/etc/ssh/ssh_host_*` | SSH host keys |
| `/nix/persist/etc/machine-id` | Machine identity |
| `/nix/persist/var/lib/nixos` | NixOS state |
| `/nix/persist/var/log` | System logs |
| `/nix/persist/var/lib/dnsmasq` | DHCP leases + blocklists |
| `/nix/persist/var/lib/ddclient` | DDNS state |
| `/nix/persist/var/lib/sops-nix` | Age decryption key |
| `/nix/persist/var/lib/systemd/timers` | Timer state |

## Automatic Updates

Updates run daily at 03:00:

1. `flake-update` service pulls latest flake inputs
2. `nixos-upgrade` builds new configuration
3. System reboots between 03:30–05:00 if needed

Additionally:
- Weekly conditional reboot (Sun 04:00) — only if kernel changed
- Monthly unconditional reboot (1st of month 04:30)
- DNS blocklist update daily at 04:00

Garbage collection runs weekly, retaining 30 days. Boot limited to 10 generations.

## Development

```bash
make build    # Build configuration
make check    # Run nix flake check
make update   # Update flake inputs
make fmt      # Format Nix files
make lint     # Syntax check
make deploy HOST=router  # Remote deploy via SSH
```

## License

[AGPL-3.0](LICENSE)
