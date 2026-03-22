# Admin user configuration
#
# This user has sudo access for system administration.
# SSH keys are configured via router.adminKeys option.
#
# Home directory is persisted via impermanence.

{ config, lib, pkgs, ... }:

{
  users.users.admin = {
    isNormalUser = true;
    description = "System Administrator";

    # Grant sudo access
    extraGroups = [ "wheel" ];

    # SSH public keys from router.adminKeys option
    openssh.authorizedKeys.keys = config.router.adminKeys;

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
