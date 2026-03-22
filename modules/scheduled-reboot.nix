# Scheduled reboot configuration
#
# Two reboot strategies:
#   1. Weekly conditional reboot (Sunday 04:00) - only if running kernel differs from booted
#   2. Monthly unconditional reboot (1st of month 04:30) - ensures regular restarts
#
# Uses kexec for fast reboots (~10 seconds vs ~60+ for full BIOS POST).
# kexec loads the new kernel directly from the running kernel, skipping firmware.
#
# Reference: https://wiki.archlinux.org/title/Kexec

{ config, lib, pkgs, ... }:

{
  # Enable kexec for fast reboots
  boot.kernelParams = [ "kexec_load_disabled=0" ];

  # Weekly conditional reboot - only if kernel changed
  # Checks if the currently running kernel differs from what would boot next
  systemd.services.conditional-reboot = {
    description = "Reboot if kernel has changed";
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.systemd pkgs.coreutils ];
    script = ''
      # Get currently running kernel version
      RUNNING=$(uname -r)

      # Get the kernel that would boot next (from the default boot entry)
      # The kernel is in /run/booted-system/kernel, but we want the staged one
      STAGED=$(readlink -f /nix/var/nix/profiles/system/kernel | xargs basename)

      echo "Running kernel: $RUNNING"
      echo "Staged kernel: $STAGED"

      # Compare kernel versions
      # Note: This is a simple string comparison; the staged path contains the full derivation
      if [[ "$RUNNING" != *"$STAGED"* ]] && [[ -n "$STAGED" ]]; then
        echo "Kernel changed, initiating kexec reboot..."
        # Use kexec for fast reboot
        systemctl kexec || systemctl reboot
      else
        echo "Kernel unchanged, skipping reboot"
      fi
    '';
  };

  # Timer for weekly conditional reboot (Sunday 04:00)
  systemd.timers.conditional-reboot = {
    description = "Weekly conditional reboot timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";
      Persistent = true;  # Run if missed (e.g., system was off)
      RandomizedDelaySec = "5min";
    };
  };

  # Monthly unconditional reboot service
  systemd.services.monthly-reboot = {
    description = "Monthly unconditional reboot";
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.systemd ];
    script = ''
      echo "Performing scheduled monthly reboot via kexec..."
      # Use kexec for fast reboot, fall back to regular reboot if kexec fails
      systemctl kexec || systemctl reboot
    '';
  };

  # Timer for monthly unconditional reboot (1st of month 04:30)
  systemd.timers.monthly-reboot = {
    description = "Monthly unconditional reboot timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 04:30:00";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };

  # Persist timer state across reboots
  # (Already configured in impermanence.nix via /var/lib/systemd/timers)
}
