# Kernel and system hardening configuration
#
# Implements security best practices for a network router:
#   - Strict reverse path filtering (BCP38/RFC3704)
#   - Disabled ICMP redirects (prevent MITM)
#   - Source routing disabled
#   - Martian packet logging
#   - TCP hardening (RFC 1337 TIME-WAIT assassination)
#   - Connection tracking limits
#   - BBR congestion control for better throughput
#   - Kernel pointer/dmesg restrictions
#   - Module blacklisting for unused protocols
#
# References:
#   - https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt
#   - https://wiki.archlinux.org/title/Sysctl#TCP/IP_stack_hardening
#   - CIS Benchmark for Linux

{ config, lib, pkgs, ... }:

{
  # Kernel boot parameters
  boot.kernelParams = [
    # Disable kernel module loading after boot (can be re-enabled if needed)
    # "module.sig_enforce=1"  # Uncomment if using signed modules only

    # Restrict /dev/mem access
    "strict_devmem=1"
  ];

  # Sysctl network hardening
  boot.kernel.sysctl = {
    #
    # --- Reverse Path Filtering (BCP38) ---
    # Strict mode: packet must arrive on interface that would be used to reach source
    # Prevents IP spoofing attacks
    #
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;

    #
    # --- ICMP Hardening ---
    # Disable ICMP redirects (routers should not accept these)
    # Prevents MITM attacks via malicious ICMP redirect
    #
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv4.conf.default.secure_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;

    # IPv6 redirects
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;

    #
    # --- Source Routing ---
    # Disable source routing (attacker-controlled packet paths)
    #
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.default.accept_source_route" = 0;

    #
    # --- Logging ---
    # Log packets with impossible addresses (martians)
    # Useful for detecting misconfiguration or attacks
    #
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.conf.default.log_martians" = 1;

    #
    # --- TCP Hardening ---
    # RFC 1337: Protect against TIME-WAIT assassination
    #
    "net.ipv4.tcp_rfc1337" = 1;

    # SYN flood protection (already enabled by default, but explicit)
    "net.ipv4.tcp_syncookies" = 1;

    # Reduce TIME-WAIT sockets (router sees many connections)
    "net.ipv4.tcp_fin_timeout" = 30;

    #
    # --- Connection Tracking ---
    # Increase conntrack table size for router workload
    # Default is often too small for NAT gateway
    #
    "net.netfilter.nf_conntrack_max" = 131072;

    # Reduce conntrack timeouts for faster cleanup
    "net.netfilter.nf_conntrack_tcp_timeout_established" = 3600;
    "net.netfilter.nf_conntrack_tcp_timeout_time_wait" = 30;

    #
    # --- BBR Congestion Control ---
    # Better throughput and latency than CUBIC, especially on lossy links
    # Reference: https://cloud.google.com/blog/products/networking/tcp-bbr-congestion-control-comes-to-gcp-your-internet-just-got-faster
    #
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";

    #
    # --- Buffer Sizes ---
    # Increase socket buffer sizes for better throughput
    #
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 87380 16777216";
    "net.ipv4.tcp_wmem" = "4096 65536 16777216";

    #
    # --- Kernel Security ---
    # Restrict access to kernel pointers (information disclosure)
    #
    "kernel.kptr_restrict" = 2;

    # Restrict dmesg access to root only
    "kernel.dmesg_restrict" = 1;

    # Restrict ptrace to root only (prevents many debugging-based attacks)
    "kernel.yama.ptrace_scope" = 2;

    # Disable magic SysRq key (physical security)
    "kernel.sysrq" = 0;

    # Restrict kernel profiling
    "kernel.perf_event_paranoid" = 3;

    #
    # --- Kernel Panic Handling ---
    # Auto-reboot after kernel panic (critical for headless router)
    # Value is seconds to wait before reboot
    #
    "kernel.panic" = 60;

    #
    # --- Additional ICMP Hardening ---
    # Ignore ICMP broadcasts (smurf attack protection)
    # Reference: CVE-1999-0513
    #
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;

    # Ignore bogus ICMP error responses
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

    #
    # --- IPv6 Router Advertisement Hardening ---
    # Disable RA acceptance by default (router should not accept RA on LAN)
    # WAN interface RA is enabled in firewall.nix where interface is known
    #
    "net.ipv6.conf.all.accept_ra" = 0;
    "net.ipv6.conf.all.autoconf" = 0;
    "net.ipv6.conf.all.use_tempaddr" = 0;
    "net.ipv6.conf.default.accept_ra" = 0;
    "net.ipv6.conf.default.autoconf" = 0;
  };

  # Load BBR congestion control module
  boot.kernelModules = [ "tcp_bbr" ];

  # Blacklist unused/insecure kernel modules
  # These protocols are rarely needed on a router and reduce attack surface
  boot.blacklistedKernelModules = [
    # Insecure/legacy protocols
    "dccp"       # Datagram Congestion Control Protocol
    "sctp"       # Stream Control Transmission Protocol
    "rds"        # Reliable Datagram Sockets
    "tipc"       # Transparent Inter-Process Communication

    # Wireless (not needed on wired router)
    "bluetooth"
    "btusb"

    # Filesystems (reduce attack surface)
    "cramfs"
    "freevxfs"
    "hfs"
    "hfsplus"
    "jffs2"
    "udf"

    # Uncommon network filesystems
    "cifs"
    "nfs"
    "nfsv3"
    "nfsv4"
    "gfs2"
  ];

  # NixOS security options
  security = {
    # Protect kernel image from modification
    protectKernelImage = true;

    # Force page table isolation (Meltdown mitigation)
    forcePageTableIsolation = true;

    # Lockdown mode (optional, may break some functionality)
    # lockKernelModules = true;
  };

  # Disable coredumps (information disclosure)
  systemd.coredump.enable = false;

  # Memory allocator hardening
  environment.memoryAllocator.provider = "scudo";
}
