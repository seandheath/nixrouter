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

{ config, lib, pkgs, ... }:

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
in
{
  # Enable IP forwarding (required for routing)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;

    # IPv6 forwarding is deliberately OFF.
    #
    # Every isolation rule in extraCommands below is `iptables` only -- none of
    # it is mirrored to ip6tables -- and the ip6tables FORWARD chain is empty
    # with an ACCEPT policy. There is also no NAT layer incidentally covering
    # for that on v6. Today the WAN only gets a bare /128 with no prefix
    # delegation, so no LAN client has a v6 address and nothing is exposed;
    # forwarding=1 was latent rather than actively dangerous. But it would
    # become a hole the moment a prefix arrives, so close it explicitly rather
    # than depending on the ISP not delegating one.
    #
    # Re-enabling this is part of the IPv6 work, NOT a prerequisite for it:
    # mirror the VLAN isolation and Kids DNS rules to ip6tables and set a
    # default-deny forward policy FIRST, then flip this to 1.
    "net.ipv6.conf.all.forwarding" = 0;

    # Allow IPv6 autoconfiguration on WAN only, so the router itself can reach
    # v6-only upstream endpoints. Value 2 = accept RA even when forwarding is
    # enabled; harmless with forwarding off, and correct if it is turned back on.
    "net.ipv6.conf.${wan}.accept_ra" = 2;
    "net.ipv6.conf.${wan}.autoconf" = 1;
  };

  # NixOS declarative firewall
  networking.firewall = {
    enable = true;

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
          22  # SSH
          53  # DNS
          80  # nginx (reverse-proxies http://kids.lan/ + http://adguard.lan/)
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

      # ============================================================
      # Kids VLAN pinholes (config.nix `kidsPinholes`)
      # ============================================================
      # Inserted LAST, and at position 1, so they sit above the blanket
      # `-d 10.0.0.0/8 -j DROP` above -- punching through it is their entire
      # purpose. See config.nix for why this is narrower than it looks: one
      # UDP port on one host, carrying an encrypted tunnel that applies its
      # own per-peer policy at the far end.
      #
      # Delete-then-insert so repeated firewall starts cannot stack duplicates.
      ${lib.concatMapStringsSep "\n      " (p: ''
        iptables -D FORWARD -i ${kidsIf} -d ${p.host} -p ${p.proto} --dport ${toString p.port} -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 1 -i ${kidsIf} -d ${p.host} -p ${p.proto} --dport ${toString p.port} -j ACCEPT'') cfg.kidsPinholes}

      # ============================================================
      # VLAN Leak Prevention (wired LAN port)
      # ============================================================
      # ${wiredLan} faces an unmanaged switch. Nothing behind it has any
      # business emitting 802.1Q-tagged frames, and brLan runs with
      # vlan_filtering=0 -- so a tagged frame arriving here gets flooded
      # straight out the trunk into the AP's VLAN domain.
      #
      # This is exactly what happened during the 2026-07-28 bridge loop:
      # 96% of frames received on ${wiredLan} were tagged vlan 10/20
      # (Guest/Kids), i.e. VLAN traffic was transiting the main LAN segment
      # and defeating the isolation modules/vlans.nix is built to provide.
      #
      # Filtering has to happen in the bridge (ebtables) rather than in
      # iptables: these frames are switched, not routed, so they never reach
      # the IP hooks. Deletes run first so repeated firewall starts don't
      # stack duplicate rules.
      #
      # NOTE when verifying: pkgs.ebtables is ebtables-legacy (v2.0.11), but
      # `ebtables` on $PATH resolves to iptables' xtables-nft-multi, which
      # reads the nft bridge family instead. They are separate rule stores --
      # listing with the wrong one shows an empty table and looks like these
      # rules failed to apply. Check with the same binary used here:
      #   sudo ${pkgs.ebtables}/bin/ebtables -L --Lc
      for chain in INPUT FORWARD; do
        for proto in 802_1Q 0x88A8; do
          ${pkgs.ebtables}/bin/ebtables -D $chain -i ${wiredLan} -p $proto -j DROP 2>/dev/null || true
          ${pkgs.ebtables}/bin/ebtables -A $chain -i ${wiredLan} -p $proto -j DROP
        done
      done
    '';

    # Cleanup rules when firewall stops
    extraStopCommands = ''
      ${lib.concatMapStringsSep "\n      " (p:
        "iptables -D FORWARD -i ${kidsIf} -d ${p.host} -p ${p.proto} --dport ${toString p.port} -j ACCEPT 2>/dev/null || true"
      ) cfg.kidsPinholes}
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
      for chain in INPUT FORWARD; do
        for proto in 802_1Q 0x88A8; do
          ${pkgs.ebtables}/bin/ebtables -D $chain -i ${wiredLan} -p $proto -j DROP 2>/dev/null || true
        done
      done
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
    # DNAT lands in PREROUTING matching `-i ${wan}`, so these packets are FORWARDed,
    # never delivered locally — which is why there is no matching entry in the WAN
    # interface's allowedUDPPorts above, and why a host on an internal VLAN cannot
    # reach these by dialling our own WAN address (no hairpin). That is what
    # `kidsPinholes` exists to work around.
    forwardPorts = map (f: {
      sourcePort = f.port;
      proto = f.proto;
      destination = "${f.destination}:${toString f.port}";
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
