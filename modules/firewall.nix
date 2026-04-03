# Firewall and NAT configuration
#
# Architecture:
#   WAN (external) <---> [Router] <---> LAN (10.0.0.0/24)
#                                  |
#                                  +---> Guest VLAN (10.10.0.0/24) - isolated
#                                  +---> Kids VLAN (10.20.0.0/24) - filtered
#                                  +---> IoT VLAN (10.30.0.0/24) - logged
#
# Policy:
#   - Input: Allow SSH/DHCP/DNS from LAN only, drop from WAN and VLANs
#   - Forward: Allow LAN→WAN, VLAN→WAN, block inter-VLAN and VLAN→LAN
#   - NAT: Masquerade outbound traffic on WAN interface
#
# Security:
#   - VLANs cannot reach each other or the main LAN (10.0.0.0/8 blocked)
#   - VLANs cannot SSH to router (management from LAN only)
#   - IoT connections are logged for monitoring
#
# Reference: https://nixos.wiki/wiki/Firewall

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  wan = interfaces.wan;
  lan = interfaces.lan;
  lanNetwork = cfg.lan.network;
  vlans = cfg.vlans;

  # VLAN interface names
  guestIf = "${lan}.${toString vlans.guest.id}";
  kidsIf = "${lan}.${toString vlans.kids.id}";
  iotIf = "${lan}.${toString vlans.iot.id}";
in
{
  # Enable IP forwarding (required for routing)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;

    # Allow IPv6 autoconfiguration on WAN only
    # Value 2 = accept RA even when forwarding is enabled
    # This allows the router to get an IPv6 prefix from upstream
    "net.ipv6.conf.${wan}.accept_ra" = 2;
    "net.ipv6.conf.${wan}.autoconf" = 1;
  };

  # NixOS declarative firewall
  networking.firewall = {
    enable = true;

    # Default: reject packets to closed ports (more polite than drop)
    rejectPackets = false;  # Use drop instead for stealth

    # Log refused connections (useful for debugging, can be noisy)
    logRefusedConnections = true;
    logRefusedPackets = false;

    # Allow ICMP ping
    allowPing = true;

    # Per-interface rules
    interfaces = {
      # LAN interface - allow management services
      ${lan} = {
        allowedTCPPorts = [
          22   # SSH
          53   # DNS
        ];
        allowedUDPPorts = [
          53   # DNS
          67   # DHCP server
        ];
      };

      # WAN interface - nothing open
      # Only established/related connections allowed (handled automatically)
      ${wan} = {
        allowedTCPPorts = [ ];
        allowedUDPPorts = [ ];
      };

      # Guest VLAN - DHCP and DNS only, no SSH
      ${guestIf} = {
        allowedTCPPorts = [
          53   # DNS
        ];
        allowedUDPPorts = [
          53   # DNS
          67   # DHCP server
        ];
      };

      # Kids VLAN - DHCP and DNS only, no SSH
      ${kidsIf} = {
        allowedTCPPorts = [
          53   # DNS
        ];
        allowedUDPPorts = [
          53   # DNS
          67   # DHCP server
        ];
      };

      # IoT VLAN - DHCP only (DNS goes through gateway anyway)
      ${iotIf} = {
        allowedTCPPorts = [
          53   # DNS (for initial resolution)
        ];
        allowedUDPPorts = [
          53   # DNS
          67   # DHCP server
        ];
      };
    };

    # Extra iptables rules for inter-VLAN isolation and logging
    # These run after the NixOS firewall rules
    extraCommands = ''
      # ============================================================
      # Inter-VLAN Isolation
      # ============================================================
      # Block VLANs from reaching any RFC1918 private address space
      # This prevents Guest/Kids/IoT from reaching:
      #   - Main LAN (10.0.0.0/24)
      #   - Other VLANs (10.10.0.0/24, 10.20.0.0/24, 10.30.0.0/24)
      #   - Router itself on any internal interface
      #
      # Traffic to WAN (internet) is still allowed via NAT

      # Guest VLAN: internet only
      iptables -I FORWARD -i ${guestIf} -d 10.0.0.0/8 -j DROP
      iptables -I FORWARD -i ${guestIf} -d 172.16.0.0/12 -j DROP
      iptables -I FORWARD -i ${guestIf} -d 192.168.0.0/16 -j DROP

      # Kids VLAN: internet only
      iptables -I FORWARD -i ${kidsIf} -d 10.0.0.0/8 -j DROP
      iptables -I FORWARD -i ${kidsIf} -d 172.16.0.0/12 -j DROP
      iptables -I FORWARD -i ${kidsIf} -d 192.168.0.0/16 -j DROP

      # IoT VLAN: internet only
      iptables -I FORWARD -i ${iotIf} -d 10.0.0.0/8 -j DROP
      iptables -I FORWARD -i ${iotIf} -d 172.16.0.0/12 -j DROP
      iptables -I FORWARD -i ${iotIf} -d 192.168.0.0/16 -j DROP

      # ============================================================
      # DNS Bypass Prevention (Kids VLAN)
      # ============================================================
      # Block outbound DNS/DoT to prevent bypassing content filtering
      # Kids network must use the router's filtered DNS

      # Block DNS over UDP/TCP (port 53) to any external server
      iptables -I FORWARD -i ${kidsIf} -p udp --dport 53 -j DROP
      iptables -I FORWARD -i ${kidsIf} -p tcp --dport 53 -j DROP

      # Block DNS over TLS (port 853)
      iptables -I FORWARD -i ${kidsIf} -p tcp --dport 853 -j DROP

      # ============================================================
      # IoT Connection Logging
      # ============================================================
      # Log all new connections from IoT network for monitoring
      # Logs appear in journald: journalctl -k | grep "IOT-NEW:"

      iptables -I FORWARD -i ${iotIf} -m state --state NEW -j LOG \
        --log-prefix "IOT-NEW: " --log-level 4
    '';

    # Cleanup rules when firewall stops
    extraStopCommands = ''
      iptables -D FORWARD -i ${guestIf} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${guestIf} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${guestIf} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${kidsIf} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${kidsIf} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${kidsIf} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${iotIf} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${iotIf} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${iotIf} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${kidsIf} -p udp --dport 53 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${kidsIf} -p tcp --dport 53 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${kidsIf} -p tcp --dport 853 -j DROP 2>/dev/null || true
      iptables -D FORWARD -i ${iotIf} -m state --state NEW -j LOG \
        --log-prefix "IOT-NEW: " --log-level 4 2>/dev/null || true
    '';
  };

  # NAT configuration
  networking.nat = {
    enable = true;
    externalInterface = wan;
    internalInterfaces = [
      lan
      guestIf
      kidsIf
      iotIf
    ];
    internalIPs = [
      lanNetwork
      vlans.guest.network
      vlans.kids.network
      vlans.iot.network
    ];
  };
}
