# sops-nix secrets management configuration
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

    # Default secrets file
    defaultSopsFile = ../secrets/secrets.yaml;

    # Validate secrets at build time
    validateSopsFiles = false;  # Set to true once secrets.yaml is properly configured

    # Secrets are decrypted to /run/secrets by default
    # This is a tmpfs, so secrets are never written to disk

    # Example secret definitions:
    # secrets."ddclient/cloudflare-token" = {
    #   owner = "ddclient";
    #   group = "ddclient";
    #   mode = "0400";
    # };
  };

  # Ensure sops-nix package is available
  environment.systemPackages = with pkgs; [
    sops
    age
  ];
}
