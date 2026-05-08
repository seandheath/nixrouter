# WireGuard remote-access VPN
#
# Architecture:
#
#   Phone (10.40.0.2)  --- UDP/51820 --->  Router WAN
#                                              |
#                                          wg0 (10.40.0.1/24)
#                                              |
#                                          [forward, no NAT]
#                                              |
#                                          brLan (10.0.0.0/24)
#
# - Phone-side AllowedIPs is split-tunnel (10.0.0.0/24, 10.40.0.0/24).
#   Phone's general internet traffic is NOT routed through home.
# - brLan devices have the router as default gateway, so reply packets to
#   10.40.0.0/24 route back through wg0 naturally. No NAT needed; brLan
#   hosts see the real client IP (10.40.0.2). If full-tunnel is wanted
#   later, add wg0 to networking.nat.internalInterfaces and 10.40.0.0/24
#   to networking.nat.internalIPs in modules/firewall.nix.
# - wg0 -> Guest/Kids/IoT VLAN forwarding is explicitly DROPped, mirroring
#   the existing inter-VLAN isolation policy (modules/firewall.nix).
#
# Configuration knobs live in ../config.nix under the `wireguard` key.
#
# Reference:
#   https://www.wireguard.com/quickstart/
#   https://nixos.wiki/wiki/WireGuard

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  wan = interfaces.wan;
  lan = interfaces.lan;
  vlans = cfg.vlans;
  wg = cfg.wireguard;

  # VLAN interface names (on the trunk port) - used for FORWARD drops
  guestIf = "${lan}.${toString vlans.guest.id}";
  kidsIf = "${lan}.${toString vlans.kids.id}";
  iotIf = "${lan}.${toString vlans.iot.id}";

  wgIf = "wg0";
in
lib.mkIf wg.enable {
  # ---------------------------------------------------------------------
  # WireGuard interface
  # ---------------------------------------------------------------------
  # Uses NixOS's native networking.wireguard (not wg-quick, not a
  # systemd-networkd netdev). Keeps the private key file readable only
  # by root (sops decrypts to /run/secrets, tmpfs).
  networking.wireguard.interfaces.${wgIf} = {
    ips = [ "${wg.serverIp}/${toString wg.prefixLength}" ];
    listenPort = wg.port;
    privateKeyFile = config.sops.secrets."wireguard/server-private-key".path;

    peers = map (p: {
      publicKey = p.publicKey;
      allowedIPs = [ p.allowedIp ];
    }) wg.peers;
  };

  # Decrypt the server private key into /run/secrets at boot.
  sops.secrets."wireguard/server-private-key" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # ---------------------------------------------------------------------
  # Firewall
  # ---------------------------------------------------------------------
  # Module-system list merging: these settings are appended to the
  # interface blocks already defined in modules/firewall.nix.
  networking.firewall.interfaces = {
    # Open the WireGuard listen port on the WAN interface
    ${wan}.allowedUDPPorts = [ wg.port ];

    # Allow VPN clients to reach router-local services
    ${wgIf} = {
      allowedTCPPorts = [
        22  # SSH
        53  # DNS (dnsmasq)
        80  # nginx (kids.lan, adguard.lan)
      ];
      allowedUDPPorts = [
        53  # DNS
      ];
    };
  };

  # Block forwarding from the VPN into Guest/Kids/IoT VLANs.
  # brLan is reachable by default (FORWARD policy is permissive); these
  # drops keep the existing per-VLAN isolation intact for VPN clients too.
  networking.firewall.extraCommands = ''
    # WireGuard isolation: VPN reaches brLan only, never other VLANs
    iptables -I FORWARD -i ${wgIf} -o ${guestIf} -j DROP
    iptables -I FORWARD -i ${wgIf} -o ${kidsIf}  -j DROP
    iptables -I FORWARD -i ${wgIf} -o ${iotIf}   -j DROP
  '';

  networking.firewall.extraStopCommands = ''
    iptables -D FORWARD -i ${wgIf} -o ${guestIf} -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${wgIf} -o ${kidsIf}  -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${wgIf} -o ${iotIf}   -j DROP 2>/dev/null || true
  '';

  # ---------------------------------------------------------------------
  # DNS over the tunnel
  # ---------------------------------------------------------------------
  # Have dnsmasq listen on wg0 too so the phone can use 10.0.0.1 as DNS
  # and resolve kids.lan / adguard.lan. dnsmasq is bind-interfaces=true,
  # so it must wait for wg0 to exist before starting.
  services.dnsmasq.settings.interface = [ wgIf ];

  systemd.services.dnsmasq = {
    after = [ "sys-subsystem-net-devices-${wgIf}.device" "wireguard-${wgIf}.service" ];
    wants = [ "sys-subsystem-net-devices-${wgIf}.device" "wireguard-${wgIf}.service" ];
  };
}
