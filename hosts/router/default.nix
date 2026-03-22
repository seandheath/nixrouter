# Main router host configuration
#
# This is the entry point for the router NixOS configuration.
# Imports hardware-specific config and sets up networking.

{ config, lib, pkgs, inputs, ... }:

let
  # Import interface configuration (generated during install)
  interfacesFile = /etc/nixos/interfaces.nix;
  interfaces =
    if builtins.pathExists interfacesFile
    then import interfacesFile
    else { wan = "eth0"; lan = "eth1"; };

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

  # Network interface configuration
  networking = {
    # Use networkd for interface management
    useNetworkd = true;

    # Disable DHCP globally (we configure per-interface)
    useDHCP = false;

    # WAN interface: DHCP from upstream provider
    interfaces.${wan} = {
      useDHCP = true;
    };

    # LAN interface: Static IP (gateway for local network)
    interfaces.${lan} = {
      ipv4.addresses = [{
        address = "10.0.0.1";
        prefixLength = 24;
      }];
    };
  };

  # Enable systemd-networkd
  systemd.network.enable = true;

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
  system.stateVersion = "24.11";
}
