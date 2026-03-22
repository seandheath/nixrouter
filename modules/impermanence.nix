# Ephemeral root configuration with tmpfs and persistence
#
# The root filesystem is a tmpfs that resets on every boot.
# Stateful data is persisted to /nix/persist via the impermanence module.
#
# This approach provides:
#   - Clean system state on every boot
#   - Explicit declaration of all persistent state
#   - Easy rollback (just reboot)
#   - Reduced attack surface (malware can't persist easily)
#
# Reference: https://github.com/nix-community/impermanence

{ config, lib, pkgs, ... }:

{
  # Mount root as tmpfs
  # 1G is sufficient for a router; adjust if needed
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "defaults"
      "size=1G"
      "mode=755"
    ];
  };

  # Persistence configuration
  # Everything listed here survives reboots
  environment.persistence."/nix/persist" = {
    hideMounts = true;

    directories = [
      # NixOS state (user/group ID mappings, etc.)
      "/var/lib/nixos"

      # System logs (journald)
      "/var/log"

      # Systemd timer state (for scheduled tasks)
      "/var/lib/systemd/timers"

      # Service-specific state
      "/var/lib/dnsmasq"   # DHCP leases
      "/var/lib/ddclient"  # Dynamic DNS cache

      # sops-nix age key location
      "/var/lib/sops-nix"
    ];

    files = [
      # Machine identity
      "/etc/machine-id"

      # SSH host keys (generated at install or first boot)
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };

  # Disable mutable users - all user config must be declarative
  # This prevents passwd/shadow from being modified at runtime
  users.mutableUsers = false;

  # Disable sudo lecture - it would appear on every boot with tmpfs root
  security.sudo.extraConfig = ''
    Defaults lecture = never
  '';

  # Ensure persist directory exists with correct permissions
  systemd.tmpfiles.rules = [
    "d /nix/persist 0755 root root -"
    "d /nix/persist/var/lib/nixos 0755 root root -"
    "d /nix/persist/var/log 0755 root root -"
    "d /nix/persist/var/lib/systemd/timers 0755 root root -"
    "d /nix/persist/var/lib/dnsmasq 0755 dnsmasq dnsmasq -"
    "d /nix/persist/var/lib/ddclient 0700 ddclient ddclient -"
    "d /nix/persist/var/lib/sops-nix 0700 root root -"
    "d /nix/persist/etc/ssh 0755 root root -"
  ];

  # Create required users/groups early for tmpfiles
  users.users.dnsmasq = {
    isSystemUser = true;
    group = "dnsmasq";
  };
  users.groups.dnsmasq = {};

  users.users.ddclient = {
    isSystemUser = true;
    group = "ddclient";
  };
  users.groups.ddclient = {};
}
