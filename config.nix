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
  # client using this router as its resolver. The
  # names resolve to hydrogen, which runs nginx and terminates TLS with a
  # *.luckyobserver.com Cloudflare DNS-01 wildcard cert. This keeps
  # self-hosted traffic on the LAN instead of egressing.
  #
  # Per-subdomain only — do NOT wildcard luckyobserver.com here: it's a
  # real public zone and a wildcard would clobber public services.
  localServices = {
    host = "10.0.0.10";
    domain = "luckyobserver.com";
    # KEEP IN STEP with `serviceNames` in the nixos repo, modules/family/devices.nix.
    # Two flakes cannot share a list without one importing the other, so this is a manual
    # pairing: adding a service means touching hydrogen's nginx, devices.nix, and here.
    names = [ "nc" "immich" "calibre" "paper" "mc" ];  # <name>.<domain>
  };

  # Names that need an address other than localServices.host. Marketplace resolves to
  # hydrogen's direct tail address so Headscale can enforce its administrative ACL.
  # Keep these in both resolver paths (dnsmasq and the kids VLAN's AdGuard Home).
  localEndpoints = {
    # Public DNS points at the dynamic WAN address; this split-horizon answer
    # avoids hairpinning during enrollment from home.
    "headscale.luckyobserver.com" = "10.0.0.1";
    "marketplace.luckyobserver.com" = "100.64.0.3";
  };

  portForwards = [ ];
  kidsPinholes = [ ];

  tailnet = {
    routerAddress = "100.64.0.1";
  };

  # System settings
  hostname = "router";
  timezone = "America/New_York";
  stateVersion = "25.11";
}
