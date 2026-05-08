# AdGuard Home for the Kids VLAN
#
# Provides DNS resolution and content filtering for the Kids VLAN
# (10.20.0.0/24). The web admin UI is exposed only on the main LAN
# bridge (brLan, 10.0.0.0/24) so it's reachable from the trusted
# "skynet" SSID and not from any other VLAN or the WAN.
#
# Bindings:
#   DNS:       10.20.0.1:53   (eth1.20 only)
#   Admin UI:  10.0.0.1:3000  (brLan only - firewall.nix opens 3000/tcp)
#
# DHCP for the Kids VLAN is intentionally NOT served by AGH; the
# dnsmasq-kids sidecar (modules/dns-blocklist.nix) keeps that role
# and continues to advertise 10.20.0.1 as the DNS server, which is
# now answered by AGH.
#
# State:
#   /var/lib/AdGuardHome (persisted via modules/impermanence.nix)
#
# mutableSettings = true:
#   The Nix-supplied `settings` block is merged on top of the live
#   YAML on every rebuild. yaml-merge does NOT deep-merge arrays, so
#   declaring `settings.users` or `settings.filters` here would clobber
#   anything configured via the web UI. We deliberately leave both
#   unset; the admin user/password is created via the first-run wizard
#   at http://10.0.0.1:3000/ and filter lists are managed in the UI.
#
# References:
#   - https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration
#   - https://search.nixos.org/options?query=services.adguardhome

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;
  vlans = cfg.vlans;

  # Tagged kids interface on the trunk port (e.g. "enp4s0f0.20")
  kidsIf = "${lan}.${toString vlans.kids.id}";
in
{
  services.adguardhome = {
    enable = true;

    # Mutable: bootstrap minimal config in Nix; further tuning via UI
    # persists across rebuilds. See header comment for caveats.
    mutableSettings = true;

    # Admin UI bind. With schema_version >= 23 the NixOS module writes
    # these into `http.address` only - DNS bind is governed entirely by
    # `settings.dns.bind_hosts` below.
    host = cfg.lan.address;   # 10.0.0.1 (brLan gateway)
    port = 3000;

    # We open 3000/tcp explicitly on brLan in firewall.nix so the UI
    # cannot leak to other VLANs or the WAN. `openFirewall = true` would
    # open it on all interfaces.
    openFirewall = false;

    settings = {
      dns = {
        # Bind DNS only on the kids gateway IP. AGH binds to addresses
        # (not interfaces), so this address must already be assigned by
        # systemd-networkd when AGH starts; the systemd ordering below
        # waits on the eth1.20 device unit.
        bind_hosts = [ vlans.kids.address ];   # 10.20.0.1
        port = 53;

        # Plain-IP upstreams - no DoH/DoT, so bootstrap_dns is not
        # strictly needed. Setting it anyway makes a future switch to
        # encrypted upstreams a one-line change.
        upstream_dns = cfg.upstreamDns;
        bootstrap_dns = cfg.upstreamDns;

        # Validate DNSSEC at the resolver.
        enable_dnssec = true;
      };

      # AGH's own DHCP server stays disabled; dnsmasq-kids handles DHCP
      # for the Kids VLAN.
      dhcp.enabled = false;

      # `users` and `filters` intentionally unset - managed via the
      # web UI. See header comment.
    };
  };

  # Boot/rebuild ordering:
  #
  # 1. Wait for the kids VLAN device unit so 10.20.0.1 has been
  #    assigned by systemd-networkd before AGH tries to bind.
  # 2. Wait for dnsmasq-kids so on a rebuild that flips it from DNS+DHCP
  #    to DHCP-only (port=0), it releases :53 before AGH tries to claim
  #    it. systemd's switch-to-configuration honors `after` ordering
  #    when restarting units.
  systemd.services.adguardhome = {
    after = [
      "sys-subsystem-net-devices-${kidsIf}.device"
      "dnsmasq-kids.service"
    ];
    wants = [ "sys-subsystem-net-devices-${kidsIf}.device" ];
  };
}
