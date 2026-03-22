# Firewall and NAT configuration
#
# Architecture:
#   WAN (external) <---> [Router] <---> LAN (10.0.0.0/24)
#
# Policy:
#   - Input: Allow SSH/DHCP/DNS from LAN only, drop from WAN
#   - Forward: Allow LAN→WAN, allow established WAN→LAN
#   - NAT: Masquerade outbound traffic on WAN interface
#
# Interface names come from router.interfaces.wan/lan options.
#
# Reference: https://nixos.wiki/wiki/Firewall

{ config, lib, pkgs, ... }:

let
  wan = config.router.interfaces.wan;
  lan = config.router.interfaces.lan;
  lanNetwork = "10.0.0.0/24";
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
    };
  };

  # NAT configuration
  networking.nat = {
    enable = true;
    externalInterface = wan;
    internalInterfaces = [ lan ];
    internalIPs = [ lanNetwork ];
  };
}
