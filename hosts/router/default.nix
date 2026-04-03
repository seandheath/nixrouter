# Main router host configuration
#
# This is the entry point for the router NixOS configuration.
# Imports hardware-specific config and sets up networking.

{ config, lib, pkgs, inputs, ... }:

let
  interfaces = import ./interfaces.nix;
  wan = interfaces.wan;
  lan = interfaces.lan;
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

  # Timezone (adjust to your location)
  time.timeZone = "UTC";

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
    tcpdump
    ethtool
    iperf3
    nftables
    conntrack-tools
    git  # For flake updates
  ];

  # Enable vim as default editor
  programs.vim = {
    enable = true;
    defaultEditor = true;
  };

  # NixOS state version (do not change after install)
  system.stateVersion = "25.11";
}
