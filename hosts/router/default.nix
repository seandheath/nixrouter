# Main router host configuration
#
# This is the entry point for the router NixOS configuration.
# Imports hardware-specific config and sets up networking.

{ config, lib, pkgs, inputs, ... }:

let
  interfaces = import ./interfaces.nix;
  wan = interfaces.wan;
  lan = interfaces.lan;
  cfg = import ../../config.nix;
in
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];

  # System identification
  networking.hostName = "router";

  # Boot loader configuration (UEFI)
  boot.loader = {
    systemd-boot = {
      enable = true;
      editor = false;  # Disable boot entry editing (security)
      consoleMode = "max";
    };
    efi.canTouchEfiVariables = true;

    # Timeout in seconds (0 = no menu unless holding key)
    timeout = 3;
  };

  # Use latest LTS kernel for stability + security patches
  boot.kernelPackages = pkgs.linuxPackages_6_6;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Network interface configuration
  # All interface config uses native systemd-networkd (systemd.network.networks)
  # VLANs, bridge, and LAN are configured in modules/vlans.nix
  networking = {
    useNetworkd = true;
    useDHCP = false;
  };

  # Headscale is reachable before the tailnet exists; tailscaled is a separate
  # node on that control plane and advertises only the trusted home LAN.
  fleet.headscaleServer = {
    enable = true;
    hostname = "headscale.luckyobserver.com";
    publicInterface = wan;
    acmeEmail = "se@nheath.com";
    tailnetDomain = "tail.luckyobserver.com";
    owner = "home";
    dnsRecords =
      [{ name = "git.luckyobserver.com"; type = "A"; value = "100.64.0.3"; }]
      ++ map (name: {
        inherit name;
        type = "A";
        value = "10.0.0.10";
      }) [
        "nc.luckyobserver.com"
        "immich.luckyobserver.com"
        "paper.luckyobserver.com"
        "calibre.luckyobserver.com"
        "mc.luckyobserver.com"
      ]
      ++ [{
        name = "marketplace.luckyobserver.com";
        type = "A";
        value = "100.64.0.3";
      }]
      ++ map (name: {
        inherit name;
        type = "A";
        value = cfg.tailnet.routerAddress;
      }) [ "kids.lan" "adguard.lan" "monitor.lan" ];
    policy = {
      # Tagged one-time pre-auth keys assign the non-human node identities.
      # Avoid naming home@ here so a brand-new database can load the policy
      # before headscale-bootstrap-owner creates the personal-device user.  An
      # empty owner group defines the tags without letting an interactive node
      # self-assign one; only an administrator-issued tagged key can do that.
      groups."group:preauth-only" = [ ];
      tagOwners = {
        "tag:admin" = [ "group:preauth-only" ];
        "tag:family" = [ "group:preauth-only" ];
        "tag:server" = [ "group:preauth-only" ];
        "tag:subnet-router" = [ "group:preauth-only" ];
      };
      autoApprovers.routes."10.0.0.0/24" = [ "tag:subnet-router" ];
      acls = [
        {
          action = "accept";
          src = [ "autogroup:member" "tag:admin" ];
          dst = [ "*:*" ];
        }
        {
          action = "accept";
          src = [ "tag:family" ];
          dst = [ "10.0.0.10:22,80,443,2456-2458,25565-25575" ];
        }
      ];
    };
  };

  fleet.tailscaleClient = {
    enable = true;
    acceptRoutes = false;
    tags = [ "tag:subnet-router" ];
    allowedTCPPorts = [ 22 53 80 443 ];
    allowedUDPPorts = [ 53 ];
  };

  fleet.tailscaleSubnetRouter = {
    enable = true;
    routes = [ cfg.lan.network ];
    lanInterface = cfg.bridgeName;
  };

  # WAN interface: DHCP from upstream ISP
  systemd.network.networks."10-wan" = {
    matchConfig.Name = wan;
    networkConfig.DHCP = "ipv4";
    dhcpV4Config.UseDNS = false;  # Router runs its own DNS via dnsmasq
    linkConfig.RequiredForOnline = "routable";
  };

  # Use router's own dnsmasq for DNS resolution
  networking.nameservers = [ "10.0.0.1" ];

  # Disable power management (router should never suspend)
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Wait for network to be online before starting services that need it
  systemd.network.wait-online = {
    anyInterface = true;  # Don't wait for all interfaces
    timeout = 30;
  };

  # Timezone — sourced from config.nix so kids-mode "until midnight"
  # and other local-time logic line up with system time.
  time.timeZone = cfg.timezone;

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";

  # Console configuration
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # Minimal system packages
  environment.systemPackages = with pkgs; [
    vim
    htop
    tmux
    tcpdump
    ethtool
    iperf3
    nftables
    conntrack-tools
    git          # For flake updates
    claude-code  # Anthropic Claude Code CLI - dynamic linker would
                 # block the upstream installer on NixOS, use the
                 # nixpkgs build instead
  ];

  # Enable vim as default editor
  programs.vim = {
    enable = true;
    defaultEditor = true;
  };

  # NixOS state version (do not change after install)
  system.stateVersion = "25.11";
}
