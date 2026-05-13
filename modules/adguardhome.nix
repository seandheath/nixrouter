# AdGuard Home for the Kids VLAN
#
# AGH is the sole authority for both DNS and DHCP on the Kids VLAN
# (10.20.0.0/24). Admin UI is reachable only from brLan
# ("skynet" SSID).
#
# Bindings:
#   DNS:       10.20.0.1:53   (eth1.20 only)
#   DHCP:      eth1.20         (range 10.20.0.100-.254, 12h leases)
#   Admin UI:  127.0.0.1:3000 (loopback only; reach via http://adguard.lan/
#              which nginx (modules/nginx.nix) proxies on brLan)
#
# State:
#   /var/lib/AdGuardHome (persisted via modules/impermanence.nix)
#
# mutableSettings = true:
#   The Nix-supplied `settings` block is merged on top of the live YAML
#   on every rebuild. yaml-merge deep-merges maps but does NOT merge
#   arrays - it overwrites them. Practical implications:
#
#   - We do NOT declare `settings.users` or `settings.filters` here;
#     those are managed via the web UI on first boot and preserved.
#   - We do NOT declare `settings.dns.upstream_dns` or `bootstrap_dns`;
#     the kids-mode toggle service (modules/kids-mode.nix) owns those
#     at runtime and would have its writes silently reverted on every
#     rebuild if Nix declared them too.
#   - We DO declare the basic DHCP scope (interface, gateway, range,
#     lease time) since those are stable across rebuilds. Static
#     leases are NOT declared here - the user manages those via the
#     UI, and the array-overwrite behavior would otherwise wipe them.
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

    # Grant CAP_NET_RAW so AGH can serve DHCP. The NixOS module gates
    # this capability behind allowDHCP; without it AGH starts but
    # DHCP socket binding fails.
    allowDHCP = true;

    # Admin UI bind. With schema_version >= 23 the NixOS module writes
    # these into `http.address` only - DNS bind is governed entirely by
    # `settings.dns.bind_hosts` below.
    #
    # 127.0.0.1: loopback only. nginx (modules/nginx.nix) is the
    # public entry point on http://adguard.lan/ from brLan.
    host = "127.0.0.1";
    port = 3000;

    # nginx fronts this; nothing should hit AGH directly from the network.
    openFirewall = false;

    settings = {
      dns = {
        # Bind DNS only on the kids gateway IP. AGH binds to addresses
        # (not interfaces), so this address must already be assigned by
        # systemd-networkd when AGH starts; the systemd ordering below
        # waits on the eth1.20 device unit.
        bind_hosts = [ vlans.kids.address ];   # 10.20.0.1
        port = 53;

        # Validate DNSSEC at the resolver.
        enable_dnssec = true;

        # Don't forward private-range PTRs upstream. AGH auto-detects
        # the host's local resolver as 127.0.0.53:53 (systemd-resolved
        # stub), which isn't running on this router - dnsmasq is. Every
        # PTR for a 10.20.0.x client would stall 2s before timing out.
        # AGH still answers PTRs for its own DHCP leases from its
        # internal lease table.
        use_private_ptr_resolvers = false;

        # upstream_dns / bootstrap_dns intentionally not set here.
        # kids-mode-web sets them at runtime per current mode. AGH's
        # built-in default (Quad9) is fine for the brief window before
        # the toggle service has a chance to reconcile.
      };

      # DHCP scope. Static leases are NOT declared here - manage them
      # via the AGH UI (Settings -> DHCP). We rely on yaml-merge's
      # deep-merge of maps to leave UI-managed fields like static_leases
      # untouched on rebuild.
      dhcp = {
        enabled = true;
        interface_name = kidsIf;
        dhcpv4 = {
          gateway_ip = vlans.kids.address;        # 10.20.0.1
          subnet_mask = "255.255.255.0";          # /24, matches vlans.kids.prefixLength
          range_start = vlans.kids.dhcpStart;     # 10.20.0.100
          range_end   = vlans.kids.dhcpEnd;       # 10.20.0.254
          lease_duration = 43200;                 # 12h, in seconds
          icmp_timeout_msec = 1000;
        };
      };
    };
  };

  # AGH's bind_hosts and DHCP interface_name both require eth1.20 to
  # exist before AGH starts. Mirror the dnsmasq pattern.
  systemd.services.adguardhome = {
    after = [ "sys-subsystem-net-devices-${kidsIf}.device" ];
    wants = [ "sys-subsystem-net-devices-${kidsIf}.device" ];
  };
}
