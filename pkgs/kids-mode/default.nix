# kids-mode: small HTTP service that toggles AGH between restricted
# and play modes for the Kids VLAN. See modules/kids-mode.nix for how
# this is wired into the running system.
#
# No external dependencies - vendorHash = null means buildGoModule
# skips the vendor step entirely (only valid when go.sum is empty).

{ lib, buildGoModule }:

buildGoModule {
  pname = "kids-mode";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  vendorHash = null;
  subPackages = [ "." ];

  meta = with lib; {
    description = "Kids VLAN AGH mode toggle (restricted/play)";
    license = licenses.mit;
    mainProgram = "kids-mode";
    platforms = platforms.linux;
  };
}
