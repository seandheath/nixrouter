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
  lanAddress = "10.0.0.1";
in
{
  services.openssh = {
    enable = true;

    settings = {
      # --- Authentication ---
      # Disable password authentication (keys only)
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;

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

      # --- Client Keepalive ---
      # Disconnect inactive clients after 3 missed keepalives (15 min)
      ClientAliveInterval = 300;
      ClientAliveCountMax = 3;
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

  # Banner shown before login
  services.openssh.banner = ''
    **************************************************************************
    * Authorized access only. All activity may be monitored and recorded.    *
    **************************************************************************
  '';
}
