# Hestia daemon in a NixOS container (from the hestia-host flake).
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
  imports = [ inputs.hestia-host.nixosModules.default ];

  services.hestia = {
    enable = true;
    lanBridge = cfg.bridgeName;
    managedInterface = "${interfaces.lan}.40";
    relayUrl = "relay.groundedgadgets.com";
    relayGrant = "a3696465766963655f69649820187318bd18441827181a189a0818e018cc1880181b18ba18da18c818ba18b418521868184818d6184e186318dd1847182118bb184c18301218441881182565756e74696c1af4865700697369676e6174757265584036138a8c9ac23ec426ab63a4673fbe4df678e0c2fc38060ba4cee1cb6483f5219879c843778a976ad0a89167c6123536be2b1ca51062ec43eb6811b914dd6a0a";
  };

  # flake-update (as admin) and rebuilds (as root) fetch hestia-host and its
  # private inputs from the forge. The token stays in /run/secrets, never in the store.
  sops.secrets.hestia-forge-token.owner = "admin";
  programs.git.config.credential."https://git.luckyobserver.com".helper =
    "!f() { test \"$1\" = get && echo username=token && echo password=$(cat ${config.sops.secrets.hestia-forge-token.path}); }; f";
}
