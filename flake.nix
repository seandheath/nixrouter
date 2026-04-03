{
  description = "NixOS router with ephemeral root and automatic updates";

  inputs = {
    # Using nixos-25.11-small for minimal footprint on router hardware
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11-small";

    # Declarative disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Ephemeral root with persistence
    impermanence.url = "github:nix-community/impermanence";

    # Secrets management
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

        # Router modules
        ./modules

        # Host configuration
        ./hosts/router

        # Users
        ./users/admin.nix
      ];
    };
  };
}
