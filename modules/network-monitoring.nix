# Network traffic visibility with ntopng.
#
# ntopng captures routed traffic on each internal network independently. This
# preserves the useful boundary in its UI: Main LAN, Guest, Kids, and IoT. The
# web server is loopback-only and is exposed by nginx at http://monitor.lan/.
#
# The wireless AP is separate hardware. A client seen on a tagged VLAN can be
# associated with that VLAN's SSID/network, but clients on brLan may be either
# wired or on the AP's untagged SSID. Exact AP/radio association requires an AP
# controller or SNMP integration and cannot be inferred from router traffic.

{ config, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  lan = interfaces.lan;
  vlans = cfg.vlans;

  guestIf = "${lan}.${toString vlans.guest.id}";
  kidsIf = "${lan}.${toString vlans.kids.id}";
  iotIf = "${lan}.${toString vlans.iot.id}";

  localNetworks = [
    "${cfg.lan.network}=Main_LAN"
    "${vlans.guest.network}=Guest_WiFi"
    "${vlans.kids.network}=Kids_WiFi"
    "${vlans.iot.network}=IoT_WiFi"
    "${cfg.wireguard.subnet}=Remote_Access_VPN"
  ];
in
{
  services.ntopng = {
    enable = true;

    # Use a complete config so the embedded UI binds only to loopback. The
    # NixOS httpPort option accepts a port number but not ntopng's :PORT syntax.
    configText = ''
      --interface=${cfg.bridgeName}
      --interface=${guestIf}
      --interface=${kidsIf}
      --interface=${iotIf}
      --http-port=:3002
      --https-port=0
      --redis=${config.services.ntopng.redis.address}
      --data-dir=/var/lib/ntopng
      --user=ntopng
      --local-networks=${builtins.concatStringsSep "," localNetworks}
      --dns-mode=0
      --instance-name=router
    '';
  };

  # Redis and Valkey both crash during startup on this Skylake router when built with
  # jemalloc. Keep following nixpkgs' current Valkey, but use libc's allocator; ntopng's
  # small local datastore does not benefit materially from jemalloc.
  services.redis.package = pkgs.valkey.overrideAttrs (old: {
    makeFlags = old.makeFlags ++ [ "MALLOC=libc" ];
    # The upstream integration suite takes many minutes and stalled in the Nix sandbox;
    # the router activation below performs the relevant executable, PING, and ntopng checks.
    doCheck = false;
    doInstallCheck = false;
  });

  # Packet capture needs the internal interfaces to exist first. Redis remains
  # ordered by the upstream NixOS ntopng module.
  systemd.services.ntopng = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}
