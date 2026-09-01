# Static configuration values for nixrouter
#
# These are hardcoded values that don't need secrecy.
# Interface names are in hosts/router/interfaces.nix (generated at install).
# Secrets are in secrets/secrets.yaml (encrypted with sops).

{
  # Bridge name for the main LAN (bridges trunk + wired LAN NICs)
  bridgeName = "brLan";

  # LAN network configuration (native VLAN / untagged)
  lan = {
    address = "10.0.0.1";
    prefixLength = 24;
    network = "10.0.0.0/24";
    dhcpStart = "10.0.0.100";
    dhcpEnd = "10.0.0.254";
    leaseTime = "12h";
  };

  # VLAN network configuration
  # VLANs are tagged on the trunk interface and delivered via 802.1Q to the AP.
  # Untagged traffic from the trunk and wired LAN NIC are bridged into brLan.
  vlans = {
    # Guest network - internet access only, isolated from all other networks
    guest = {
      id = 10;
      address = "10.10.0.1";
      prefixLength = 24;
      network = "10.10.0.0/24";
      dhcpStart = "10.10.0.100";
      dhcpEnd = "10.10.0.254";
    };

    # Kids network - internet with DNS-based content filtering
    kids = {
      id = 20;
      address = "10.20.0.1";
      prefixLength = 24;
      network = "10.20.0.0/24";
      dhcpStart = "10.20.0.100";
      dhcpEnd = "10.20.0.254";
    };

    # IoT network - restricted internet with full connection logging
    iot = {
      id = 30;
      address = "10.30.0.1";
      prefixLength = 24;
      network = "10.30.0.0/24";
      dhcpStart = "10.30.0.100";
      dhcpEnd = "10.30.0.254";
    };
  };

  # Upstream DNS servers (privacy-focused)
  upstreamDns = [
    "1.1.1.1"      # Cloudflare
    "1.0.0.1"      # Cloudflare secondary
    "9.9.9.9"      # Quad9
    "8.8.8.8"      # Google (fallback)
  ];

  # Split-horizon DNS — internal service names answered locally for any
  # client using this router as its resolver (LAN + WireGuard VPN). The
  # names resolve to hydrogen, which runs nginx and terminates TLS with a
  # *.luckyobserver.com Cloudflare DNS-01 wildcard cert. This keeps
  # self-hosted traffic on the LAN/tunnel instead of egressing.
  #
  # Per-subdomain only — do NOT wildcard luckyobserver.com here: it's a
  # real public zone and a wildcard would clobber vpn.luckyobserver.com
  # (the WG endpoint A record ddclient points at the public WAN IP).
  localServices = {
    # 10.41.0.1, not 10.0.0.10, since 2026-08-06: hydrogen stopped serving these on its
    # LAN address and now answers only on its WireGuard interfaces. A client that holds
    # no key cannot reach them at either address, so this answer is not what grants
    # access — it is simply the one that is true for clients that do.
    host = "10.41.0.2";                # hydrogen's wgfam address
    domain = "luckyobserver.com";
    # KEEP IN STEP with `serviceNames` in the nixos repo, modules/family/peers.nix --
    # that list feeds both the laptops' networking.hosts and hydrogen's tunnel resolver.
    # Two flakes cannot share a list without one importing the other, so this is a manual
    # pairing: adding a service means touching hydrogen's nginx, peers.nix, and here.
    names = [ "nc" "immich" "calibre" "paper" "mc" ];  # <name>.<domain>
  };

  # Names that need an address other than localServices.host. Device endpoint names resolve
  # directly to the device that owns the port; the marketplace UI resolves to hydrogen's
  # administrative tunnel because nginx deliberately rejects it on wgfam.
  # Keep these in both resolver paths (dnsmasq and the kids VLAN's AdGuard Home).
  localEndpoints = {
    "hydrogen.luckyobserver.com" = "10.0.0.10";
    "router.luckyobserver.com" = "10.0.0.1";
    # Public DNS points at the dynamic WAN address; this split-horizon answer
    # avoids hairpinning when an already-enrolled client is at home.
    "headscale.luckyobserver.com" = "10.0.0.1";
    "marketplace.luckyobserver.com" = "10.42.0.2";
  };

  # Port forwards from WAN to internal hosts (modules/firewall.nix).
  #
  # These are hydrogen's own WireGuard hubs. As of 2026-08-06 hydrogen scopes every
  # service — Immich, Nextcloud, Paperless, Minecraft, SSH, RustDesk, Syncthing — to a
  # WireGuard interface and opens nothing on its LAN address except SSH. Reaching any of
  # it, from anywhere including this LAN, means holding a key:
  #
  # Addressing convention on every tunnel: .1 router, .2 hydrogen, .3 sulfur.
  #
  #   51821  wgfam  10.41.0.0/24  the kids' laptops (and phones, when enrolled):
  #                               https + Minecraft only, peers isolated from each
  #                               other and from 10.0.0.0/24 by hydrogen's own
  #                               forward policy
  #   51822  wgadm  10.42.0.0/24  sulfur only: full administrative access
  #
  # This router's own hub on 51820 is unaffected and stays as the way onto brLan when
  # hydrogen is down. It deliberately does NOT reach hydrogen's services.
  #
  # networking.nat generates WAN forwarding and reflection for internal clients using the
  # same vpn.luckyobserver.com endpoint.
  portForwards = [
    { port = 51821; proto = "udp"; destination = "10.0.0.10"; comment = "hydrogen wgfam (family devices)"; }
    { port = 51822; proto = "udp"; destination = "10.0.0.10"; comment = "hydrogen wgadm (sulfur)"; }
  ];

  # Exceptions to the Kids VLAN's default-deny forwarding policy. AdGuard resolves the
  # family WireGuard endpoint directly to hydrogen's LAN address, so this packet is not
  # DNATed and must be admitted explicitly. WireGuard authenticates it before exposing any
  # service; no other Kids-to-LAN traffic is opened.
  kidsPinholes = [
    { host = "10.0.0.10"; port = 51821; proto = "udp"; comment = "hydrogen wgfam tunnel"; }
  ];

  # Management tunnel (modules/wireguard-mgmt.nix) -- reaching THIS router from outside.
  #
  # Separate from wg0 above, which is general remote access onto brLan. This one reaches
  # the router and nothing else, and exists so that administering the router never
  # depends on hydrogen: sulfur peers with both boxes directly rather than routing
  # through one to get to the other.
  #
  # Peer addresses are the ones those devices already use on hydrogen's tunnels, so each
  # device keeps ONE WireGuard profile with ONE address and simply lists two peers.
  # WireGuard has no notion of subnet membership -- only per-peer allowedIPs -- so a
  # 10.41.x device peering here is perfectly ordinary.
  wireguardMgmt = {
    enable = true;
    port = 51823;                      # UDP, opened on WAN
    address = "10.42.0.1";             # this router, inside the tunnel

    peers = [
      { name = "sulfur"; publicKey = "B3JEHLQkYPzrbiJAlDcd7fi50j2egYo9enu257jvBSU="; allowedIp = "10.42.0.3/32"; }

      # The parents' phones, for kids.lan and adguard.lan when away from home. Note the
      # addresses come from two different subnets -- that is fine and deliberate: each
      # phone keeps ONE profile with the address hydrogen already knows it by, and
      # WireGuard cares only about per-peer allowedIPs, never subnet membership.
      #
      # Add each only once the device has generated its keypair. A malformed key fails
      # `wg setconf` and takes the whole interface down, sulfur's SSH path included.
      { name = "sheath-phone"; publicKey = "T1JupspOSEWuBKZrPuwSWy7Hdo9vu84grjU3f7jEQmQ="; allowedIp = "10.42.0.4/32"; }
      { name = "spouse-phone"; publicKey = "PrXXMEAU1mVsZLz/0CLZ14mXYJqwEppaV5OUEr0c504="; allowedIp = "10.41.0.21/32"; }
    ];
  };

  # WireGuard remote-access VPN
  # Brings up a wg0 interface on the router so off-network devices can
  # reach brLan over an encrypted UDP tunnel. Other VLANs stay isolated.
  #
  # Bootstrap (see docs/log.md):
  #   1. Generate router keypair, store private key in sops as
  #      wireguard/server-private-key.
  #   2. Generate per-peer keypair on each client; add the client's PUBLIC
  #      key here in `peers`. The client's private key never leaves the
  #      client device.
  #   3. Flip `enable = true` and rebuild.
  wireguard = {
    enable = true;                     # sops + peers populated
    port = 51820;                      # UDP, opened on WAN
    serverIp = "10.40.0.1";            # router's address inside the tunnel
    subnet = "10.40.0.0/24";           # tunnel subnet (LAN=0, Guest=10, Kids=20, IoT=30, VPN=40)
    prefixLength = 24;
    ddnsHostname = "vpn.luckyobserver.com";  # phone connects to this:51820

    # One entry per remote device. allowedIp must be a /32 inside `subnet`.
    # Example:
    #   { name = "phone"; publicKey = "abc...="; allowedIp = "10.40.0.2/32"; }
    peers = [
      { name = "SeanPhone"; publicKey = "e14NEY0q1hfrsYwN5i0xUr4jzELmgBF2WMmDI00dKzo="; allowedIp = "10.40.0.2/32";}
      { name = "sulphur";   publicKey = "4ZAwOX6/WKDCm0YBuaNXKhSVej+3pwGEOgFU5Ca2pBM="; allowedIp = "10.40.0.3/32";}
    ];
  };

  # System settings
  hostname = "router";
  timezone = "America/New_York";
  stateVersion = "25.11";
}
