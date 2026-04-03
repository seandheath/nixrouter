# Automatic system upgrades via flake update + system.autoUpgrade
#
# Strategy:
#   1. flake-update service runs before upgrade to pull latest flake inputs
#   2. system.autoUpgrade builds and stages the new configuration
#   3. System reboots during allowed window to activate changes
#
# The upgrade happens at 03:00 daily with reboots allowed 03:30-05:00.
# This gives time for the build to complete before the reboot window.
#
# Reference: https://nixos.wiki/wiki/Automatic_system_upgrades

{ config, lib, pkgs, ... }:

let
  # Path to the flake configuration (persisted across reboots)
  flakePath = "/nix/persist/etc/nixos";
in
{
  # Service to update flake inputs before system upgrade
  systemd.services.flake-update = {
    description = "Update flake.lock with latest inputs";
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = flakePath;
      # Run as root to write flake.lock
      User = "root";
      # Limit resources during update
      MemoryMax = "512M";
      CPUQuota = "50%";
    };
    path = [ pkgs.nix pkgs.git ];
    script = ''
      # Only update if directory exists and contains a flake
      if [[ -f "${flakePath}/flake.nix" ]]; then
        echo "Updating flake inputs..."
        nix flake update --commit-lock-file 2>&1 || true
      else
        echo "No flake found at ${flakePath}, skipping update"
      fi
    '';
  };

  # Automatic system upgrades
  system.autoUpgrade = {
    enable = true;

    # Build from local flake (updated by flake-update service)
    flake = "${flakePath}#router";

    # Build new configuration but don't switch until reboot
    # This avoids disrupting running services
    operation = "boot";

    # Run upgrade at 03:00 daily
    dates = "03:00";

    # Allow reboot during this window if upgrade requires it
    allowReboot = true;
    rebootWindow = {
      lower = "03:30";
      upper = "05:00";
    };

    # Randomize start time slightly to avoid thundering herd
    # (useful if managing multiple routers)
    randomizedDelaySec = "5min";
  };

  # Ensure flake-update runs before auto-upgrade
  systemd.services.nixos-upgrade = {
    wants = [ "flake-update.service" ];
    after = [ "flake-update.service" ];
  };

  # Garbage collection to prevent disk from filling up
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Limit number of boot configurations to save /boot space
  boot.loader.systemd-boot.configurationLimit = 10;

  # Nix build and store settings
  nix.settings = {
    # Enable flakes (required for flake-based upgrades)
    experimental-features = [ "nix-command" "flakes" ];

    # Use all CPU cores per build derivation
    cores = 0;

    # Build multiple derivations in parallel (auto = number of CPUs)
    max-jobs = "auto";

    # Keep derivations and outputs to avoid re-downloading after GC
    # Trades disk space for faster rebuilds
    keep-derivations = true;
    keep-outputs = true;

    # Deduplicate store paths on write (replaces periodic nix.optimise)
    auto-optimise-store = true;
  };
}
