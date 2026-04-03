# VLAN interface configuration
#
# Creates VLAN interfaces on the LAN trunk port using systemd-networkd.
# VLANs are tagged 802.1Q frames delivered via eth1 (trunk port).
#
# Network topology:
#   eth1 (trunk) -> eth1.10 (Guest), eth1.20 (Kids), eth1.30 (IoT)
#
# The parent interface (eth1) carries untagged traffic for the main LAN
# and tagged traffic for VLANs 10, 20, 30.
#
# Reference: https://wiki.nixos.org/wiki/Systemd-networkd

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;
  vlans = cfg.vlans;
in
{
  # Enable systemd-networkd for VLAN interface management
  systemd.network.enable = true;

  # VLAN netdev definitions
  # These create the virtual VLAN interfaces
  systemd.network.netdevs = {
    # Guest VLAN (10) - isolated internet access
    "10-vlan-guest" = {
      netdevConfig = {
        Name = "${lan}.${toString vlans.guest.id}";
        Kind = "vlan";
      };
      vlanConfig = {
        Id = vlans.guest.id;
      };
    };

    # Kids VLAN (20) - filtered internet access
    "10-vlan-kids" = {
      netdevConfig = {
        Name = "${lan}.${toString vlans.kids.id}";
        Kind = "vlan";
      };
      vlanConfig = {
        Id = vlans.kids.id;
      };
    };

    # IoT VLAN (30) - logged and restricted internet
    "10-vlan-iot" = {
      netdevConfig = {
        Name = "${lan}.${toString vlans.iot.id}";
        Kind = "vlan";
      };
      vlanConfig = {
        Id = vlans.iot.id;
      };
    };
  };

  # Network configuration for parent interface (trunk)
  # Links VLANs to the parent interface
  systemd.network.networks = {
    # Parent interface (eth1) - trunk port carrying tagged VLANs
    # Note: IP configuration for eth1 itself is handled elsewhere (networking.interfaces)
    "20-lan-trunk" = {
      matchConfig = {
        Name = lan;
      };
      # Attach VLANs to this interface
      vlan = [
        "${lan}.${toString vlans.guest.id}"
        "${lan}.${toString vlans.kids.id}"
        "${lan}.${toString vlans.iot.id}"
      ];
      # Don't configure IP here - let NixOS networking.interfaces handle it
      linkConfig = {
        RequiredForOnline = "carrier";
      };
    };

    # Guest VLAN interface configuration
    "30-vlan-guest" = {
      matchConfig = {
        Name = "${lan}.${toString vlans.guest.id}";
      };
      address = [
        "${vlans.guest.address}/${toString vlans.guest.prefixLength}"
      ];
      networkConfig = {
        # Allow interface to come up without carrier (no clients connected)
        ConfigureWithoutCarrier = true;
      };
    };

    # Kids VLAN interface configuration
    "30-vlan-kids" = {
      matchConfig = {
        Name = "${lan}.${toString vlans.kids.id}";
      };
      address = [
        "${vlans.kids.address}/${toString vlans.kids.prefixLength}"
      ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
    };

    # IoT VLAN interface configuration
    "30-vlan-iot" = {
      matchConfig = {
        Name = "${lan}.${toString vlans.iot.id}";
      };
      address = [
        "${vlans.iot.address}/${toString vlans.iot.prefixLength}"
      ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
    };
  };
}
