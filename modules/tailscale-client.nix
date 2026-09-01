# Reusable Tailscale client role.  tailscaled owns the tunnel and its durable
# identity; NetworkManager and networkd only own the underlying uplinks.
{ config, lib, pkgs, ... }:
let
  cfg = config.fleet.tailscaleClient;
  tailscale = lib.getExe config.services.tailscale.package;
  desiredSetFlags = [
    "--accept-dns=${lib.boolToString cfg.acceptDns}"
    "--accept-routes=${lib.boolToString cfg.acceptRoutes}"
    # An empty exit node explicitly preserves the local Internet default route.
    "--exit-node="
  ] ++ cfg.reconcileFlags;
  # A tagged Headscale pre-auth key assigns the node's tags. Headscale rejects
  # enrollment when that same request also advertises tags from the client.
  desiredUpFlags = desiredSetFlags;
in
{
  options.fleet.tailscaleClient = {
    enable = lib.mkEnableOption "the Headscale-managed Tailscale client";

    loginServer = lib.mkOption {
      type = lib.types.str;
      default = "https://headscale.luckyobserver.com";
      description = "Public Headscale URL used for initial enrollment.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional file containing a one-time Headscale pre-authentication key.
        Leave null for interactive enrollment.  The file must be supplied by
        sops-nix or another out-of-store secret mechanism.
      '';
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tag:subnet-router" ];
      description = ''
        Expected Headscale policy tags for this node. These document which
        tagged pre-auth key to use; the client does not request them itself.
      '';
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Accept approved subnet routes, never an exit route.";
    };

    acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Accept the Headscale-provided MagicDNS configuration.";
    };

    reconcileFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Additional tailscale up/set flags supplied by another role.";
    };

    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "TCP ports reachable on this machine through tailscale0.";
    };

    allowedUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "UDP ports reachable on this machine through tailscale0.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.hasPrefix "https://" cfg.loginServer;
      message = "fleet.tailscaleClient.loginServer must use public HTTPS.";
    }];

    services.tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = cfg.authKeyFile;
      useRoutingFeatures = lib.mkDefault (if cfg.acceptRoutes then "client" else "none");
      extraUpFlags = [ "--login-server=${cfg.loginServer}" ] ++ desiredUpFlags;
    };

    # nginx binds the stable tail address before tailscaled may have restored it.
    boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

    networking.firewall.interfaces.tailscale0 = {
      allowedTCPPorts = cfg.allowedTCPPorts;
      allowedUDPPorts = cfg.allowedUDPPorts;
    };

    # The upstream autoconnect unit uses the key only in NeedsLogin state.  This
    # companion unit reapplies non-secret preferences after upgrades/rebuilds and
    # deliberately does nothing before enrollment; tailscaled itself handles
    # roaming, suspend/resume, endpoint changes, and reconnects.
    systemd.services.tailscale-configure = {
      description = "Reconcile declarative Tailscale preferences";
      after = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.jq ];
      serviceConfig.Type = "oneshot";
      script = ''
        state="$(${tailscale} status --json --peers=false 2>/dev/null \
          | jq -r '.BackendState // empty' || true)"

        if [ "$state" = Running ]; then
          exec ${tailscale} set ${lib.escapeShellArgs desiredSetFlags}
        fi

        echo "tailscale is not enrolled (state: ''${state:-unknown}); leaving it running"
      '';
    };
  };
}
