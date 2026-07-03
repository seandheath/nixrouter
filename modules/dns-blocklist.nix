# DNS blocklist for the main LAN dnsmasq
#
# Loads a daily-refreshed StevenBlack hosts file into the main dnsmasq
# instance via addn-hosts so brLan clients get ad/tracker/malware
# blocking transparently.
#
# Kids VLAN filtering is NOT handled here - that lives entirely in
# AdGuard Home (modules/adguardhome.nix) with mode toggling driven by
# modules/kids-mode.nix.
#
# Blocklist source:
#   Base: https://github.com/StevenBlack/hosts (unified hosts)

{ config, lib, pkgs, ... }:

let
  baseBlocklist = "/var/lib/dnsmasq/blocklist-base.hosts";
  baseBlocklistUrl = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";

  # Domains to un-block. dnsmasq answers addn-hosts entries authoritatively,
  # so a server=/domain/# override cannot beat a 0.0.0.0 hosts entry. The only
  # reliable fix is to strip these lines from the fetched hosts file.
  #
  # googleadservices.com is Google's ad-click redirector: shopping/product-ad
  # links (www.googleadservices.com/pagead/aclk?...) dead-end without it.
  allowlist = [
    "googleadservices.com"
    "www.googleadservices.com"
  ];

  # ERE alternation of allowlisted hosts with dots escaped, e.g.
  # "googleadservices\.com|www\.googleadservices\.com".
  allowlistPattern = lib.concatStringsSep "|"
    (map (d: lib.replaceStrings [ "." ] [ "\\." ] d) allowlist);
in
{
  # Add blocklist to main dnsmasq instance (LAN only)
  # Blocked domains resolve to 0.0.0.0
  services.dnsmasq.settings = {
    addn-hosts = baseBlocklist;
  };

  # Systemd timer to update the blocklist daily.
  systemd.services.update-dns-blocklists = {
    description = "Update DNS blocklist (main LAN)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.curl pkgs.coreutils pkgs.gnugrep ];

    script = ''
      set -euo pipefail

      mkdir -p /var/lib/dnsmasq

      # Download base blocklist (ads, trackers, malware)
      curl -sL --fail --retry 3 --max-time 60 \
        -o ${baseBlocklist}.raw \
        "${baseBlocklistUrl}"

      # Strip allowlisted domains. Match on the host field only: whitespace
      # (the 0.0.0.0 separator) followed by the exact domain at end of line,
      # so "notgoogleadservices.com" or subdomains aren't removed.
      grep -viE '[[:space:]](${allowlistPattern})$' \
        ${baseBlocklist}.raw > ${baseBlocklist}.tmp
      rm -f ${baseBlocklist}.raw

      # Atomically replace old file
      mv ${baseBlocklist}.tmp ${baseBlocklist}
      chown dnsmasq:dnsmasq ${baseBlocklist}
      chmod 644 ${baseBlocklist}

      echo "Base blocklist: $(wc -l < ${baseBlocklist}) entries"

      # SIGHUP for graceful reload.
      systemctl reload dnsmasq || true
    '';

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      TimeoutStartSec = "5min";
    };
  };

  systemd.timers.update-dns-blocklists = {
    description = "Daily DNS blocklist update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # Seed an empty blocklist file so dnsmasq can start before the first
  # fetch completes.
  systemd.tmpfiles.rules = [
    "f ${baseBlocklist} 0644 dnsmasq dnsmasq -"
  ];

  # Run blocklist update on first boot if the file doesn't exist yet.
  systemd.services.update-dns-blocklists-initial = {
    description = "Initial DNS blocklist fetch";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "dnsmasq.service" ];

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
