# DNS blocklist configuration for content filtering
#
# Provides tiered DNS-based content filtering:
#   - Base blocklist: ads, trackers, malware (Main LAN)
#   - Extended blocklist: base + adult content, gambling, social (Kids network)
#
# Implementation:
#   - Uses StevenBlack/hosts blocklists
#   - Base blocklist loaded via dnsmasq addn-hosts
#   - Kids network runs separate dnsmasq instance with extended blocklist
#   - Blocklists updated daily via systemd timer
#
# Blocklist sources:
#   - Base: https://github.com/StevenBlack/hosts (unified hosts)
#   - Extended: https://github.com/StevenBlack/hosts (alternates/fakenews-gambling-porn-social)
#
# Reference: https://github.com/StevenBlack/hosts

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;
  vlans = cfg.vlans;

  kidsIf = "${lan}.${toString vlans.kids.id}";

  # Blocklist file locations
  baseBlocklist = "/var/lib/dnsmasq/blocklist-base.hosts";
  kidsBlocklist = "/var/lib/dnsmasq/blocklist-kids.hosts";

  # StevenBlack hosts URLs
  # Unified hosts: ads, malware, fakenews
  baseBlocklistUrl = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
  # Extended: unified + gambling + porn + social
  kidsBlocklistUrl = "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn-social/hosts";
in
{
  # Add blocklist to main dnsmasq instance (LAN only)
  # This configures the base ad/tracker/malware blocking
  services.dnsmasq.settings = {
    # Load base blocklist (ads, trackers, malware)
    # Blocked domains resolve to 0.0.0.0
    addn-hosts = baseBlocklist;
  };

  # Separate dnsmasq instance for Kids network with extended filtering
  # This runs on a different port internally and handles Kids VLAN DNS
  systemd.services.dnsmasq-kids = {
    description = "DNS forwarder and DHCP server (Kids network - filtered)";
    documentation = [ "man:dnsmasq(8)" ];
    after = [ "network.target" "sys-subsystem-net-devices-${kidsIf}.device" ];
    wants = [ "sys-subsystem-net-devices-${kidsIf}.device" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq -k --conf-file=/etc/dnsmasq-kids.conf";
      User = "dnsmasq";
      Group = "dnsmasq";
      Restart = "on-failure";
      RestartSec = "5s";

      # Capabilities needed for port 53 binding
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" ];
    };
  };

  # Configuration file for Kids dnsmasq instance
  environment.etc."dnsmasq-kids.conf".text = ''
    # Kids network dnsmasq configuration
    # Extended content filtering

    # Bind only to Kids VLAN interface
    interface=${kidsIf}
    bind-interfaces

    # DNS on standard port
    port=53

    # DHCP for Kids VLAN
    dhcp-range=${vlans.kids.dhcpStart},${vlans.kids.dhcpEnd},${cfg.lan.leaseTime}
    dhcp-option=option:router,${vlans.kids.address}
    dhcp-option=option:dns-server,${vlans.kids.address}
    dhcp-leasefile=/var/lib/dnsmasq/dnsmasq-kids.leases
    dhcp-authoritative

    # Listen on the Kids VLAN gateway address
    listen-address=${vlans.kids.address}

    # Upstream DNS (same as main)
    no-resolv
    ${lib.concatMapStringsSep "\n" (s: "server=${s}") cfg.upstreamDns}

    # DNSSEC
    dnssec
    trust-anchor=.,20326,8,2,E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D

    # Cache
    cache-size=5000
    neg-ttl=60

    # Security
    domain-needed
    bogus-priv

    # Extended blocklist (kids content filtering)
    addn-hosts=${kidsBlocklist}

    # Log blocked queries (optional, can be verbose)
    # log-queries
  '';

  # Systemd timer to update blocklists daily
  systemd.services.update-dns-blocklists = {
    description = "Update DNS blocklists";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.curl pkgs.coreutils ];

    script = ''
      set -euo pipefail

      echo "Updating DNS blocklists..."

      # Create directory if needed
      mkdir -p /var/lib/dnsmasq

      # Download base blocklist (ads, trackers, malware)
      echo "Fetching base blocklist..."
      curl -sL --fail --retry 3 --max-time 60 \
        -o ${baseBlocklist}.tmp \
        "${baseBlocklistUrl}"

      # Download extended blocklist (base + adult, gambling, social)
      echo "Fetching kids blocklist..."
      curl -sL --fail --retry 3 --max-time 60 \
        -o ${kidsBlocklist}.tmp \
        "${kidsBlocklistUrl}"

      # Atomically replace old files
      mv ${baseBlocklist}.tmp ${baseBlocklist}
      mv ${kidsBlocklist}.tmp ${kidsBlocklist}

      # Fix permissions
      chown dnsmasq:dnsmasq ${baseBlocklist} ${kidsBlocklist}
      chmod 644 ${baseBlocklist} ${kidsBlocklist}

      echo "Blocklists updated successfully"
      echo "Base blocklist: $(wc -l < ${baseBlocklist}) entries"
      echo "Kids blocklist: $(wc -l < ${kidsBlocklist}) entries"

      # Reload dnsmasq to pick up new blocklists
      # Use SIGHUP for graceful reload
      echo "Reloading dnsmasq..."
      systemctl reload dnsmasq || true
      systemctl reload dnsmasq-kids || true

      echo "Done"
    '';

    serviceConfig = {
      Type = "oneshot";
      # Run as root to write files, dnsmasq reads them
      User = "root";
      # Timeouts
      TimeoutStartSec = "5min";
    };
  };

  systemd.timers.update-dns-blocklists = {
    description = "Daily DNS blocklist update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Run daily at 4 AM
      OnCalendar = "*-*-* 04:00:00";
      # Run on boot if missed
      Persistent = true;
      # Randomize within 1 hour to avoid thundering herd
      RandomizedDelaySec = "1h";
    };
  };

  # Create initial empty blocklist files so dnsmasq can start
  # They'll be populated by the update service
  systemd.tmpfiles.rules = [
    "f ${baseBlocklist} 0644 dnsmasq dnsmasq -"
    "f ${kidsBlocklist} 0644 dnsmasq dnsmasq -"
    "f /var/lib/dnsmasq/dnsmasq-kids.leases 0644 dnsmasq dnsmasq -"
  ];

  # Run blocklist update on first boot
  # This ensures blocklists are available immediately after deployment
  systemd.services.update-dns-blocklists-initial = {
    description = "Initial DNS blocklist fetch";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "dnsmasq.service" "dnsmasq-kids.service" ];

    # Only run if blocklists don't exist or are empty
    unitConfig = {
      ConditionPathExists = "!${baseBlocklist}";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.systemd.package}/bin/systemctl start update-dns-blocklists";
    };
  };
}
