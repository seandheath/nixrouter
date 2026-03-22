# Hardening a NixOS router for unattended operation

**Your NixOS router config at `seandheath/nixos` has solid fundamentals — IP forwarding, SYN flood protection, kernel panic auto-reboot — but lacks three critical capabilities for a system that goes months untouched: automatic security updates, scheduled reboots, and ephemeral root storage.** The config also runs a Veloren game server directly on the network perimeter, which is the single biggest security concern. This review covers every gap with specific, copy-paste NixOS configuration snippets.

The analysis is based on the reconstructed `hosts/router.nix` (the only file indexed by search engines from the repo), which imports `modules/core.nix`, `modules/sops.nix`, `users/user.nix`, `users/veloren.nix`, and `modules/ddclient.nix`. The WAN interface is `enp3s0f1`, IPv6 is configured with autoconfiguration on WAN only, and sops-nix handles secrets management.

## Your config has no automatic updates — here's what to add

The current configuration contains **zero auto-upgrade machinery**. No `system.autoUpgrade`, no systemd timers for flake updates, no channel tracking. For a router untouched for months, this means known kernel vulnerabilities, OpenSSL bugs, and firewall bypasses accumulate silently.

**The simplest reliable approach** uses the built-in `system.autoUpgrade` module pointed at a stable-small channel or flake. The `nixos-XX.YY-small` channel is ideal for routers: identical security patches to the full stable channel but **advances hours to days faster** because Hydra only needs to build a smaller package set. For a router with minimal packages, the build penalty is negligible.

If your repo uses flakes (likely, given the modular structure), the recommended pattern is a **separate systemd service that updates `flake.lock` before the upgrade runs**. The commonly cited `--update-input nixpkgs` flag is **deprecated as of Nix 2.19** and may silently stop working — a serious risk for an unattended system.

```nix
# modules/auto-upgrade.nix
{ config, pkgs, ... }:
let
  flakePath = "/etc/nixos";
in {
  # Step 1: Update flake.lock before rebuilding
  systemd.services.flake-update = {
    description = "Update flake inputs";
    serviceConfig = {
      ExecStart = "${pkgs.nix}/bin/nix flake update --flake ${flakePath}";
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "60";
    };
    before = [ "nixos-upgrade.service" ];
    requiredBy = [ "nixos-upgrade.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.nix pkgs.git ];
  };

  programs.git.config.safe.directory = [ flakePath ];

  # Step 2: Rebuild from updated flake
  system.autoUpgrade = {
    enable = true;
    flake = "${flakePath}#router";
    dates = "03:00";
    randomizedDelaySec = "45min";
    operation = "boot";       # safer: don't activate until reboot
    allowReboot = true;
    rebootWindow = {
      lower = "03:30";
      upper = "05:00";
    };
    persistent = true;        # catch up if timer was missed
  };

  # Prevent disk from filling over months
  boot.loader.systemd-boot.configurationLimit = 10;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.settings.auto-optimise-store = true;
}
```

Pin your `flake.nix` input to the small channel for faster security propagation:

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11-small";
}
```

The `operation = "boot"` setting is deliberate. Unlike `"switch"`, which activates the new config live (potentially disrupting active connections mid-packet), `"boot"` only makes the new generation the boot default. The system continues running the proven config until the controlled reboot in the `rebootWindow`. If the new config fails to boot, the previous generation remains selectable in the boot menu.

**For an even more robust approach**, use a CI pipeline (GitHub Actions with `DeterminateSystems/update-flake-lock`) to update `flake.lock` in your repo daily, optionally running `nix build` to verify the config builds. The router then pulls and rebuilds from a known-good commit, giving you a testing gate before updates reach production.

## Scheduled reboots with conditional logic and kexec

The config has no reboot mechanism beyond `kernel.panic = 60` (which only triggers on kernel panics). For a long-running router, periodic reboots clear accumulated state — memory fragmentation, leaked file descriptors, stale conntrack entries — and activate kernel updates that `operation = "boot"` staged.

The best approach combines **conditional weekly reboots** (only when the kernel/initrd actually changed) with an **unconditional monthly safety-net reboot** and **kexec** to minimize downtime from ~60 seconds to ~10 seconds:

```nix
# modules/scheduled-reboot.nix
{ config, pkgs, lib, ... }: {
  # Weekly: reboot only if kernel/initrd changed after upgrade
  systemd.services."router-conditional-reboot" = {
    description = "Conditional weekly reboot (only if kernel changed)";
    path = with pkgs; [ coreutils kexec-tools ];
    serviceConfig = {
      Type = "oneshot";
      # ExecCondition: exit 1 = skip silently, exit 0 = proceed
      ExecCondition = pkgs.writeShellScript "needs-reboot" ''
        booted="$(readlink /run/booted-system/{initrd,kernel,kernel-modules})"
        current="$(readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})"
        if [ "$booted" = "$current" ]; then
          echo "Kernel unchanged, skipping reboot"
          exit 1
        fi
        echo "Kernel changed, reboot required"
      '';
    };
    script = ''
      # Try kexec first (bypasses BIOS, ~10s), fall back to full reboot
      p=$(readlink -f /nix/var/nix/profiles/system)
      cmdline="init=$p/init $(cat $p/kernel-params)"
      kexec -l "$p/kernel" --initrd="$p/initrd" --command-line="$cmdline" && \
        systemctl kexec || \
        systemctl reboot
    '';
  };

  systemd.timers."router-conditional-reboot" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # Monthly: unconditional reboot to clear accumulated state
  systemd.services."router-monthly-reboot" = {
    description = "Monthly unconditional router reboot";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl reboot";
    };
  };

  systemd.timers."router-monthly-reboot" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 04:30:00";
      Persistent = true;
    };
  };

  environment.systemPackages = [ pkgs.kexec-tools ];
}
```

**kexec loads the new kernel directly into memory**, skipping BIOS/UEFI initialization entirely. On typical x86 router hardware, this reduces reboot time from 60+ seconds to under 10. The script falls back to a standard reboot if kexec fails (which can happen on some hardware that needs full re-initialization). **Note**: if you enable `kernel.kexec_load_disabled = 1` in sysctl hardening (see below), you must remove the kexec path and use only `systemctl reboot`.

## Running root on tmpfs with impermanence

The `nix-community/impermanence` module lets you mount `/` on tmpfs and declaratively specify only what persists across reboots. Every reboot gives you a **factory-fresh system state** — rogue files, compromised binaries, or corrupted state outside `/nix` simply vanish. For a router, this is a powerful security and reliability guarantee.

The architecture is simple: `/boot` and `/nix` live on disk, `/` lives in RAM, and bind mounts connect persistent paths to their expected locations. Your `/nix/store` (which contains all NixOS system files) remains untouched on disk — the system boots normally because NixOS is just symlinks into the store.

### Disk layout and filesystem configuration

```nix
# Partition layout:
#   /dev/sda1 - 512MB FAT32 - /boot (EFI)
#   /dev/sda2 - remainder ext4 - /nix (store + persistent state)

fileSystems."/" = {
  device = "none";
  fsType = "tmpfs";
  options = [ "defaults" "size=1G" "mode=755" ];  # 1G is plenty for a router
};

fileSystems."/nix" = {
  device = "/dev/disk/by-label/nix";
  fsType = "ext4";
  neededForBoot = true;  # critical: must be available for impermanence bind mounts
};

fileSystems."/boot" = {
  device = "/dev/disk/by-label/boot";
  fsType = "vfat";
};
```

The **`mode=755`** on tmpfs is required — without it, OpenSSH and other services reject the root filesystem permissions. The **`size=1G`** is conservative; a router generates minimal ephemeral data. Monitor with `df -h /` after running for a few days.

### What to persist for a router

```nix
# Add to flake.nix inputs:
#   impermanence.url = "github:nix-community/impermanence";
# Add to modules:
#   impermanence.nixosModules.impermanence

environment.persistence."/nix/persist" = {
  hideMounts = true;

  directories = [
    "/etc/nixos"                        # your flake/config
    "/var/lib/nixos"                    # uid/gid maps, declarative user state
    "/var/log"                          # journald logs for post-mortem debugging
    "/var/lib/systemd/timers"           # persistent timer state (for auto-upgrade)
    "/var/lib/systemd/coredump"         # crash dumps

    # DHCP leases (use whichever applies):
    # "/var/lib/dnsmasq"                # if using dnsmasq
    # "/var/lib/kea"                    # if using kea
    # "/var/lib/dhcp"                   # if using ISC dhcpd

    # ddclient state
    "/var/lib/ddclient"
    # "/var/cache/ddclient"             # if ddclient caches here
  ];

  files = [
    "/etc/machine-id"                   # critical: journald, systemd use this
    "/etc/ssh/ssh_host_ed25519_key"
    "/etc/ssh/ssh_host_ed25519_key.pub"
    "/etc/ssh/ssh_host_rsa_key"
    "/etc/ssh/ssh_host_rsa_key.pub"
  ];
};

# CRITICAL: Users must be immutable with tmpfs root
users.mutableUsers = false;

# Suppress the sudo lecture (it reappears every reboot with tmpfs root)
security.sudo.extraConfig = "Defaults lecture = never";
```

**sops-nix integration is the trickiest part.** The age key or SSH host keys used for decryption must be available at boot, before impermanence bind mounts are fully set up. Two solutions:

```nix
# Option A: Reference the persistent path directly (simplest)
sops.age.keyFile = "/nix/persist/var/lib/sops-nix/key.txt";
sops.age.sshKeyPaths = [];  # don't look in /etc/ssh (not mounted yet)

# Option B: Use SSH host keys but reference persistent location
sops.age.sshKeyPaths = [ "/nix/persist/etc/ssh/ssh_host_ed25519_key" ];
```

Things you **do not need to persist** on a router: firewall rules (declarative in NixOS, regenerated every boot), conntrack state (kernel runtime state, rebuilds naturally), `/etc/resolv.conf` (generated from config), `/etc/passwd` and `/etc/shadow` (generated from `users.users`).

## Twenty missing sysctl settings and a game server on the perimeter

Your current sysctl block covers forwarding, SYN cookies, ICMP broadcasts, and TCP buffer tuning — a reasonable starting point. But **several critical router-specific hardening settings are absent**, and the Veloren game server import is the most significant security concern.

### The Veloren problem

Importing `users/veloren.nix` means an **alpha-quality game server runs directly on your network perimeter**. Veloren uses TCP/UDP 14004 and is CPU/memory-intensive. A vulnerability in Veloren gives an attacker direct access to the device forwarding all your traffic. A DDoS against the game port saturates your entire WAN link. Under heavy game load, packet forwarding, DHCP, and DNS processing starve for CPU cycles.

**Strong recommendation: move Veloren to a separate machine behind the router.** If that's impossible, at minimum sandbox it aggressively with systemd resource controls (`CPUQuota = "50%"`, `MemoryMax = "2G"`, `ProtectSystem = "strict"`, full `CapabilityBoundingSet = ""`) and bind it only to the LAN interface.

### Missing sysctl hardening

Add these to your existing `boot.kernel.sysctl` block:

```nix
boot.kernel.sysctl = {
  # --- YOUR EXISTING SETTINGS (keep all of them) ---

  # --- ADD: Anti-spoofing (critical for a router) ---
  "net.ipv4.conf.all.rp_filter" = 1;         # strict reverse path filtering
  "net.ipv4.conf.default.rp_filter" = 1;

  # --- ADD: Disable ICMP redirects (router must not accept or send these) ---
  "net.ipv4.conf.all.accept_redirects" = false;
  "net.ipv4.conf.default.accept_redirects" = false;
  "net.ipv4.conf.all.secure_redirects" = false;
  "net.ipv4.conf.all.send_redirects" = false;
  "net.ipv4.conf.default.send_redirects" = false;
  "net.ipv6.conf.all.accept_redirects" = false;

  # --- ADD: Disable source routing ---
  "net.ipv4.conf.all.accept_source_route" = false;
  "net.ipv6.conf.all.accept_source_route" = false;

  # --- ADD: Log packets with impossible source addresses ---
  "net.ipv4.conf.all.log_martians" = true;

  # --- ADD: TIME-WAIT assassination protection ---
  "net.ipv4.tcp_rfc1337" = true;

  # --- ADD: Connection tracking (raise for busy networks) ---
  "net.netfilter.nf_conntrack_max" = 131072;

  # --- ADD: BBR congestion control + bufferbloat mitigation ---
  "net.ipv4.tcp_congestion_control" = "bbr";
  "net.core.default_qdisc" = "fq";

  # --- ADD: Kernel security ---
  "kernel.kptr_restrict" = 2;          # hide kernel pointers
  "kernel.dmesg_restrict" = 1;         # restrict dmesg to root
  "kernel.unprivileged_bpf_disabled" = 1;
  "kernel.sysrq" = 4;                  # only allow SAK
  "kernel.yama.ptrace_scope" = 2;      # restrict ptrace
  "fs.suid_dumpable" = 0;              # no core dumps from setuid binaries
};

# BBR requires this kernel module
boot.kernelModules = [ "tcp_bbr" ];
```

**`rp_filter = 1`** (strict reverse path filtering) is arguably the most important missing setting. It drops packets with source addresses that don't match what the routing table says — the primary defense against IP spoofing attacks from the WAN. Your router currently accepts spoofed packets without question.

**BBR + fq** transforms TCP performance. BBR (Bottleneck Bandwidth and Round-trip propagation time) is Google's congestion control algorithm that achieves significantly better throughput than the default CUBIC, especially on lossy links. The `fq` qdisc provides fair queuing that pairs with BBR to control bufferbloat.

### SSH configuration concerns

The ForceCommand that echoes Matrix quotes is a creative deterrent, but if you actually need SSH access to the router, it blocks legitimate admin sessions too. More critically, ForceCommand **can be bypassed if TCP forwarding is enabled** — an attacker with valid keys can tunnel without executing the command. Ensure these are set:

```nix
services.openssh.settings = {
  PasswordAuthentication = false;
  PermitRootLogin = "no";
  AllowTcpForwarding = false;     # prevents ForceCommand bypass
  AllowAgentForwarding = false;
  X11Forwarding = false;
  MaxAuthTries = 3;
  LogLevel = "VERBOSE";           # needed for fail2ban
};
```

Add fail2ban for brute-force protection and consider `services.endlessh-go` as a tarpit on port 22 if you move real SSH to a non-standard port.

### Additional hardening

```nix
# Enable nftables backend (better performance, atomic rule replacement)
networking.nftables.enable = true;

# Log refused connections for debugging
networking.firewall.logRefusedConnections = true;

# Blacklist unused kernel modules (reduces attack surface)
boot.blacklistedKernelModules = [
  "dccp" "sctp" "rds" "tipc" "n-hdlc" "ax25" "netrom" "x25"
  "rose" "decnet" "econet" "af_802154" "ipx" "appletalk"
  "cramfs" "freevxfs" "jffs2" "hfs" "hfsplus" "udf"
  "bluetooth" "btusb" "uvcvideo" "firewire-core" "vivid"
];

# Kernel security options
security.protectKernelImage = true;
security.forcePageTableIsolation = true;

# Restrict nix commands to wheel group
nix.settings.allowed-users = [ "@wheel" ];
```

## Conclusion

The existing configuration demonstrates good NixOS fundamentals — modular structure, sops-nix secrets management, reasonable TCP tuning, and kernel panic recovery. The three highest-impact changes, in priority order:

1. **Add `system.autoUpgrade` with a `flake-update` service** targeting `nixos-24.11-small`. This alone closes the months-long window where known CVEs accumulate unpatched. Use `operation = "boot"` to avoid disrupting active routing.

2. **Implement conditional reboots via systemd timer** to activate staged kernel updates and clear accumulated state. The kexec path keeps downtime under 10 seconds.

3. **Move to tmpfs root with impermanence** for a genuinely ephemeral system where compromise artifacts, corrupted state, and configuration drift vanish on every reboot. This pairs naturally with scheduled reboots — each cycle delivers a factory-fresh router running the latest security patches.

Beyond these three features, **move Veloren off the router immediately** — it's a pre-alpha game server running on your network's single point of failure. Add the missing sysctl hardening (especially `rp_filter`, redirect disabling, and BBR), blacklist unused kernel modules, and switch to nftables for your firewall backend. These changes transform the router from a reasonably configured system into one that can genuinely run unattended for months with confidence.