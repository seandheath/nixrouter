# Dynamic DNS client (Cloudflare)
#
# Keeps an A record up to date with the router's current WAN IP so the
# WireGuard VPN endpoint (vpn.luckyobserver.com) is always reachable
# despite the dynamic public IP from the ISP.
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
    domains = [ "vpn.luckyobserver.com" ];

    # Cloudflare API token auth: literal username "token", password is
    # the API token itself, supplied via sops.
    username = "token";
    passwordFile = config.sops.secrets."ddclient/cloudflare-token".path;

    # Detect the public IP from the outside (the WAN interface may sit
    # behind a modem in bridge mode; web detection is more reliable).
    usev4 = "webv4, webv4=checkip.amazonaws.com";

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
