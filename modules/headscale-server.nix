# Public Headscale control plane behind nginx.  Headscale itself listens only
# on loopback; nginx is the sole Internet-facing HTTP(S) service.
{ config, lib, pkgs, ... }:
let
  cfg = config.fleet.headscaleServer;
  policyFile = pkgs.writeText "headscale-policy.hujson" (builtins.toJSON cfg.policy);
  headscale = lib.getExe config.services.headscale.package;
in
{
  options.fleet.headscaleServer = {
    enable = lib.mkEnableOption "the Headscale control server";

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "headscale.luckyobserver.com";
      description = "Stable public hostname of the Headscale HTTPS endpoint.";
    };

    publicInterface = lib.mkOption {
      type = lib.types.str;
      description = "WAN interface on which ACME HTTP and Headscale HTTPS are exposed.";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      description = "Contact address for the public ACME certificate.";
    };

    tailnetDomain = lib.mkOption {
      type = lib.types.str;
      default = "tail.luckyobserver.com";
      description = "MagicDNS suffix; must differ from the control hostname.";
    };

    owner = lib.mkOption {
      type = lib.types.str;
      default = "home";
      description = "Headscale user created idempotently for personal devices.";
    };

    dnsRecords = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption { type = lib.types.str; };
          type = lib.mkOption { type = lib.types.enum [ "A" "AAAA" ]; };
          value = lib.mkOption { type = lib.types.str; };
        };
      });
      default = [ ];
      description = "Stable home-service records served by MagicDNS.";
    };

    policy = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      description = "Declarative Headscale/Tailscale HuJSON policy.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.hostname != cfg.tailnetDomain;
      message = "Headscale's public hostname and MagicDNS domain must differ.";
    }];

    services.headscale = {
      enable = true;
      # Remove when stable nixpkgs has 0.29.3: 0.28 crashes Android 1.102 clients.
      package = if lib.versionOlder pkgs.headscale.version "0.29.3" then
        pkgs.headscale.overrideAttrs (final: _: {
          version = "0.29.3";
          src = pkgs.fetchFromGitHub {
            owner = "juanfont";
            repo = "headscale";
            tag = "v${final.version}";
            hash = "sha256-ddJHSEqZd++JeG3UjUwzw7i45FlZYggUwhEG/tDkq0s=";
          };
          vendorHash = "sha256-fzKyXNMw/2yAEhaTZu0n1NXatPO2IP0HFA2ey1vZIYM=";
        })
      else pkgs.headscale;
      address = "127.0.0.1";
      port = 8080;
      settings = {
        server_url = "https://${cfg.hostname}";
        metrics_listen_addr = "127.0.0.1:9090";
        grpc_listen_addr = "127.0.0.1:50443";
        grpc_allow_insecure = false;
        trusted_proxies = [ "127.0.0.1/32" "::1/128" ];

        database = {
          type = "sqlite";
          sqlite = {
            path = "/var/lib/headscale/db.sqlite";
            write_ahead_log = true;
          };
        };

        derp = {
          server.enabled = false;
          urls = [ "https://controlplane.tailscale.com/derpmap/default" ];
          auto_update_enabled = true;
          update_frequency = "3h";
        };

        policy = {
          mode = "file";
          path = policyFile;
        };

        dns = {
          magic_dns = true;
          base_domain = cfg.tailnetDomain;
          # Add MagicDNS without replacing whatever resolver the laptop's
          # current Wi-Fi or Ethernet connection supplies.
          override_local_dns = false;
          nameservers.global = [ ];
          nameservers.split = { };
          search_domains = [ ];
          extra_records = cfg.dnsRecords;
        };
      };
    };

    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.acmeEmail;
    };

    services.nginx.virtualHosts.${cfg.hostname} = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };

    # Port 80 is used only for ACME HTTP-01 and redirects; Headscale traffic is
    # HTTPS on 443.  Scope both openings to the actual WAN interface.
    networking.firewall.interfaces.${cfg.publicInterface}.allowedTCPPorts = [ 80 443 ];

    # The policy references this owner.  Keep its database record declarative
    # and idempotent while leaving node enrollment itself explicit/auditable.
    systemd.services.headscale-bootstrap-owner = {
      description = "Ensure the Headscale owner exists";
      after = [ "headscale.service" ];
      requires = [ "headscale.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.jq ];
      serviceConfig.Type = "oneshot";
      script = ''
        users="$(${headscale} users list --output json)"
        if ! printf '%s' "$users" | jq -e --arg owner ${lib.escapeShellArg cfg.owner} \
          'map(select(.name == $owner)) | length == 1' >/dev/null; then
          ${headscale} users create ${lib.escapeShellArg cfg.owner}
        fi
      '';
    };
  };
}
