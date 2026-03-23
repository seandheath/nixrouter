# NixOS Router Specification

## Overview

A hardened NixOS router configuration designed for home/small office use. Provides NAT gateway, DHCP, DNS, and automatic security updates with minimal attack surface.

## Requirements

### Hardware

- x86_64 system with UEFI boot
- Minimum 2 network interfaces (WAN + LAN)
- 2GB+ RAM (1GB for tmpfs root + services)
- 8GB+ storage (for /nix store and persistence)

### Network Topology

```
Internet <---> [ISP Modem] <---> WAN [Router] LAN <---> [Switch] <---> Clients
                                  10.0.0.1
                                     |
                              DHCP: 10.0.0.100-254
```

## Features

### Ephemeral Root (tmpfs)

- Root filesystem is tmpfs, wiped on every boot
- Stateful data persisted to `/nix/persist`
- Benefits:
  - Clean state on every boot
  - Explicit persistence declaration
  - Malware cannot easily persist
  - Fast boot times

### Automatic Updates

- Daily at 03:00: flake update + system upgrade
- Weekly conditional reboot (Sun 04:00) if kernel changed
- Monthly unconditional reboot (1st 04:30)
- kexec for fast reboots (~10s)

### Security Hardening

- Strict reverse path filtering (BCP38)
- ICMP/IPv6 redirect disabled
- Source routing disabled
- Martian logging enabled
- TCP hardening (RFC 1337)
- BBR congestion control
- Kernel pointer/dmesg restrictions
- Unused protocol modules blacklisted
- SSH: key-only, LAN-only, rate-limited

### Firewall (nftables)

- Default deny on input and forward
- LAN services: SSH, DHCP, DNS only
- NAT masquerading on WAN
- Connection tracking with tuned timeouts
- Logging of refused connections

### DHCP/DNS (dnsmasq)

- DHCP range: 10.0.0.100-254
- 12-hour lease time
- DNSSEC validation
- Upstream: Cloudflare + Quad9
- 10,000 entry DNS cache

### Secrets Management (sops-nix)

- Secrets encrypted with age
- Password-protected age key stored in repo
- Decrypted at install time to persistence
- Secrets available at runtime via `/run/secrets`

## Configuration Files

| File | Purpose |
|------|---------|
| `flake.nix` | Flake definition, inputs |
| `config.nix` | Static configuration values |
| `hosts/router/default.nix` | Main host configuration |
| `hosts/router/hardware.nix` | Hardware-specific (generated) |
| `hosts/router/disko.nix` | Disk partitioning |
| `hosts/router/interfaces.nix` | WAN/LAN interface names (generated) |
| `modules/*.nix` | Feature modules |
| `users/admin.nix` | Admin user definition |
| `secrets/secrets.yaml` | Encrypted secrets (sops) |
| `secrets/age-key.enc` | Password-encrypted age key |
| `.sops.yaml` | Sops configuration |

## Persisted Paths

| Path | Content |
|------|---------|
| `/etc/nixos` | Configuration |
| `/etc/ssh/ssh_host_*` | SSH host keys |
| `/etc/machine-id` | Machine identity |
| `/var/lib/nixos` | uid/gid mappings |
| `/var/log` | System logs |
| `/var/lib/dnsmasq` | DHCP leases |
| `/var/lib/ddclient` | DDNS state |
| `/var/lib/sops-nix` | Age key |
| `/var/lib/systemd/timers` | Timer state |

## Interfaces

Generated at install time in `hosts/router/interfaces.nix`:

```nix
{
  wan = "enp1s0";  # Example
  lan = "enp2s0";  # Example
}
```

## Update Schedule

| Event | Schedule | Condition |
|-------|----------|-----------|
| Flake update | Daily 03:00 | Always |
| System upgrade | Daily 03:00 | Always |
| Reboot window | 03:30-05:00 | If upgrade staged |
| Conditional reboot | Sun 04:00 | If kernel changed |
| Unconditional reboot | 1st 04:30 | Always |

## Installation Flow

1. Boot NixOS live ISO
2. Clone repository
3. Run `./install.sh`
   - Select WAN interface
   - Select LAN interface
   - Select target disk
   - Enter age key password
4. Reboot into installed system
5. SSH to admin@10.0.0.1

## Out of Scope

- IPv6 (can be added later)
- VPN server
- WiFi AP (use separate AP hardware)
- Complex QoS
- Multi-WAN failover
