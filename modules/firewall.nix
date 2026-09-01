# Firewall and NAT configuration
#
# Architecture:
#   WAN (external) <---> [Router] <---> brLan (10.0.0.0/24)
#                                  |       ├── eth1 (trunk to AP)
#                                  |       └── eth2 (unmanaged switch)
#                                  +---> Guest VLAN (10.10.0.0/24) - isolated
#                                  +---> Kids VLAN (10.20.0.0/24) - filtered
#                                  +---> IoT VLAN (10.30.0.0/24) - logged
#
# Policy:
#   - Input: Allow SSH/DHCP/DNS from brLan only, drop from WAN and VLANs
#   - Forward: Allow brLan→WAN, VLAN→WAN, block inter-VLAN and VLAN→LAN
#   - NAT: Masquerade outbound traffic on WAN interface
#
# Security:
#   - VLANs cannot reach each other or the main LAN (10.0.0.0/8 blocked)
#   - VLANs cannot SSH to router (management from brLan only)
#   - IoT connections are logged for monitoring
#
# Reference: https://nixos.wiki/wiki/Firewall

{ lib, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  wan = interfaces.wan;
  lan = interfaces.lan;
  wiredLan = interfaces.wiredLan;
  bridge = cfg.bridgeName;
  lanNetwork = cfg.lan.network;
  vlans = cfg.vlans;

  # VLAN interface names (on the trunk port, not the bridge)
  guestIf = "${lan}.${toString vlans.guest.id}";
  kidsIf = "${lan}.${toString vlans.kids.id}";
  iotIf = "${lan}.${toString vlans.iot.id}";
  wg = cfg.wireguard;
  mgmt = cfg.wireguardMgmt;
  wgIf = "wg0";
  mgmtIf = "wgmgt";
in
{
  # Enable IP forwarding (required for routing)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;

    # IPv6 forwarding is deliberately OFF.
    #
    # Today the WAN only gets a bare /128 with no prefix
    # delegation, so no LAN client has a v6 address and nothing is exposed;
    # forwarding=1 was latent rather than actively dangerous. But it would
    # become a hole the moment a prefix arrives, so close it explicitly rather
    # than depending on the ISP not delegating one.
    #
    # Re-enabling this is part of the IPv6 work, NOT a prerequisite for it:
    # assign routed VLAN prefixes and extend the nftables policy first.
    "net.ipv6.conf.all.forwarding" = lib.mkForce 0;

    # Allow IPv6 autoconfiguration on WAN only, so the router itself can reach
    # v6-only upstream endpoints. Value 2 = accept RA even when forwarding is
    # enabled; harmless with forwarding off, and correct if it is turned back on.
    "net.ipv6.conf.${wan}.accept_ra" = 2;
    "net.ipv6.conf.${wan}.autoconf" = 1;
  };

  # NixOS declarative firewall
  networking.nftables.enable = true;

  networking.firewall = {
    enable = true;
    filterForward = true;

    # WireGuard authenticates before it exposes any network service, so its handshake
    # sockets do not benefit from interface scoping. Keeping these global also matters
    # for vpn.luckyobserver.com on the LAN: the same endpoint must work whether nftables
    # reports an untagged frame against brLan, a bridge member, or the WAN interface.
    # Declare each listener exactly once; every ordinary service remains interface-bound
    # below, and forwarded 51821/51822 still require the DNAT rules in networking.nat.
    allowedUDPPorts =
      lib.optional wg.enable wg.port
      ++ lib.optional mgmt.enable mgmt.port;

    # Default: reject packets to closed ports (more polite than drop)
    rejectPackets = false;  # Use drop instead for stealth

    # Refused-connection logging off: dmesg/journal gets spammy on a
    # WAN-facing router. Flip back to true for debugging.
    logRefusedConnections = false;
    logRefusedPackets = false;

    # Allow ICMP ping
    allowPing = true;

    # Per-interface rules
    interfaces = {
      # Main LAN bridge - allow management services
      ${bridge} = {
        allowedTCPPorts = [
          22  # Key-only SSH recovery path when the management tunnel is unavailable
          53  # DNS
          80  # nginx (kids.lan + adguard.lan) -- deliberately stays: the kids-mode
              # toggle has to be reachable from any phone on home wifi in ten seconds,
              # and a phone on hydrogen's wgfam cannot reach this router at all.
          443 # Public Headscale control plane (also needed before tailnet enrollment)
        ];
        allowedUDPPorts = [
          53  # DNS
          67  # DHCP server
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
          443  # Headscale control plane
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
          443  # Headscale control plane
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
          443  # Headscale control plane
        ];
        allowedUDPPorts = [
          53   # DNS
          67   # DHCP server
        ];
      };

      ${wgIf} = lib.mkIf wg.enable {
        allowedTCPPorts = [ 22 53 80 443 ];
        allowedUDPPorts = [ 53 ];
      };

      ${mgmtIf} = lib.mkIf mgmt.enable {
        allowedTCPPorts = [ 22 53 80 ];
        allowedUDPPorts = [ 53 ];
      };
    };

    # Default-drop forwarding means VLANs and wgmgt reach nothing unless listed here.
    # mkBefore keeps the Kids DNS denial and IoT log ahead of the WAN accepts generated
    # by networking.nat. DNAT forwards are admitted by the NixOS firewall itself.
    extraForwardRules = lib.mkBefore ''
      iifname "${kidsIf}" udp dport 53 drop comment "Kids must use filtered DNS"
      iifname "${kidsIf}" tcp dport { 53, 853 } drop comment "Kids must use filtered DNS"
      ${lib.concatMapStringsSep "\n      " (p:
        ''iifname "${kidsIf}" ip daddr ${p.host} ${p.proto} dport ${toString p.port} accept comment "${p.comment}"''
      ) cfg.kidsPinholes}
      iifname "${iotIf}" ct state new log prefix "IOT-NEW: " level info

      iifname "${bridge}" accept comment "Main LAN may route to internal networks"
      ${lib.optionalString wg.enable ''
        iifname "${wgIf}" oifname "${bridge}" accept comment "Remote VPN may reach main LAN"
      ''}
    '';
  };

  # Layer-2 guard for the unmanaged-switch port, atomically managed by the
  # NixOS nftables service.
  networking.nftables.tables.vlan-guard = {
    family = "bridge";
    content = ''
      chain input {
        type filter hook input priority filter; policy accept;
        iifname "${wiredLan}" ether type { 0x8100, 0x88a8 } drop
      }

      chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "${wiredLan}" ether type { 0x8100, 0x88a8 } drop
      }
    '';
  };

  # NAT configuration
  networking.nat = {
    enable = true;
    externalInterface = wan;

    # WAN -> internal port forwards (config.nix `portForwards`). Today this is
    # hydrogen's two WireGuard hubs; see config.nix for what they carry and why
    # nothing else is forwarded.
    #
    # NixOS supplies WAN DNAT. The explicit rules above supply matching hairpin DNAT and
    # return-path masquerading for brLan and the Kids VLAN.
    forwardPorts = map (f: {
      sourcePort = f.port;
      proto = f.proto;
      destination = "${f.destination}:${toString f.port}";
      loopbackIPs = [ cfg.lan.address ];
    }) cfg.portForwards;
    internalInterfaces = [
      bridge
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
