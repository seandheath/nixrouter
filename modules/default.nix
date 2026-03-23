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
    ./firewall.nix
    ./dnsmasq.nix
    ./ssh.nix
    ./ddclient.nix
    ./sops.nix
  ];
}
