# Static configuration values for nixrouter
#
# These are hardcoded values that don't need secrecy.
# Interface names are in hosts/router/interfaces.nix (generated at install).
# Secrets are in secrets/secrets.yaml (encrypted with sops).

{
  # LAN network configuration
  lan = {
    address = "10.0.0.1";
    prefixLength = 24;
    network = "10.0.0.0/24";
    dhcpStart = "10.0.0.100";
    dhcpEnd = "10.0.0.254";
    leaseTime = "12h";
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
