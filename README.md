# NixOS Router

Hardened NixOS router configuration with ephemeral root, automatic security updates, and declarative firewall.

## Features

- **Ephemeral root**: tmpfs root filesystem resets on every boot
- **Automatic updates**: Daily flake updates + system upgrades with scheduled reboots
- **nftables firewall**: Stateful NAT with logging
- **DHCP/DNS**: dnsmasq serving 10.0.0.0/24 with DNSSEC
- **Hardened kernel**: sysctl hardening, BBR congestion control, module blacklisting
- **Secrets management**: sops-nix with age encryption
- **Fast reboots**: kexec for ~10 second restarts

## Quick Start

### Prerequisites

- NixOS minimal installer USB
- Hardware with 2+ network interfaces
- Target disk (all data will be erased)
- Your SSH public key

### Installation

1. Boot the NixOS minimal installer

2. Get the configuration:
   ```bash
   nix-shell -p git
   git clone https://github.com/yourusername/nixrouter.git
   cd nixrouter
   ```

3. **Add your SSH key** to `users/admin.nix`:
   ```nix
   openssh.authorizedKeys.keys = [
     "ssh-ed25519 AAAAC3... your-key-here"
   ];
   ```

4. Run the installer:
   ```bash
   sudo ./install.sh
   ```

5. Follow the prompts to select:
   - WAN interface (connects to ISP/modem)
   - LAN interface (connects to local network)
   - Target disk

6. Reboot and connect cables:
   - WAN → ISP modem/ONT
   - LAN → Switch/local network

7. SSH from a LAN client:
   ```bash
   ssh admin@10.0.0.1
   ```

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
- **Forward**: LAN→WAN allowed, WAN→LAN only if established
- **NAT**: Masquerade on WAN interface

## File Structure

```
nixrouter/
├── flake.nix                 # Flake definition with inputs
├── hosts/router/
│   ├── default.nix           # Main host config
│   ├── hardware.nix          # Hardware-specific (generated)
│   └── disko.nix             # Disk partitioning
├── modules/
│   ├── auto-upgrade.nix      # Automatic updates
│   ├── scheduled-reboot.nix  # Weekly/monthly reboots
│   ├── impermanence.nix      # Ephemeral root + persistence
│   ├── hardening.nix         # Kernel security
│   ├── firewall.nix          # nftables NAT
│   ├── dnsmasq.nix           # DHCP/DNS server
│   ├── ssh.nix               # SSH hardening
│   ├── sops.nix              # Secrets management
│   └── ddclient.nix          # Dynamic DNS (stub)
├── users/admin.nix           # Admin user
├── secrets/secrets.yaml      # Encrypted secrets
├── install.sh                # Interactive installer
└── Makefile                  # Build targets
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

Check timers: `systemctl list-timers`

## Dynamic DNS

To enable ddclient:

1. Edit `modules/ddclient.nix` - uncomment your provider
2. Add credentials to `secrets/secrets.yaml`
3. Encrypt with sops
4. Rebuild

## Secrets Management

Using sops-nix with age encryption:

```bash
# Generate age key (done during install)
age-keygen -o /nix/persist/var/lib/sops-nix/key.txt

# Get public key
age-keygen -y /nix/persist/var/lib/sops-nix/key.txt

# Create .sops.yaml with your public key
# Edit secrets
sops secrets/secrets.yaml
```

## Building & Testing

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

## Post-Install Checklist

- [ ] Verify SSH access from LAN
- [ ] Test DHCP (client gets IP in 10.0.0.100-254 range)
- [ ] Test DNS resolution
- [ ] Test NAT (LAN client can reach internet)
- [ ] Check firewall logs: `journalctl -k | grep nft`
- [ ] Verify auto-upgrade timer: `systemctl status nixos-upgrade.timer`
- [ ] Configure ddclient if using dynamic DNS
- [ ] Set up sops secrets if needed

## Troubleshooting

### Can't SSH after reboot

Ensure your SSH key is in `users/admin.nix` and rebuild.

### DHCP not working

Check dnsmasq status:
```bash
systemctl status dnsmasq
journalctl -u dnsmasq
```

### No internet from LAN

Verify NAT is working:
```bash
nft list ruleset
cat /proc/sys/net/ipv4/ip_forward  # Should be 1
```

### Check firewall logs

```bash
journalctl -k | grep "nft-"
```

## License

MIT
