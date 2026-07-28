{
  description = "NixOS router with ephemeral root and automatic updates";

  inputs = {
    # Track the current NixOS stable release.
    #
    # nixos-25.11 went end-of-life on 2026-06-30 -- its last commit. The
    # auto-upgrade machinery kept reporting success against a dead branch,
    # so the router silently received no security updates for four weeks.
    # When 26.05 reaches EOL (roughly Dec 2026), bump this again; a stale
    # value here is invisible from the logs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Declarative disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Ephemeral root with persistence
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
        # Local packages (overlay so pkgs.kids-mode is visible inside modules)
        ({ ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              kids-mode = final.callPackage ./pkgs/kids-mode { };
            })
          ];
        })

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
