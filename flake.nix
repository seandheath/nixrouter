{
  description = "NixOS router module with ephemeral root and automatic updates";

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
  };

  outputs = { self, nixpkgs, disko, impermanence, ... }@inputs: {
    # Export the router module for use in other flakes
    nixosModules.router = import ./modules;
    nixosModules.default = self.nixosModules.router;

    # Example configuration (requires setting router.* options)
    nixosConfigurations.router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        # Flake input modules
        disko.nixosModules.disko
        impermanence.nixosModules.impermanence

        # Router module (includes all feature modules)
        self.nixosModules.router

        # Host configuration
        ./hosts/router

        # Users
        ./users/admin.nix

        # Example: Set required options for build testing
        # In real deployment, these come from the consuming flake
        ({ lib, ... }: {
          # Placeholder key - override in consuming flake with real keys
          # Using mkDefault so consuming flake can easily override
          router.adminKeys = lib.mkDefault [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholder-override-in-consuming-flake"
          ];
          router.interfaces.wan = lib.mkDefault "eth0";
          router.interfaces.lan = lib.mkDefault "eth1";
        })
      ];
    };

  };
}
