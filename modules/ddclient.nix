# Dynamic DNS client (Cloudflare)
#
# Keeps the public Headscale A record synchronized with the router's
# changing WAN IPv4 address.
#
# Credentials live in sops (secrets/secrets.yaml ::
# ddclient.cloudflare-token). The Cloudflare token must be scoped to
# Zone:DNS:Edit on the luckyobserver.com zone.
#
# Reference: https://ddclient.net/protocols.html#cloudflare

{ config, lib, pkgs, ... }:

{
  services.ddclient = {
    enable = true;
    protocol = "cloudflare";
    zone = "luckyobserver.com";
    domains = [
      "headscale.luckyobserver.com"
    ];

    # Cloudflare API token auth: literal username "token", password is
    # the API token itself, supplied via sops.
    username = "token";
    passwordFile = config.sops.secrets."ddclient/cloudflare-token".path;

    # Detect the public IP from the outside (the WAN interface may sit
    # behind a modem in bridge mode; web detection is more reliable).
    usev4 = "webv4, webv4=checkip.amazonaws.com";
    # This deployment publishes A records only.  The module otherwise enables
    # IPv6 discovery by default, causing needless timeouts and failed AAAA
    # updates on an IPv4-only WAN/DDNS setup.
    usev6 = "";

    # Default ddclient interval is 5 minutes; that's fine.
    interval = "5min";
  };

  # ddclient runs as a DynamicUser. Its prestart script renders
  # /etc/ddclient.conf as root (substituting the token), so the secret
  # only needs to be readable by root.
  sops.secrets."ddclient/cloudflare-token" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };
}
