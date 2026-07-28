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
  # Service to pull config changes and update flake inputs before the upgrade
  #
  # system.autoUpgrade builds from the LOCAL clone at ${flakePath}, so without
  # an explicit `git pull` here nothing pushed to the git remote ever reaches
  # this machine -- only flake input bumps would land. That failure is silent:
  # nixos-upgrade.service still reports success every night while rebuilding
  # the identical store path. (Observed 2026-07-28: no new generation since
  # Jul 4 despite nightly "successful" runs.)
  systemd.services.flake-update = {
    description = "Pull config from origin and update flake.lock";
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
      # Fail loudly. The previous version ended every command with `|| true`,
      # which turned a broken update pipeline into a green systemd unit.
      set -euo pipefail

      if [[ ! -f "${flakePath}/flake.nix" ]]; then
        echo "No flake found at ${flakePath}, skipping update"
        exit 0
      fi

      echo "Fetching config from origin..."
      git fetch --quiet origin

      # flake.lock is a build artifact on this box: `nix flake update` rewrites
      # it nightly and it is regenerated below regardless, so it is never
      # committed here. Committing would create a local branch divergence that
      # breaks every subsequent --ff-only pull. Stash it across the merge so a
      # dirty lock cannot abort the fast-forward, then restore it -- restoring
      # the NEWER lock rather than rolling nixpkgs back to origin's committed
      # one, which may be months behind what this machine actually runs.
      stashed=""
      if ! git diff --quiet -- flake.lock; then
        git stash push --quiet -- flake.lock
        stashed=1
      fi

      git merge --ff-only origin/main

      if [[ -n "$stashed" ]]; then
        git stash pop --quiet
      fi

      echo "Updating flake inputs..."
      nix flake update
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

  # The auto-upgrade services (flake-update, nixos-upgrade) run as root, but
  # the flake repo at ${flakePath} is owned by the admin user. Modern
  # git/libgit2 refuses to open a repo it doesn't own ("detected dubious
  # ownership"), which makes the git+file:// flake fetch fail with exit 1 -
  # silently stalling all upgrades. Mark the path safe so root can read it.
  #
  # This MUST be declarative: /root is tmpfs under impermanence
  # (modules/impermanence.nix), so a per-user `git config --global` in
  # /root/.gitconfig would not survive a reboot - and a successful upgrade
  # reboots the box. programs.git writes system-wide /etc/gitconfig, which is
  # in the Nix store and read by every user including root.
  programs.git = {
    enable = true;
    config.safe.directory = [ flakePath ];
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
