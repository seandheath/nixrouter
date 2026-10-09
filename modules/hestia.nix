# Hestia daemon in a NixOS container (from the hestia-firmware flake).
#
# The container's WAN joins brLan and takes a DHCP lease from dnsmasq; the
# kids network is VLAN 40 from the AP, reached through a macvlan. The host
# has no address on VLAN 40 (see vlans.nix).

{ config, inputs, ... }:

let
  cfg = import ../config.nix;
  interfaces = import ../hosts/router/interfaces.nix;
in
{
  imports = [ inputs.hestia-firmware.nixosModules.default ];

  services.hestia = {
    enable = true;
    lanBridge = cfg.bridgeName;
    kidsInterface = "${interfaces.lan}.40";
  };

  # Rebuilds as root fetch hestia-firmware and its private inputs from the
  # forge. The token stays in /run/secrets (root-only), never in the store.
  sops.secrets.hestia-forge-token = { };
  programs.git.config.credential."https://git.luckyobserver.com".helper =
    "!f() { test \"$1\" = get && echo username=token && echo password=$(cat ${config.sops.secrets.hestia-forge-token.path}); }; f";
}
