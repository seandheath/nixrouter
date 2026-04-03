# dnsmasq configuration for DHCP and DNS
#
# Provides:
#   - DHCP server on br-lan and VLAN interfaces
#   - Caching DNS resolver with optional blocklist filtering
#   - Router advertisement for each network
#
# Network configuration:
#   - Main LAN (br-lan): 10.0.0.0/24, DNS with base blocklist
#   - Guest VLAN (eth1.10): 10.10.0.0/24, DNS without filtering
#   - Kids VLAN (eth1.20): 10.20.0.0/24, DNS with extended blocklist
#   - IoT VLAN (eth1.30): 10.30.0.0/24, DNS without filtering
#
# DHCP leases are persisted to /nix/persist/var/lib/dnsmasq
#
# Reference: https://thekelleys.org.uk/dnsmasq/doc.html

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;
  bridge = cfg.bridgeName;
  vlans = cfg.vlans;

  # VLAN interface names (on trunk port)
  guestIf = "${lan}.${toString vlans.guest.id}";
  kidsIf = "${lan}.${toString vlans.kids.id}";
  iotIf = "${lan}.${toString vlans.iot.id}";

  # Lease time for all networks
  leaseTime = cfg.lan.leaseTime;
in
{
  services.dnsmasq = {
    enable = true;

    # Don't update /etc/resolv.conf — this router IS the resolver.
    # Prevents preStart from writing to /etc/ which fails with impermanence.
    resolveLocalQueries = false;

    settings = {
      # --- Interface Binding ---
      # Listen on LAN and all VLAN interfaces (not WAN!)
      interface = [
        bridge
        guestIf
        kidsIf
        iotIf
      ];
      bind-interfaces = true;

      # --- DHCP Configuration ---
      # Multiple DHCP ranges for each network
      dhcp-range = [
        # Main LAN
        "${cfg.lan.dhcpStart},${cfg.lan.dhcpEnd},${leaseTime}"
        # Guest VLAN
        "${vlans.guest.dhcpStart},${vlans.guest.dhcpEnd},${leaseTime}"
        # Kids VLAN
        "${vlans.kids.dhcpStart},${vlans.kids.dhcpEnd},${leaseTime}"
        # IoT VLAN
        "${vlans.iot.dhcpStart},${vlans.iot.dhcpEnd},${leaseTime}"
      ];

      # Per-interface router and DNS server options
      # dnsmasq auto-detects the correct network based on interface
      dhcp-option = [
        # Main LAN (bridge)
        "tag:${bridge},option:router,${cfg.lan.address}"
        "tag:${bridge},option:dns-server,${cfg.lan.address}"

        # Guest VLAN
        "tag:${guestIf},option:router,${vlans.guest.address}"
        "tag:${guestIf},option:dns-server,${vlans.guest.address}"

        # Kids VLAN
        "tag:${kidsIf},option:router,${vlans.kids.address}"
        "tag:${kidsIf},option:dns-server,${vlans.kids.address}"

        # IoT VLAN
        "tag:${iotIf},option:router,${vlans.iot.address}"
        "tag:${iotIf},option:dns-server,${vlans.iot.address}"
      ];

      # Persist DHCP leases
      dhcp-leasefile = "/var/lib/dnsmasq/dnsmasq.leases";

      # Authoritative mode (respond to all DHCP requests, even if not ours)
      dhcp-authoritative = true;

      # --- DNS Configuration ---
      # Don't read /etc/resolv.conf (use upstream servers below)
      no-resolv = true;

      # Upstream DNS servers (privacy-focused)
      server = cfg.upstreamDns;

      # Enable DNSSEC validation
      dnssec = true;
      trust-anchor = ".,20326,8,2,E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D";

      # Cache size (number of DNS entries)
      cache-size = 10000;

      # Don't cache negative responses (NXDOMAIN) for too long
      neg-ttl = 60;

      # --- Security ---
      # Don't forward queries for local-only domains
      domain-needed = true;
      bogus-priv = true;

      # Don't forward queries without a domain part
      local-service = true;

      # --- Blocklist Configuration ---
      # Base blocklist applies to Main LAN only (via dns-blocklist.nix)
      # Kids VLAN uses separate dnsmasq instance for extended filtering
      # Guest and IoT use unfiltered DNS

      # --- Logging ---
      # Log queries (useful for debugging, disable in production)
      # log-queries = true;
      # log-dhcp = true;

      # --- Local Domain ---
      # Optional: Set a local domain for DHCP clients
      # domain = "lan";
      # local = "/lan/";
      # expand-hosts = true;

      # --- Static Leases ---
      # Add static DHCP reservations here
      # dhcp-host = "aa:bb:cc:dd:ee:ff,10.0.0.10,hostname";
    };
  };

  # Wait for bridge and VLAN interfaces before starting dnsmasq
  systemd.services.dnsmasq = {
    after = [ "sys-subsystem-net-devices-${bridge}.device" "sys-subsystem-net-devices-${guestIf}.device" "sys-subsystem-net-devices-${kidsIf}.device" "sys-subsystem-net-devices-${iotIf}.device" ];
    wants = [ "sys-subsystem-net-devices-${bridge}.device" "sys-subsystem-net-devices-${guestIf}.device" "sys-subsystem-net-devices-${kidsIf}.device" "sys-subsystem-net-devices-${iotIf}.device" ];
  };

  # Create lease file directory with correct permissions
  systemd.tmpfiles.rules = [
    "f /var/lib/dnsmasq/dnsmasq.leases 0644 dnsmasq dnsmasq -"
  ];
}
