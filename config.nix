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
    ];
  };

  # System settings
  hostname = "router";
  timezone = "America/New_York";
  stateVersion = "25.11";
}
