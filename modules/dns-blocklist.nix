# DNS blocklist (Main LAN) and Kids VLAN DHCP sidecar
#
# Two responsibilities:
#   1. Base blocklist: ads/trackers/malware loaded into the main
#      dnsmasq instance via addn-hosts. Updated daily via systemd timer.
#   2. dnsmasq-kids: a DHCP-only sidecar that serves the Kids VLAN
#      (eth1.20). It does NOT answer DNS - port=0 disables that.
#      DNS for the Kids VLAN is handled by AdGuard Home; see
#      modules/adguardhome.nix. dnsmasq-kids advertises 10.20.0.1
#      as the DNS server in DHCP, which is now AGH's bind address.
#
# Why split DHCP from DNS for the Kids VLAN:
#   AGH brings a web UI, per-client policies, and richer filter
#   management. dnsmasq-kids stays for DHCP because it's already
#   battle-tested on this router and AGH's DHCP is less proven.
#
# Blocklist source:
#   Base: https://github.com/StevenBlack/hosts (unified hosts)

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;
  vlans = cfg.vlans;

  kidsIf = "${lan}.${toString vlans.kids.id}";

  # Blocklist file location (main LAN dnsmasq only - the Kids VLAN
  # uses AGH for filtering now)
  baseBlocklist = "/var/lib/dnsmasq/blocklist-base.hosts";

  # StevenBlack hosts URL: ads, malware, fakenews (unified)
  baseBlocklistUrl = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
in
{
  # Add blocklist to main dnsmasq instance (LAN only)
  # This configures the base ad/tracker/malware blocking
  services.dnsmasq.settings = {
    # Load base blocklist (ads, trackers, malware)
    # Blocked domains resolve to 0.0.0.0
    addn-hosts = baseBlocklist;
  };

  # DHCP sidecar for the Kids VLAN. DNS is served by AGH; this
  # instance runs with port=0 so it does not bind :53.
  # CAP_NET_BIND_SERVICE is now unused but kept for parity with the
  # main dnsmasq.service in case DNS is ever re-enabled here.
  systemd.services.dnsmasq-kids = {
    description = "DHCP server (Kids network)";
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

      # Capabilities for DHCP:
      #   CAP_NET_RAW       - raw sockets for DHCP packets
      #   CAP_NET_ADMIN     - dnsmasq enforces this in DHCP mode
      #   CAP_NET_BIND_SERVICE - unused now (port=0); kept for parity
      #     with dnsmasq.service so re-enabling DNS here doesn't break.
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" "CAP_NET_ADMIN" ];
    };
  };

  # Configuration file for Kids dnsmasq instance (DHCP-only)
  #
  # port=0 disables the DNS resolver entirely - dnsmasq still binds
  # raw sockets for DHCP independently of any UDP/53 listener.
  # Clients still get 10.20.0.1 advertised as their DNS server, which
  # is answered by AGH (see modules/adguardhome.nix).
  environment.etc."dnsmasq-kids.conf".text = ''
    # Kids VLAN DHCP-only configuration
    # DNS is handled by AdGuard Home on 10.20.0.1:53.

    # Bind only to Kids VLAN interface
    interface=${kidsIf}
    bind-interfaces

    # Disable DNS listener (DHCP only)
    port=0

    # DHCP for Kids VLAN
    dhcp-range=${vlans.kids.dhcpStart},${vlans.kids.dhcpEnd},${cfg.lan.leaseTime}
    dhcp-option=option:router,${vlans.kids.address}
    dhcp-option=option:dns-server,${vlans.kids.address}
    dhcp-leasefile=/var/lib/dnsmasq/dnsmasq-kids.leases
    dhcp-authoritative
  '';

  # Systemd timer to update blocklists daily
  systemd.services.update-dns-blocklists = {
    description = "Update DNS blocklists";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.curl pkgs.coreutils ];

    script = ''
      set -euo pipefail

      echo "Updating DNS blocklist (main LAN)..."

      # Create directory if needed
      mkdir -p /var/lib/dnsmasq

      # Download base blocklist (ads, trackers, malware)
      curl -sL --fail --retry 3 --max-time 60 \
        -o ${baseBlocklist}.tmp \
        "${baseBlocklistUrl}"

      # Atomically replace old file
      mv ${baseBlocklist}.tmp ${baseBlocklist}

      # Fix permissions
      chown dnsmasq:dnsmasq ${baseBlocklist}
      chmod 644 ${baseBlocklist}

      echo "Base blocklist: $(wc -l < ${baseBlocklist}) entries"

      # SIGHUP for graceful reload of the main dnsmasq instance.
      # dnsmasq-kids no longer reads any blocklist (DHCP-only), so it
      # does not need reloading.
      systemctl reload dnsmasq || true

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

  # Create initial empty blocklist file so dnsmasq can start before
  # the first fetch completes. The DHCP lease file for dnsmasq-kids
  # is also created here.
  systemd.tmpfiles.rules = [
    "f ${baseBlocklist} 0644 dnsmasq dnsmasq -"
    "f /var/lib/dnsmasq/dnsmasq-kids.leases 0644 dnsmasq dnsmasq -"
  ];

  # Run blocklist update on first boot
  # This ensures blocklists are available immediately after deployment
  systemd.services.update-dns-blocklists-initial = {
    description = "Initial DNS blocklist fetch";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "dnsmasq.service" ];

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
