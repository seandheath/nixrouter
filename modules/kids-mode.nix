# Kids VLAN mode toggle
#
# A tiny HTTP service on http://10.0.0.1:3001 (brLan only) that flips
# AdGuard Home between two modes:
#   - restricted: whitelist-only (AGH user_rules = ["/.*/", "@@||d^", ...])
#   - play:       AGH user_rules = []; family DNS upstreams (1.1.1.3 etc.)
#
# Persistent state at /var/lib/kids-mode/{mode,whitelist.txt}.
# Authenticates to AGH's HTTP API via a sops-encrypted user:password
# secret at /run/secrets/agh-admin (you set this up after running the
# AGH first-boot wizard - see secrets/secrets.yaml.template).
#
# Trust model: brLan is the only interface where 10.0.0.1:3001 is
# reachable (firewall.nix opens 3001/tcp on brLan only). The page has
# no auth of its own - if you're on the trusted LAN you can flip modes.

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  bridge = cfg.bridgeName;

  # Wikipedia + Khan Academy seed for first boot.
  # @@||d^ in AGH covers d and all subdomains, but Wikipedia spans
  # multiple eTLDs - include the main ones up front so the user
  # doesn't immediately have to add wikimedia/wmcloud just to read an
  # article.
  whitelistSeed = lib.concatStringsSep "\n" [
    "wikipedia.org"
    "wikimedia.org"
    "wmcloud.org"
    "khanacademy.org"
    "kastatic.org"
    "kasandbox.org"
  ] + "\n";
in
{
  # Static system user - lets us set sops owner/group and tmpfiles
  # ownership without touching DynamicUser semantics.
  users.users.kids-mode = {
    isSystemUser = true;
    group = "kids-mode";
    description = "kids-mode AGH toggle service";
  };
  users.groups.kids-mode = {};

  # AGH admin credentials, decrypted at boot to /run/secrets/agh-admin.
  # File contents must be a single line: "user:password" matching the
  # admin user/password set during the AGH first-boot wizard.
  sops.secrets."agh-admin" = {
    mode = "0400";
    owner = config.users.users.kids-mode.name;
    group = config.users.groups.kids-mode.name;
  };

  # Seed the whitelist on first boot only (the `f` rule is a no-op if
  # the file already exists, so subsequent edits via the web UI are
  # never overwritten).
  systemd.tmpfiles.settings."10-kids-mode" = {
    "/var/lib/kids-mode/whitelist.txt"."f" = {
      mode = "0640";
      user = "kids-mode";
      group = "kids-mode";
      argument = whitelistSeed;
    };
  };

  systemd.services.kids-mode-web = {
    description = "Kids VLAN AGH mode toggle (restricted/play)";
    wantedBy = [ "multi-user.target" ];

    # We bind 10.0.0.1 (brLan IP) and call AGH on 10.0.0.1:3000, so we
    # need brLan up and AGH running. AGH itself isn't strictly required
    # for the page to render (the reconcile loop tolerates a missing
    # AGH and reports the failure on the page), but ordering it first
    # means the common-case startup is silent.
    after = [
      "adguardhome.service"
      "sys-subsystem-net-devices-${bridge}.device"
    ];
    wants = [
      "sys-subsystem-net-devices-${bridge}.device"
    ];

    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.kids-mode}/bin/kids-mode"
        "-addr 10.0.0.1:80"
        "-state-dir /var/lib/kids-mode"
        "-agh-url http://10.0.0.1:3000"
        "-agh-credentials-file /run/secrets/agh-admin"
      ];
      User = "kids-mode";
      Group = "kids-mode";
      Restart = "on-failure";
      RestartSec = "5s";

      # State directory is bind-mounted from /nix/persist via
      # impermanence.nix; StateDirectory= still chowns it correctly.
      StateDirectory = "kids-mode";
      StateDirectoryMode = "0750";

      # Hardening - this is a small, internet-exposed-on-LAN HTTP server.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateUsers = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];

      ReadWritePaths = [ "/var/lib/kids-mode" ];

      # Network: only loopback + brLan (the AGH API and the bind addr
      # are both on the router itself; 10.0.0.0/24 is brLan).
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "127.0.0.0/8" "10.0.0.0/24" ];

      # Bind to privileged port 80 for http://kids.lan/. Only this
      # capability - everything else is dropped.
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    };
  };
}
