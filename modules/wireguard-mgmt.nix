# Management tunnel — reaching THIS ROUTER from outside, without going through anything
# else.
#
# Architecture:
#
#   sulfur / phones  --- UDP/51823 --->  Router WAN
#                                            |
#                                        wgmgt (10.42.0.3)
#                                            |
#                                   [the router itself, and nothing beyond]
#
# WHY THIS EXISTS, and why it is not a peer on hydrogen's wgadm. hydrogen hosts the
# other two hubs, so routing this through it would have made administering the router
# depend on hydrogen being up and forwarding correctly. The router is the thing every
# other thing depends on; its management path must not depend on a service host. A peer
# is not a spoke — WireGuard has no hubs, only pairs — so sulfur simply peers with both
# and neither outage implies the other.
#
# WHAT IT CARRIES:
#   22  SSH, for sulfur
#   80  nginx: kids.lan (the kids-mode toggle) and adguard.lan, for the parents' phones
#
# Peers address the router at its brLan address, 10.0.0.1 — NOT at 10.42.0.3. That is
# deliberate: kids.lan already resolves to 10.0.0.1 everywhere, so a phone with
# `AllowedIPs = 10.0.0.1/32` reaches the toggle over the tunnel using the same URL it
# uses on home wifi, with no second name and no split-horizon entry. Packets arrive on
# wgmgt destined for a local address, so the INPUT rules below are what admits them.
#
# ON SSH REACH. Both parents' phones can open a TCP connection to port 22 here. sshd is
# key-only (PasswordAuthentication = false, PermitRootLogin = no, modules/ssh.nix), so
# reach is not access — but if you want the phones unable to so much as knock, the fix
# is a source-matched rule in the INPUT path rather than this interface list.
#
# Nothing is forwarded. This tunnel reaches the router and stops.
{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
  wan = interfaces.wan;
  mgmt = cfg.wireguardMgmt;

  wgIf = "wgmgt";
  chain = "mgmt-forward";
in
lib.mkIf mgmt.enable {
  networking.wireguard.interfaces.${wgIf} = {
    ips = [ "${mgmt.address}/32" ];
    listenPort = mgmt.port;
    privateKeyFile = config.sops.secrets."wireguard/mgmt-private-key".path;

    # /32 per peer. On this side allowedIPs doubles as an anti-spoofing rule: a peer may
    # only source packets from the address listed against its own key.
    peers = map (p: {
      publicKey = p.publicKey;
      allowedIPs = [ p.allowedIp ];
    }) mgmt.peers;
  };

  sops.secrets."wireguard/mgmt-private-key" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  networking.firewall.interfaces = {
    # Listen port on the WAN. Merged with modules/wireguard.nix's entry for 51820 by
    # the module system's list merging.
    ${wan}.allowedUDPPorts = [ mgmt.port ];

    ${wgIf}.allowedTCPPorts = [
      22   # SSH (sulfur) -- see ON SSH REACH above
      80   # nginx: kids.lan, adguard.lan
    ];
  };

  # NOTHING FORWARDS OFF THIS TUNNEL.
  #
  # Peers' allowedIPs already stop them addressing anything but 10.0.0.1, but that is
  # configuration on someone else's phone. This is the half enforced here, and it
  # matters more than usual: this host is the LAN's gateway, so a client that set
  # AllowedIPs = 0.0.0.0/0 would otherwise be routed straight onto brLan and out.
  #
  # Built as its own chain and refilled wholesale rather than appended rule-by-rule --
  # FORWARD's policy is ACCEPT, so a rule that fails to apply fails OPEN, and a single
  # missing DROP here is a full LAN bypass.
  networking.firewall.extraCommands = ''
    iptables -N ${chain} 2>/dev/null || true
    iptables -F ${chain}
    iptables -A ${chain} -i ${wgIf} -j DROP
    iptables -C FORWARD -j ${chain} 2>/dev/null || iptables -I FORWARD 1 -j ${chain}
  '';

  networking.firewall.extraStopCommands = ''
    iptables -D FORWARD -j ${chain} 2>/dev/null || true
    iptables -F ${chain} 2>/dev/null || true
    iptables -X ${chain} 2>/dev/null || true
  '';

  # dnsmasq is bind-interfaces=true, so it must not try to bind wgmgt before it exists.
  # It is deliberately NOT told to listen here: phones resolve through hydrogen's tunnel
  # resolver, which forwards names it does not own back to this router anyway.
  systemd.services.dnsmasq = {
    after = [ "wireguard-${wgIf}.service" ];
    wants = [ "wireguard-${wgIf}.service" ];
  };
}
