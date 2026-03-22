{
  description = "NixOS router configuration with ephemeral root and automatic updates";

  inputs = {
    # Using nixos-24.11-small for minimal footprint on router hardware
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11-small";

    # Declarative disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Ephemeral root with persistence
    impermanence.url = "github:nix-community/impermanence";

    # Secrets management with age/sops
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, impermanence, sops-nix, ... }@inputs: {
    nixosConfigurations.router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        # Flake input modules
        disko.nixosModules.disko
        impermanence.nixosModules.impermanence
        sops-nix.nixosModules.sops

        # Host configuration
        ./hosts/router

        # Feature modules
        ./modules/impermanence.nix
        ./modules/auto-upgrade.nix
        ./modules/scheduled-reboot.nix
        ./modules/hardening.nix
        ./modules/firewall.nix
        ./modules/dnsmasq.nix
        ./modules/ssh.nix
        ./modules/sops.nix
        ./modules/ddclient.nix

        # Users
        ./users/admin.nix
      ];
    };

  };
}
