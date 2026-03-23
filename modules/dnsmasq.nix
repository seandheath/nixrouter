# dnsmasq configuration for DHCP and DNS
#
# Provides:
#   - DHCP server on LAN interface (10.0.0.100-254)
#   - Caching DNS resolver
#   - Router advertisement (10.0.0.1)
#
# DHCP leases are persisted to /nix/persist/var/lib/dnsmasq
#
# Reference: https://thekelleys.org.uk/dnsmasq/doc.html

{ config, lib, pkgs, ... }:

let
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;
  lanAddress = "10.0.0.1";
  dhcpRangeStart = "10.0.0.100";
  dhcpRangeEnd = "10.0.0.254";
  leaseTime = "12h";
in
{
  services.dnsmasq = {
    enable = true;

    settings = {
      # --- Interface Binding ---
      # Only listen on LAN interface (not WAN!)
      interface = lan;
      bind-interfaces = true;

      # --- DHCP Configuration ---
      dhcp-range = "${dhcpRangeStart},${dhcpRangeEnd},${leaseTime}";

      # Advertise router (default gateway)
      dhcp-option = [
        "option:router,${lanAddress}"
        "option:dns-server,${lanAddress}"
        # Optional: NTP server
        # "option:ntp-server,${lanAddress}"
      ];

      # Persist DHCP leases
      dhcp-leasefile = "/var/lib/dnsmasq/dnsmasq.leases";

      # Authoritative mode (respond to all DHCP requests, even if not ours)
      dhcp-authoritative = true;

      # --- DNS Configuration ---
      # Don't read /etc/resolv.conf (use upstream servers below)
      no-resolv = true;

      # Upstream DNS servers (privacy-focused)
      server = [
        "1.1.1.1"        # Cloudflare
        "1.0.0.1"        # Cloudflare secondary
        "9.9.9.9"        # Quad9
        "8.8.8.8"        # Google (fallback)
      ];

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

  # Ensure dnsmasq can write to its state directory
  # (Directory created by impermanence.nix tmpfiles rules)
  systemd.services.dnsmasq = {
    serviceConfig = {
      # Run as dnsmasq user (created in impermanence.nix)
      User = "dnsmasq";
      Group = "dnsmasq";
      # Hardening (use mkForce to override NixOS defaults)
      ProtectHome = lib.mkForce true;
      ProtectSystem = lib.mkForce "strict";
      ReadWritePaths = [ "/var/lib/dnsmasq" ];
      PrivateTmp = lib.mkForce true;
      NoNewPrivileges = lib.mkForce true;
      # Need to bind to port 53 and 67
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" ];
    };
  };

  # Create lease file directory with correct permissions
  systemd.tmpfiles.rules = [
    "f /var/lib/dnsmasq/dnsmasq.leases 0644 dnsmasq dnsmasq -"
  ];
}
