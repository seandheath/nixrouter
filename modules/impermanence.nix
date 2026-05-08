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
      "/var/lib/dnsmasq"              # DHCP leases (main LAN dnsmasq)
      "/var/lib/kids-mode"            # kids-mode toggle: mode + whitelist
      # ddclient state intentionally NOT persisted: nixpkgs flipped the
      # service to DynamicUser=true, which collides with a bind-mounted
      # /var/lib/ddclient (EBUSY on systemd's private-state symlink). The
      # only state is an IP cache; losing it costs one extra API call
      # after each reboot.
      # AGH runs under DynamicUser, so systemd places its state under
      # /var/lib/private/AdGuardHome and symlinks /var/lib/AdGuardHome
      # to it. Persist the real path; do NOT bind-mount the symlink
      # location or systemd fails with EBUSY at startup.
      "/var/lib/private/AdGuardHome"

      # sops-nix age key location
      "/var/lib/sops-nix"

      # Nix evaluation/download cache for root user
      "/root/.cache/nix"
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
    "d /nix/persist/var/lib/kids-mode 0750 kids-mode kids-mode -"
    # AGH runs under DynamicUser; systemd places state at
    # /var/lib/private/AdGuardHome (with a symlink at /var/lib/AdGuardHome).
    # We persist the real /private path. Don't pin a static owner -
    # systemd's StateDirectory will chown to the dynamic UID at start.
    # UID is stable across reboots because /var/lib/nixos is persisted.
    "d /nix/persist/var/lib/private 0755 root root -"
    "d /nix/persist/var/lib/private/AdGuardHome 0700 root root -"
    "d /nix/persist/var/lib/sops-nix 0700 root root -"
    "d /nix/persist/root/.cache/nix 0700 root root -"
    "d /nix/persist/etc/ssh 0755 root root -"
  ];

  # Create required users/groups early for tmpfiles
  users.users.dnsmasq = {
    isSystemUser = true;
    group = "dnsmasq";
  };
  users.groups.dnsmasq = {};

  # ddclient runs as a DynamicUser (provided by nixpkgs), so no static
  # user/group declaration is needed.
}
