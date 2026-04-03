# VLAN and bridge interface configuration
#
# Creates a bridge (br-lan) for the main LAN, bridging the trunk port and
# the wired LAN NIC. VLAN sub-interfaces are created on the trunk port
# directly (not on the bridge) so tagged traffic stays isolated.
#
# Network topology:
#   br-lan (10.0.0.1/24)
#     ├── eth1 (trunk) <-> AP
#     │     ├── untagged -> br-lan
#     │     ├── eth1.10 (Guest)
#     │     ├── eth1.20 (Kids)
#     │     └── eth1.30 (IoT)
#     └── eth2 <-> Unmanaged switch
#
# Reference: https://wiki.nixos.org/wiki/Systemd-networkd

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;        # Trunk port (AP)
  wiredLan = interfaces.wiredLan; # Wired LAN (unmanaged switch)
  bridge = cfg.bridgeName;
  vlans = cfg.vlans;
in
{
  # Enable systemd-networkd for bridge and VLAN management
  systemd.network.enable = true;

  systemd.network.netdevs = {
    # Bridge for the main LAN
    "10-br-lan" = {
      netdevConfig = {
        Name = bridge;
        Kind = "bridge";
      };
    };

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

  systemd.network.networks = {
    # Trunk port (AP) - bridge member, carries tagged VLANs
    # Tagged frames go to VLAN sub-interfaces; untagged frames go to br-lan
    "20-lan-trunk" = {
      matchConfig = {
        Name = lan;
      };
      vlan = [
        "${lan}.${toString vlans.guest.id}"
        "${lan}.${toString vlans.kids.id}"
        "${lan}.${toString vlans.iot.id}"
      ];
      networkConfig = {
        Bridge = bridge;
      };
      linkConfig = {
        RequiredForOnline = "carrier";
      };
    };

    # Wired LAN NIC (unmanaged switch) - bridge member
    "20-wired-lan" = {
      matchConfig = {
        Name = wiredLan;
      };
      networkConfig = {
        Bridge = bridge;
      };
      linkConfig = {
        RequiredForOnline = "carrier";
      };
    };

    # Bridge interface - main LAN gateway
    "20-br-lan" = {
      matchConfig = {
        Name = bridge;
      };
      address = [
        "${cfg.lan.address}/${toString cfg.lan.prefixLength}"
      ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
    };

    # Guest VLAN interface
    "30-vlan-guest" = {
      matchConfig = {
        Name = "${lan}.${toString vlans.guest.id}";
      };
      address = [
        "${vlans.guest.address}/${toString vlans.guest.prefixLength}"
      ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
    };

    # Kids VLAN interface
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

    # IoT VLAN interface
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
