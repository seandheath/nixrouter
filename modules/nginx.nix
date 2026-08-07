# Reverse proxy for the router's brLan-only admin web UIs.
#
# nginx terminates HTTP on 10.0.0.1:80 and proxies by Host header:
#
#   http://kids.lan/    -> 127.0.0.1:3001  (kids-mode toggle UI)
#   http://adguard.lan/ -> 127.0.0.1:3000  (AdGuard Home UI)
#
# Both backends bind to loopback only so they're not directly reachable
# from any network - clients must come through nginx, which only
# listens on the brLan address (gated by interface, not iptables).
#
# Hostnames are resolved by the main dnsmasq instance (modules/dnsmasq.nix),
# which serves brLan, Guest, and IoT. The Kids VLAN uses AGH for DNS and
# can't reach these hostnames - intentional, kids should not have access
# to the router admin UIs.

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;

  # brLan for anyone in the house, and the management tunnel's address for anyone
  # outside it. NOT 10.0.0.1 over the tunnel: that is a client's own default gateway
  # whenever it is on home wifi, and routing it into a tunnel takes that device's
  # network out entirely (it did exactly that to sulfur on 2026-08-06). So remote
  # clients reach these UIs at 10.42.0.3, and hydrogen's tunnel resolver answers
  # kids.lan/adguard.lan with that address for peers already inside.
  listenAddrs = [
    { addr = cfg.lan.address; port = 80; }
  ] ++ lib.optional cfg.wireguardMgmt.enable { addr = cfg.wireguardMgmt.address; port = 80; };
in
{
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;     # X-Forwarded-* headers, etc.
    recommendedOptimisation = true;      # sendfile, tcp_nopush, etc.

    # Reject requests that don't match a known vhost so probing the IP
    # directly doesn't leak which vhosts exist.
    virtualHosts."_default_" = {
      listen = listenAddrs;
      default = true;
      locations."/" = {
        return = "404";
      };
    };

    virtualHosts."kids.lan" = {
      listen = listenAddrs;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3001";
        proxyWebsockets = true;
      };
    };

    virtualHosts."adguard.lan" = {
      listen = listenAddrs;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;          # AGH dashboard uses WS for live updates
      };
    };
  };

  # Order nginx after the backends so the first request after boot
  # doesn't 502. Backends being slow doesn't block nginx startup
  # because of `wants` (soft dep).
  systemd.services.nginx = {
    after = [ "adguardhome.service" "kids-mode-web.service" ];
    wants = [ "adguardhome.service" "kids-mode-web.service" ];
  };
}
