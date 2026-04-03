# sops-nix secrets management configuration (optional)
#
# This module is NOT imported by default. To use it:
#   1. Add sops-nix input to your flake
#   2. Import sops-nix.nixosModules.sops
#   3. Import this module
#   4. Set sops.defaultSopsFile to your secrets file
#
# Uses age encryption for secrets. The age private key is stored at
# /nix/persist/var/lib/sops-nix/key.txt and persists across reboots.
#
# To create the age key:
#   age-keygen -o /nix/persist/var/lib/sops-nix/key.txt
#
# To encrypt secrets:
#   sops secrets/secrets.yaml
#
# Reference: https://github.com/Mic92/sops-nix

{ config, lib, pkgs, ... }:

{
  sops = {
    # Age key file location (persisted via impermanence)
    age.keyFile = "/nix/persist/var/lib/sops-nix/key.txt";

    # Secrets file (encrypted with age)
    defaultSopsFile = ../secrets/secrets.yaml;

    # Validate secrets at build time
    validateSopsFiles = false;

    # Secrets are decrypted to /run/secrets by default
    # This is a tmpfs, so secrets are never written to disk

    secrets.admin-password = {
      # Decrypt early so password hash is available during user activation
      neededForUsers = true;
    };
  };

  # Ensure sops-nix package is available
  environment.systemPackages = with pkgs; [
    sops
    age
  ];
}
