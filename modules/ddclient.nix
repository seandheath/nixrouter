# Dynamic DNS client configuration (stub)
#
# This module provides a template for configuring ddclient with various
# DNS providers. Actual credentials should be stored in secrets/secrets.yaml
# and referenced via sops-nix.
#
# Supported providers: Cloudflare, Namecheap, DuckDNS, Google Domains, etc.
#
# To enable:
#   1. Uncomment the provider configuration below
#   2. Add credentials to secrets/secrets.yaml
#   3. Uncomment the sops secret references
#
# Reference: https://ddclient.net/

{ config, lib, pkgs, ... }:

{
  # ddclient is disabled by default - uncomment to enable
  services.ddclient = {
    enable = false;  # Set to true after configuring

    # Use IPv4 by default
    protocol = "cloudflare";

    # Domain(s) to update
    domains = [ "example.com" ];

    # How to detect external IP
    use = "web, web=checkip.amazonaws.com";

    # Update interval (seconds)
    interval = "5min";

    # Configuration is written to /etc/ddclient.conf
    # Credentials should come from sops secrets
    # extraConfig = ''
    #   ssl=yes
    # '';
  };

  #
  # --- Cloudflare Example ---
  #
  # services.ddclient = {
  #   enable = true;
  #   protocol = "cloudflare";
  #   zone = "example.com";
  #   domains = [ "home.example.com" ];
  #   username = "token";  # Use "token" for API token auth
  #   passwordFile = config.sops.secrets."ddclient/cloudflare-token".path;
  #   use = "web, web=checkip.amazonaws.com";
  # };
  #
  # sops.secrets."ddclient/cloudflare-token" = {
  #   owner = "ddclient";
  #   group = "ddclient";
  # };

  #
  # --- Namecheap Example ---
  #
  # services.ddclient = {
  #   enable = true;
  #   protocol = "namecheap";
  #   server = "dynamicdns.park-your-domain.com";
  #   domains = [ "@" "www" ];  # Subdomains to update
  #   username = "example.com";  # Your domain
  #   passwordFile = config.sops.secrets."ddclient/namecheap-password".path;
  #   use = "web, web=checkip.amazonaws.com";
  # };

  #
  # --- DuckDNS Example ---
  #
  # services.ddclient = {
  #   enable = true;
  #   protocol = "duckdns";
  #   domains = [ "mysubdomain" ];
  #   username = "nouser";  # DuckDNS doesn't use username
  #   passwordFile = config.sops.secrets."ddclient/duckdns-token".path;
  #   use = "web, web=checkip.amazonaws.com";
  # };

  # State directory for ddclient (persisted via impermanence)
  # Stores the last known IP to avoid unnecessary updates
}
