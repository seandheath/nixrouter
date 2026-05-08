# Kids VLAN mode toggle
#
# A tiny HTTP service that flips AdGuard Home between two modes:
#   - restricted: whitelist-only (AGH user_rules = ["/.*/", "@@||d^", ...])
#   - play:       AGH user_rules = []; family DNS upstreams (1.1.1.3 etc.)
#
# Binds 127.0.0.1:3001 (loopback only). nginx (modules/nginx.nix) is
# the public entry point on http://kids.lan/ from brLan.
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
# Trust model: nginx is the only thing that can reach kids-mode-web
# (loopback bind), and nginx itself only listens on the brLan address.
# The page has no auth of its own - if you're on the trusted LAN you
# can flip modes.

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

    # Both the bind addr and the AGH URL are loopback now, so we don't
    # actually need brLan up. Keep the AGH ordering so the first
    # reconcile lands silently.
    after = [ "adguardhome.service" ];

    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.kids-mode}/bin/kids-mode"
        "-addr 127.0.0.1:3001"
        "-state-dir /var/lib/kids-mode"
        "-agh-url http://127.0.0.1:3000"
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

      # Network: loopback only. Bind addr and AGH URL are both 127.0.0.1.
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "127.0.0.0/8" ];

      # Unprivileged port, no caps needed.
      AmbientCapabilities = [ ];
      CapabilityBoundingSet = [ "" ];
    };
  };
}
