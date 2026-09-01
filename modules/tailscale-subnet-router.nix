# Advertise selected directly connected networks through Tailscale.  This role
# does not advertise 0/0 and therefore cannot become an exit node.
{ config, lib, ... }:
let
  cfg = config.fleet.tailscaleSubnetRouter;
  client = config.fleet.tailscaleClient;
  routesFlag = "--advertise-routes=${lib.concatStringsSep "," cfg.routes}";
in
{
  options.fleet.tailscaleSubnetRouter = {
    enable = lib.mkEnableOption "Tailscale subnet routing";

    routes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.0.0.0/24" ];
      description = "LAN prefixes to advertise; default routes are rejected.";
    };

    lanInterface = lib.mkOption {
      type = lib.types.str;
      description = "Interface through which the advertised LAN is reached.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = client.enable;
        message = "fleet.tailscaleSubnetRouter requires fleet.tailscaleClient.";
      }
      {
        assertion = cfg.routes != [ ];
        message = "fleet.tailscaleSubnetRouter.routes must not be empty.";
      }
      {
        assertion = !(lib.elem "0.0.0.0/0" cfg.routes || lib.elem "::/0" cfg.routes);
        message = "The subnet-router role refuses to configure an exit-node route.";
      }
    ];

    services.tailscale.useRoutingFeatures = "server";
    fleet.tailscaleClient.reconcileFlags = [
      routesFlag
      "--snat-subnet-routes=true"
    ];

    # The router firewall otherwise has a default-drop forwarding policy.
    # Tailscale's own netfilter rules still enforce the policy delivered by
    # Headscale before traffic reaches this forwarding path.
    networking.firewall.extraForwardRules = ''
      iifname "tailscale0" oifname "${cfg.lanInterface}" accept comment "Tailscale subnet router to home LAN"
      iifname "${cfg.lanInterface}" oifname "tailscale0" ct state established,related accept comment "Home LAN replies to Tailscale"
    '';
  };
}
