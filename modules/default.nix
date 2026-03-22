# Central router module
#
# This module defines the public interface for nixrouter. It declares all
# configuration options and imports all submodules.
#
# Usage in a consuming flake:
#   inputs.nixrouter.nixosModules.router
#
# Required options:
#   router.adminKeys - SSH public keys for the admin user
#   router.interfaces.wan - WAN interface name
#   router.interfaces.lan - LAN interface name

{ config, lib, pkgs, ... }:

let
  cfg = config.router;
in
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
  ];

  options.router = {
    adminKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "SSH public keys for the admin user";
      example = [ "ssh-ed25519 AAAAC3..." ];
    };

    interfaces = {
      wan = lib.mkOption {
        type = lib.types.str;
        description = "WAN interface name (external, connects to ISP)";
        example = "enp1s0";
      };

      lan = lib.mkOption {
        type = lib.types.str;
        description = "LAN interface name (internal, connects to local network)";
        example = "enp2s0";
      };
    };
  };

  # Assertions to catch missing required options at build time
  config = {
    assertions = [
      {
        assertion = cfg.adminKeys != [];
        message = "router.adminKeys must contain at least one SSH public key";
      }
    ];
  };
}
