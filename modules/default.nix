# Central router module
#
# Imports all submodules for the router configuration.
# Interface configuration comes from hosts/router/interfaces.nix.
# Secrets are managed via sops-nix (secrets/secrets.yaml).

{ config, lib, pkgs, ... }:

{
  imports = [
    ./impermanence.nix
    ./auto-upgrade.nix
    ./scheduled-reboot.nix
    ./hardening.nix
    ./vlans.nix
    ./firewall.nix
    ./tailscale-client.nix
    ./tailscale-subnet-router.nix
    ./headscale-server.nix
    ./dnsmasq.nix
    ./dns-blocklist.nix
    ./adguardhome.nix
    ./network-monitoring.nix
    ./kids-mode.nix
    ./nginx.nix
    ./ssh.nix
    ./ddclient.nix
    ./sops.nix
  ];
}
