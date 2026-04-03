# Static configuration values for nixrouter
#
# These are hardcoded values that don't need secrecy.
# Interface names are in hosts/router/interfaces.nix (generated at install).
# Secrets are in secrets/secrets.yaml (encrypted with sops).

{
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
  # VLANs are tagged on the LAN interface (eth1) and delivered via trunk port
  # to an unmanaged switch and wireless AP.
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

  # System settings
  hostname = "router";
  timezone = "UTC";
  stateVersion = "24.11";
}
