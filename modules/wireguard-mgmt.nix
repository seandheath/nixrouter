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
{ config, lib, ... }:

let
  cfg = import ../config.nix;
  mgmt = cfg.wireguardMgmt;

  wgIf = "wgmgt";
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

  # nginx binds ${mgmt.address} explicitly (modules/nginx.nix) and would fail at boot if
  # the interface is not up yet. Allowing non-local binds is the standard fix and is
  # robust across wgmgt restarts, which strict ordering is not: a socket bound to an
  # address that then disappears does not recover on its own.
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # THE resolver for tunnel clients. There is exactly one authority for these names and
  # it is this box -- hydrogen briefly ran a second dnsmasq for the same zone, which is
  # how split-horizon DNS starts giving two different answers to the same question.
  #
  # bind-interfaces means a missing interface at start time is a fatal bind failure, so
  # the ordering below is required rather than defensive.
  services.dnsmasq.settings.interface = [ wgIf ];

  systemd.services.dnsmasq = {
    after = [ "wireguard-${wgIf}.service" ];
    wants = [ "wireguard-${wgIf}.service" ];
  };
}
