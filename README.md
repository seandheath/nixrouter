# NixOS Router

Hardened NixOS router module with ephemeral root, automatic security updates, and declarative firewall.

## Features

- **Ephemeral root**: tmpfs root filesystem resets on every boot
- **Automatic updates**: Daily flake updates + system upgrades with scheduled reboots
- **nftables firewall**: Stateful NAT with logging
- **DHCP/DNS**: dnsmasq serving 10.0.0.0/24 with DNSSEC
- **Hardened kernel**: sysctl hardening, BBR congestion control, module blacklisting
- **Fast reboots**: kexec for ~10 second restarts

## Usage

Add nixrouter as a flake input and import the module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11-small";
    disko.url = "github:nix-community/disko";
    impermanence.url = "github:nix-community/impermanence";
    nixrouter.url = "github:yourusername/nixrouter";
  };

  outputs = { self, nixpkgs, disko, impermanence, nixrouter, ... }: {
    nixosConfigurations.myrouter = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        impermanence.nixosModules.impermanence
        nixrouter.nixosModules.router

        ./hardware-configuration.nix
        ./disko.nix

        {
          # Required options
          router.adminKeys = [
            "ssh-ed25519 AAAAC3... your-key"
          ];
          router.interfaces.wan = "enp1s0";
          router.interfaces.lan = "enp2s0";

          networking.hostName = "myrouter";
        }
      ];
    };
  };
}
```

## Required Options

| Option | Type | Description |
|--------|------|-------------|
| `router.adminKeys` | list of strings | SSH public keys for admin user |
| `router.interfaces.wan` | string | WAN interface name (connects to ISP) |
| `router.interfaces.lan` | string | LAN interface name (connects to local network) |

## Optional: Secrets Management

For secrets (e.g., Dynamic DNS credentials), add sops-nix:

```nix
{
  inputs.sops-nix.url = "github:Mic92/sops-nix";

  outputs = { sops-nix, nixrouter, ... }: {
    nixosConfigurations.myrouter = nixpkgs.lib.nixosSystem {
      modules = [
        sops-nix.nixosModules.sops
        nixrouter.nixosModules.router
        ./modules/sops.nix  # Copy from nixrouter/modules/sops.nix

        {
          sops.defaultSopsFile = ./secrets/secrets.yaml;
        }
      ];
    };
  };
}
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

## Module Structure

```
nixrouter/
├── flake.nix              # Flake with nixosModules export
├── modules/
│   ├── default.nix        # Main module (imports all, defines options)
│   ├── auto-upgrade.nix   # Automatic updates
│   ├── scheduled-reboot.nix
│   ├── impermanence.nix   # Ephemeral root + persistence
│   ├── hardening.nix      # Kernel security
│   ├── firewall.nix       # nftables NAT
│   ├── dnsmasq.nix        # DHCP/DNS server
│   ├── ssh.nix            # SSH hardening
│   ├── sops.nix           # Secrets (optional, not imported by default)
│   └── ddclient.nix       # Dynamic DNS
├── hosts/router/          # Example host config
│   ├── default.nix
│   ├── hardware.nix
│   └── disko.nix
└── users/admin.nix        # Admin user
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
| `/nix/persist/var/lib/sops-nix` | Age key (if using sops) |

## Automatic Updates

Updates run daily at 03:00:

1. `flake-update` service pulls latest flake inputs
2. `nixos-upgrade` builds new configuration
3. System reboots between 03:30-05:00 if needed

Additionally:
- Weekly conditional reboot (Sun 04:00) - only if kernel changed
- Monthly unconditional reboot (1st of month 04:30)

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

# Show module options
make options
```

## Example Personal Repo Structure

```
my-router/
├── flake.nix           # Imports nixrouter, sets options
├── flake.lock
├── hardware-configuration.nix
├── disko.nix           # Disk partitioning for your hardware
├── secrets/
│   └── secrets.yaml    # Encrypted secrets (if using sops)
└── .sops.yaml          # sops configuration
```

## License

MIT
