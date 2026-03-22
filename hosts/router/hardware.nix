# Hardware configuration template
#
# This file is a placeholder. During installation, nixos-generate-config
# will create the actual hardware.nix with detected hardware.
#
# You can also manually configure hardware here if you know the target system.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # --- CPU Microcode ---
  # Uncomment the appropriate line for your CPU:
  # hardware.cpu.intel.updateMicrocode = true;
  # hardware.cpu.amd.updateMicrocode = true;

  # --- Boot Initrd Modules ---
  # These modules are loaded early in the boot process.
  # nixos-generate-config will detect the required modules for your hardware.
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];

  # --- Kernel Modules ---
  # Modules loaded after boot
  boot.kernelModules = [ "kvm-intel" ];  # or "kvm-amd" for AMD

  # --- Network Hardware ---
  # Most Intel/Realtek NICs work out of the box.
  # If your NIC requires specific firmware:
  # hardware.enableRedistributableFirmware = true;

  # --- Power Management ---
  # Enable for laptops/mini-PCs (optional for dedicated router hardware)
  # powerManagement.enable = true;
  # services.tlp.enable = true;

  # --- Misc ---
  # Enable all firmware (may be needed for some NICs)
  hardware.enableRedistributableFirmware = lib.mkDefault true;
}
