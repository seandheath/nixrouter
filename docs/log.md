# Decision Log

## 2026-06-15 — Split-Horizon DNS for `*.luckyobserver.com`

**Decision:** Have the router's dnsmasq answer `nc/immich/calibre/paper.luckyobserver.com`
locally with hydrogen's LAN address (`10.0.0.10`) for all LAN and WireGuard
clients. Records are driven by a `localServices` knob in `config.nix` and
generated into `services.dnsmasq.settings.address`.

**Rationale:**
1. Keeps self-hosted traffic (Nextcloud, Immich, Calibre, paperless) on the
   LAN/tunnel instead of hairpinning out to the public IP.
2. Hydrogen already runs nginx and terminates TLS with a `*.luckyobserver.com`
   Cloudflare DNS-01 wildcard cert, so the router only needs to point the
   names at it — no reverse proxy, ACME, or extra open ports on the router.
3. Resolves correctly off-network too: WG clients use the router as resolver
   (dnsmasq listens on `wg0`), and `10.0.0.0/24` is in their split-tunnel
   AllowedIPs, so traffic to `10.0.0.10` flows through the tunnel.

**Alternatives considered:**
- Terminate TLS on the router and reverse-proxy to hydrogen's http nginx —
  rejected: splits the cert/proxy across two repos and adds a plaintext
  LAN hop. TLS stays co-located with the services on hydrogen instead.
- Wildcard `/luckyobserver.com/10.0.0.10` — rejected: it's a real public zone
  and would shadow `vpn.luckyobserver.com` (the WG endpoint A record),
  breaking VPN-endpoint resolution for LAN clients. Per-subdomain only.

<!-- TODO — Cross-repo dependency (nixos repo / hydrogen): nginx vhosts +
     the *.luckyobserver.com wildcard cert must serve these four names, or
     TLS will name-mismatch even though the router resolves them correctly. -->

## 2026-03-23 — Convert Back to Specific Configuration

**Decision:** Convert nixrouter from a reusable NixOS module back to a specific, deployable router configuration with sops-nix secrets.

**Rationale:**
1. Single deployment target simplifies maintenance
2. Secrets management with sops-nix provides better security than passing keys via flake options
3. Interface selection at install time via `install.sh` is more flexible
4. No abstraction overhead — direct configuration is easier to understand and modify
5. Password-encrypted age key allows storing secrets in the repo safely

**Changes:**
- Removed: `nixosModules.router` and `nixosModules.default` exports
- Removed: `options.router.*` option definitions
- Added: sops-nix input and module import
- Added: `config.nix` for static configuration values
- Added: `hosts/router/interfaces.nix` (generated at install time)
- Added: `secrets/secrets.yaml` (encrypted with sops)
- Added: `secrets/age-key.enc` (password-encrypted age private key)
- Added: `install.sh` for interactive installation
- Modified: All modules to import interfaces from `hosts/router/interfaces.nix`
- Modified: `users/admin.nix` to use sops secret for SSH keys

**Alternatives considered:**
- Keep as reusable module — Adds complexity for single-deployment use case
- Use agenix instead of sops-nix — sops-nix has better multiline secret support

---

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

## 2026-05-08 — Add WireGuard Remote-Access VPN

**Decision:** Add a `wg0` WireGuard interface on the router (UDP 51820 on
WAN) so off-network devices (starting with an Android phone) can reach
`brLan` over an encrypted tunnel. VPN subnet `10.40.0.0/24`, server
`10.40.0.1`. Reach is restricted to brLan; Guest/Kids/IoT VLANs stay
isolated. Public reachability via Cloudflare DDNS at `vpn.luckyobserver.com`.

**Rationale:**
1. Remote management of router and LAN services without exposing them to
   the public internet
2. Plain WireGuard is the minimum viable solution — single peer for now,
   list-shaped for adding more later
3. Forward-not-NAT routing preserves real client IPs on brLan and keeps
   future per-peer firewalling simple
4. Split-tunnel is the default — clients only route LAN traffic through
   home, not their general internet
5. sops-nix already handles the server private key; no new secrets backend
6. ddclient's Cloudflare provider already had a working template; just
   needed activation

**Alternatives considered:**
- Headscale + Tailscale — overkill for one phone; requires persisted
  state, an HTTPS endpoint, and DERP planning. Worth revisiting if/when
  the peer count grows or NAT traversal becomes a concern.
- wg-quick — adds a layer over `networking.wireguard.interfaces` without
  benefit for a static-peer setup.
- systemd-networkd `Kind=wireguard` netdev — would force a
  `systemd-network`-readable key file, complicating sops integration.
- Full-tunnel (`AllowedIPs = 0.0.0.0/0`) — left as a one-line config
  flip later; not worth the always-on AP mobile data cost by default.
- NAT (masquerade wg0 → brLan) — hides client IP, blocks future per-peer
  ACLs; chose plain forwarding instead.

---

## 2026-07-28 — Enable STP on brLan and drop tagged frames from the wired LAN port

**Decision:** Turn on Spanning Tree Protocol for `brLan`, and add ebtables
rules dropping 802.1Q/802.1ad-tagged frames arriving on `enp3s0f1` (the
wired LAN port facing the unmanaged switch).

**Rationale:** A layer-2 broadcast loop was diagnosed on this date. The two
`brLan` members — the trunk to the AP and the wired NIC to the unmanaged
switch — had been joined downstream by a redundant cable. With
`stp_state=0` there was nothing to break the ring:

- ~15.5k pps / ~61 Mbps of the router's own broadcast DHCP replies
  circulating, sourced from the trunk port's MAC `00:1b:21:70:7f:57`
- ~2,900 `brLan: received packet on enp3s0f1 with own address as source
  address` warnings per second, plus `net_ratelimit` suppressing 14k–22k
  callbacks per 5s interval
- FDB flapping: `00:a5:54:03:b9:f2` learned on both ports within 6s
- dnsmasq answering 5 DISCOVER/OFFER pairs per second to a single client
- 96% of frames arriving on `enp3s0f1` were tagged vlan 10/20, meaning
  Guest/Kids traffic was crossing the main LAN segment

Pulling the cable stopped the storm at 14:17:12, confirmed by 90s of zero
loop messages, zero tagged frames on `enp3s0f1`, and no multi-port FDB
entries. But cabling is not a durable control — re-plugging that cable, or
a guest bridging two wall ports, reproduces this exactly. These two changes
make the failure self-limiting instead.

Unmanaged switches forward BPDUs rather than consuming them, so STP lets the
router detect its own BPDU returning on the opposite port and block one.
The ebtables rules are the second layer: they close the VLAN leak
independently of whether a loop exists, and they have to live in the bridge
hooks because switched frames never reach iptables.

**Alternatives considered:**
- Bridge VLAN filtering (`vlan_filtering=1` with per-port VLAN maps) —
  the more correct long-term model, and it would subsume the ebtables
  rules. Deferred: it requires reworking the trunk-port-plus-subinterface
  design in `modules/vlans.nix`, and would have meant a disruptive change
  during an active incident.
- RSTP (802.1w) via `mstpd` — ~2s convergence vs. STP's ~30s, but adds a
  userspace daemon for a two-port bridge that should never be looped in
  the first place. Not worth the dependency.
- Leaving it to cabling discipline — rejected; that is what failed.
- `nft` bridge-family table instead of ebtables — cleaner syntax, but the
  firewall module is iptables-backed (`networking.nftables.enable` is
  unset) and this would have needed a separate systemd unit.

**Deployment note:** Applied 2026-07-28 14:31 via the router's own flake
clone at `/nix/persist/etc/nixos` (`make deploy` is unusable — it wants
`root@` SSH, and root login is disabled). The router's `flake.lock` was 3
months ahead of the repo's, uncommitted, because auto-upgrade's
`nix flake update --commit-lock-file` updates it but its commit is swallowed
by the `|| true` in flake-update.sh. Stashed the lock across the pull so the
deploy did not silently roll nixpkgs back from `b6018f8` to `bcd464c`.

Post-deploy state: `stp_state 1`, both ports forwarding, router elected root
bridge (no loop present, so nothing blocks — correct). Four ebtables rules
live, counters at 0. No failed units, no loop warnings, no dmesg errors;
DNS, NAT, and WireGuard all verified working.

<!-- TODO — flake-update.sh swallows the exit status of
     `nix flake update --commit-lock-file` with `|| true`, so a failed commit
     leaves flake.lock permanently dirty in the working tree and the repo's
     committed lock drifts behind what the router actually runs. Any deploy
     that does not preserve the local lock silently downgrades nixpkgs. -->
<!-- TODO — Consider migrating bridge filtering to bridge VLAN filtering
     (vlan_filtering=1 with per-port VLAN maps), which would subsume the
     ebtables rules and remove the legacy-ebtables/nft-backend split. -->
<!-- TODO — Root cause of the loop was a physical cable joining the AP's LAN
     side to the unmanaged switch. Label both ends or remove the run. -->
<!-- TODO — Consider RSTP via mstpd if the ~30s STP convergence on link
     events becomes disruptive. -->

---

<!-- TODO:SECURITY — SSH keys for admin user must be added before deployment -->
<!-- TODO:SECURITY — Audit nftables rules for completeness after real-world testing -->
<!-- TODO:FEATURE — Add IPv6 support (currently IPv4-only) -->
<!-- TODO:FEATURE — Add port forwarding examples to firewall.nix -->
<!-- TODO — Test VM build target with proper networking simulation -->
