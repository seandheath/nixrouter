# Kids VLAN mode toggle
#
# A tiny HTTP service on http://10.0.0.1:3001 (brLan only) that flips
# AdGuard Home between two modes:
#   - restricted: whitelist-only (AGH user_rules = ["/.*/", "@@||d^", ...])
#   - play:       AGH user_rules = []; family DNS upstreams (1.1.1.3 etc.)
#
# Persistent state at /var/lib/kids-mode/{mode,whitelist.txt}.
#
# AGH API auth: this module currently runs in no-auth mode (matches
# AGH's no-users-configured state). To enable auth: complete the AGH
# install wizard at http://10.0.0.1:3000/install.html, add an
# `agh-admin: "user:password"` entry to secrets/secrets.yaml, declare
# `sops.secrets."agh-admin"` here, and pass
# `-agh-credentials-file /run/secrets/agh-admin` to the binary.
#
# Trust model: brLan is the only interface where 10.0.0.1:80 is
# reachable (firewall.nix opens 80/tcp on brLan only). The page has
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
        # No -agh-credentials-file: runs in no-auth mode. See header.
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
      # PrivateUsers = true intentionally NOT set: it puts the service
      # in a user namespace where CAP_NET_BIND_SERVICE does not apply
      # to host-namespace ports, breaking the bind on :80.
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
