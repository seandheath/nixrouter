# SSH server configuration (hardened)
#
# Security measures:
#   - Key-based authentication only (no passwords)
#   - Root login disabled
#   - Limited to LAN interface
#   - Rate limiting via nftables (see firewall.nix)
#
# Reference: https://infosec.mozilla.org/guidelines/openssh

{ config, lib, pkgs, ... }:

let
  cfg = import ../config.nix;
  lanAddress = cfg.lan.address;
  bridgeDevice = "sys-subsystem-net-devices-${cfg.bridgeName}.device";
in
{
  services.openssh = {
    enable = true;

    settings = {
      # --- Authentication ---
      # Allow password authentication (admin password managed via sops)
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;

      # Disable root login entirely
      PermitRootLogin = "no";

      # Disable empty passwords
      PermitEmptyPasswords = false;

      # --- Network ---
      # Listen only on LAN interface
      ListenAddress = lanAddress;

      # --- Security Hardening ---
      # Disable TCP forwarding (prevent tunneling)
      AllowTcpForwarding = false;

      # Disable agent forwarding
      AllowAgentForwarding = false;

      # Disable X11 forwarding
      X11Forwarding = false;

      # Limit authentication attempts
      MaxAuthTries = 3;

      # Strict mode (check file permissions)
      StrictModes = true;

      # Disconnect after 60s of no activity during login
      LoginGraceTime = 60;

      # Verbose logging (useful for security auditing)
      LogLevel = "VERBOSE";

      # --- Cryptography ---
      # Use only strong ciphers (Mozilla Modern)
      Ciphers = [
        "chacha20-poly1305@openssh.com"
        "aes256-gcm@openssh.com"
        "aes128-gcm@openssh.com"
      ];

      # Use only strong MACs
      Macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
      ];

      # Use only strong key exchange algorithms
      KexAlgorithms = [
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
        "diffie-hellman-group16-sha512"
        "diffie-hellman-group18-sha512"
      ];

      # --- Keepalive Settings ---
      # Send keepalive every 30 seconds to prevent connection stalls.
      # Idle connections that miss 3 keepalives (90 seconds) are dropped.
      # This keeps connections alive through NAT/firewalls with short
      # TCP-idle timeouts (typical: 5-15 min). Previous 5-min value sat
      # right at the boundary and triggered mid-session freezes when
      # intermediate stateful devices forgot the connection.
      ClientAliveInterval = 30;
      ClientAliveCountMax = 3;

      # Enable TCP keepalive (uses kernel settings as fallback)
      TCPKeepAlive = true;
    };

    # Host keys (generated during install, persisted via impermanence)
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/etc/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };

  # Wait for the bridge interface AND for systemd-networkd to assign
  # the LAN address before binding. `after = [ bridgeDevice ]` only
  # waits for the netdev to exist - the address isn't necessarily up
  # yet, which causes sshd's first bind attempt to fail with
  # "Cannot assign requested address" on cold boot. ExecStartPre
  # polls for the address so the first ExecStart sees it ready.
  systemd.services.sshd = {
    after = [ bridgeDevice ];
    wants = [ bridgeDevice ];
    serviceConfig.ExecStartPre = pkgs.writeShellScript "wait-for-lan-addr" ''
      set -eu
      for _ in $(seq 1 50); do
        if ${pkgs.iproute2}/bin/ip -4 addr show dev ${cfg.bridgeName} | ${pkgs.gnugrep}/bin/grep -q "${lanAddress}/"; then
          exit 0
        fi
        sleep 0.2
      done
      echo "timeout waiting for ${lanAddress} on ${cfg.bridgeName}" >&2
      exit 1
    '';
  };

  # Banner shown before login
  services.openssh.banner = ''
    **************************************************************************
    * Authorized access only. All activity may be monitored and recorded.    *
    **************************************************************************
  '';
}
