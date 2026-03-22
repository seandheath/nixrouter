# Admin user configuration
#
# This user has sudo access for system administration.
# SSH public key must be added before installation.
#
# Home directory is persisted via impermanence.

{ config, lib, pkgs, ... }:

let
  # SSH public keys for the admin user
  # IMPORTANT: Add your SSH public key(s) here before installation!
  sshKeys = [
    # Example: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host"
    # Add your key(s) below:
  ];

  # Set to true to allow build without SSH keys (for testing only!)
  # The install.sh script will prompt for a key if none are configured.
  allowNoKeys = true;
in
{
  # Allow login without password/key during development builds
  # The installer will add SSH keys before actual deployment
  users.allowNoPasswordLogin = lib.mkIf (sshKeys == [] && allowNoKeys) true;

  users.users.admin = {
    isNormalUser = true;
    description = "System Administrator";

    # Grant sudo access
    extraGroups = [ "wheel" ];

    # SSH public keys for passwordless login
    openssh.authorizedKeys.keys = sshKeys;

    # No password (SSH key only)
    # If you need a password for console access, use hashedPasswordFile with sops
    hashedPassword = null;

    # Default shell
    shell = pkgs.bash;
  };

  # Persist admin home directory
  environment.persistence."/nix/persist" = {
    users.admin = {
      directories = [
        ".ssh"           # SSH known hosts, etc.
        ".local/share"   # Application state
      ];
      files = [
        ".bash_history"
      ];
    };
  };

  # Allow admin to use sudo without password (for automation)
  # Remove or modify if you prefer password prompts
  security.sudo.extraRules = [
    {
      users = [ "admin" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Ensure wheel group can use sudo
  security.sudo.wheelNeedsPassword = false;
}
