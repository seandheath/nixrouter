# Disko partitioning configuration for NixOS router
#
# Partition scheme (GPT):
#   - boot: 512MB FAT32 (ESP) mounted at /boot
#   - nix: remainder ext4 mounted at /nix
#
# Root (/) is tmpfs, defined in impermanence module.
# Persistence lives under /nix/persist.
#
# Usage during install:
#   disko --mode disko /path/to/disko.nix --arg device '"/dev/sdX"'

{ device ? "/dev/sda", ... }:

{
  disko.devices = {
    disk.main = {
      type = "disk";
      inherit device;
      content = {
        type = "gpt";
        partitions = {
          # EFI System Partition for systemd-boot
          boot = {
            size = "512M";
            type = "EF00";  # EFI System
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };

          # Main partition for /nix (including /nix/persist)
          nix = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/nix";
              # Optimize for SSD if present; harmless on HDD
              mountOptions = [ "noatime" "discard" ];
            };
          };
        };
      };
    };
  };
}
