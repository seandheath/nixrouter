# Admin user configuration
#
# This user has sudo access for system administration.
# SSH keys are managed via sops-nix (secrets/secrets.yaml).
#
# Home directory is persisted via impermanence.

{ config, lib, pkgs, ... }:

{
  # Define sops secret for SSH authorized keys
  # No neededForUsers — SSH keys don't need early decryption,
  # sshd starts after sops activation. Path: /run/secrets/admin-ssh-keys
  sops.secrets.admin-ssh-keys = {
    mode = "0444";
  };

  users.users.admin = {
    isNormalUser = true;
    description = "System Administrator";

    # Grant sudo access
    extraGroups = [ "wheel" ];

    # Password for console access (hash stored in sops)
    hashedPasswordFile = config.sops.secrets.admin-password.path;

    # Default shell
    shell = pkgs.bash;
  };

  # Configure SSH to read admin's authorized keys from sops secret
  # Uses config.sops.secrets path which resolves to /run/secrets/admin-ssh-keys
  services.openssh.extraConfig = ''
    Match User admin
      AuthorizedKeysFile ${config.sops.secrets.admin-ssh-keys.path}
  '';

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

  # Shell aliases for system management
  environment.interactiveShellInit = ''
    alias nrs='cd /nix/persist/etc/nixos && git pull && sudo nixos-rebuild switch --flake .#router'
    alias nrb='cd /nix/persist/etc/nixos && git pull && sudo nixos-rebuild boot --flake .#router'
  '';

  # Ensure wheel group can use sudo
  security.sudo.wheelNeedsPassword = false;

  # SSH keys are provided by sops at runtime, so NixOS can't verify them at build time
  # This silences the "no password or SSH key" assertion
  users.allowNoPasswordLogin = true;
}
