# Decision Log

## 2026-03-21 — Make nixrouter Generic

**Decision:** Refactor nixrouter to be a reusable NixOS module exportable via flake.

**Rationale:**
1. Personal data (SSH keys, secrets) doesn't belong in a public repo
2. Interface names are deployment-specific
3. Export as `nixosModules.router` allows use from personal infrastructure repos
4. Required options (`router.adminKeys`, `router.interfaces.*`) enforce configuration at build time

**Changes:**
- Removed: `install.sh`, `secrets/secrets.yaml`
- Added: `modules/default.nix` with option definitions
- Added: `nixosModules.router` and `nixosModules.default` exports in flake.nix
- Modified: All modules to use `config.router.interfaces.*` instead of `/etc/nixos/interfaces.nix`
- Modified: `users/admin.nix` to use `config.router.adminKeys`
- Made `sops.nix` optional (not imported by default)

**Alternatives considered:**
- Keep install.sh with prompts — Still requires manual key entry, better in consuming repo
- Use environment variables — Less declarative, harder to validate

---

## 2026-03-19 — Initial Implementation

**Decision:** Use nixos-24.11-small channel for the base system.

**Rationale:** The `-small` variant excludes graphical packages and documentation, reducing closure size. Ideal for headless router hardware with limited storage.

**Alternatives considered:**
- `nixos-24.11` — Full channel, unnecessarily large
- `nixos-unstable` — Less stable, risky for network infrastructure

---

## 2026-03-19 — Ephemeral Root with tmpfs

**Decision:** Mount root as tmpfs and persist state to /nix/persist via impermanence module.

**Rationale:**
1. Clean boot state eliminates configuration drift
2. Explicit persistence forces documentation of stateful paths
3. Faster boots (no fsck on root)
4. Malware cannot easily survive reboots

**Alternatives considered:**
- Traditional persistent root — Simpler but accumulates cruft
- ZFS with boot environments — More complex, overkill for router
- Btrfs snapshots — Requires more storage management

---

## 2026-03-21 — Migration Support in install.sh

**Decision:** Add three-mode install script: fresh install, migration, and upgrade.

**Rationale:**
1. Fresh install: Standard path from ISO
2. Migration: Allows moving from existing NixOS router to ephemeral root without losing state
3. Upgrade: Fast path for already-migrated systems (nixos-rebuild switch)
4. Auto-detection based on system state (tmpfs root, hostname, sops key presence)

**State preserved during migration:**
- SSH host keys (preserves known_hosts on clients)
- DHCP leases (optional, clients re-request)
- ddclient cache (dynamic DNS state)
- Machine ID

---

## 2026-03-21 — Additional Hardening and Reliability Settings

**Decision:** Add kernel panic auto-reboot, ICMP hardening, IPv6 RA controls, and disable sleep targets.

**Rationale:**
1. `kernel.panic=60`: Auto-reboot after 60s on kernel panic (critical for headless router)
2. ICMP broadcast/bogus response ignore: Smurf attack protection
3. IPv6 RA disabled by default, enabled only on WAN: Prevents rogue RA on LAN
4. Sleep targets disabled: Router should never suspend
5. `networking.nameservers = ["10.0.0.1"]`: Router uses own dnsmasq

---

## 2026-03-21 — Switch to NixOS Declarative Firewall

**Decision:** Use `networking.firewall` and `networking.nat` modules instead of raw nftables ruleset.

**Rationale:**
1. Declarative syntax avoids string interpolation issues in nftables rules
2. Per-interface rules (`networking.firewall.interfaces.<name>`) handle LAN/WAN separation cleanly
3. NAT masquerading via `networking.nat` is simpler than manual nftables
4. SSH rate limiting can be handled by fail2ban or sshd's MaxStartups instead
5. Easier to maintain and less error-prone

**Alternatives considered:**
- Raw nftables ruleset — More control but complex string escaping issues
- `networking.nftables.tables` — Structured but still requires careful syntax

---

## 2026-03-19 — nftables over iptables (superseded)

**Decision:** Use nftables for firewall and NAT instead of the default NixOS iptables firewall.

**Rationale:**
1. nftables is the modern replacement for iptables
2. Cleaner syntax for complex rulesets
3. Better performance with large rulesets
4. Atomic rule updates
5. iptables-nft compatibility layer deprecated

**Alternatives considered:**
- `networking.firewall` (iptables) — Simpler but legacy
- firewalld — Overkill for static ruleset

**Note:** Superseded by 2026-03-21 decision to use declarative firewall.

---

## 2026-03-19 — dnsmasq over systemd-resolved

**Decision:** Use dnsmasq for combined DHCP and DNS.

**Rationale:**
1. Single service for both DHCP and DNS
2. Lightweight and well-tested
3. Easy static lease configuration
4. DNSSEC validation support
5. Extensive documentation

**Alternatives considered:**
- ISC DHCP + bind — More complex, two services to manage
- systemd-resolved + kea — Newer but less mature
- unbound + kea — Good but more memory usage

---

## 2026-03-19 — kexec for Fast Reboots

**Decision:** Use kexec for scheduled reboots to minimize downtime.

**Rationale:** kexec loads the new kernel directly from the running kernel, bypassing BIOS/UEFI POST. Reduces reboot time from ~60s to ~10s.

**Alternatives considered:**
- Regular reboot — Slower, includes full POST
- No scheduled reboots — Kernel updates require manual intervention

---

## 2026-03-19 — BBR Congestion Control

**Decision:** Enable BBR TCP congestion control with fq qdisc.

**Rationale:** BBR provides better throughput and lower latency than CUBIC, especially on lossy or high-latency links. Developed by Google, widely deployed.

**Alternatives considered:**
- CUBIC (default) — Good but BBR is better for router workloads
- HTCP — Less tested at scale

---

## 2026-03-19 — sops-nix with age

**Decision:** Use sops-nix with age encryption for secrets management.

**Rationale:**
1. age is simpler than GPG
2. sops supports multiple key types
3. Secrets stored in git (encrypted)
4. Decrypted to tmpfs at runtime
5. NixOS integration via sops-nix module

**Alternatives considered:**
- agenix — Similar but sops-nix more flexible
- vault — Overkill for single-machine deployment
- Plain text in /nix/persist — Insecure

---

<!-- TODO:SECURITY — SSH keys for admin user must be added before deployment -->
<!-- TODO:SECURITY — Audit nftables rules for completeness after real-world testing -->
<!-- TODO:FEATURE — Add IPv6 support (currently IPv4-only) -->
<!-- TODO:FEATURE — Add port forwarding examples to firewall.nix -->
<!-- TODO — Test VM build target with proper networking simulation -->
