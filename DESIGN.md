# Design — Zero-Leak Tailscale Exit-Node Kill Switch

The goal: every device behind the router egresses **only** through a chosen Tailscale exit
node, and if that path is unavailable the router has **no internet at all** rather than
leaking its real WAN IP. Easy to toggle off (physical switch + web page) for normal/local
internet and captive-portal logins.

This document is the full rationale and the hardening details. For setup see
[README.md](README.md); for daily operation see [CHEATSHEET.md](CHEATSHEET.md).

## Reference rig (what this was built and verified on)

- Router: GL.iNet GL-MT3600BE ("Beryl 7"), GL.iNet 4.x / OpenWrt 21.02, aarch64,
  Tailscale 1.92.x. Firewall backend **fw3 / iptables**. `NetfilterMode=2` (Tailscale owns
  the `ts-*` chains). WAN on `eth0`, LAN `br-lan`. Physical slide switch via
  `/etc/gl-switch.d/`.
- Exit node: any always-on tailnet host advertising `--advertise-exit-node`, approved in the
  admin console, with a direct path to the router.
- Note: GL.iNet's native kill switch only covers GL's own WireGuard/OpenVPN clients, **not**
  Tailscale — which is why this exists.

## Kill-switch mechanism

Daemon-independent kernel **policy routing**: an `ip rule` at priority **5280** points at a
table containing only `unreachable default` (plus the IPv6 equivalent), sitting **below**
Tailscale's own rule. A healthy tunnel matches its rule first and carries the traffic; on a
drop, traffic falls through to the dead-end and stops. Because it lives in the routing table,
it survives a `tailscaled` crash — it does not depend on the daemon being alive.

> **Verify the real Tailscale rule priority/fwmark on your version** with
> `ip rule show | sort -n` — do not assume a fixed value. The dead-end (5280) must sit
> *below* Tailscale's rule so the healthy tunnel always wins.

Belt-and-suspenders alongside the route rule: `ip6tables -I FORWARD 1 -o <WAN> -j DROP`,
multicast/broadcast drops toward the WAN, and IPv6 disabled on the WAN interface via sysctl.

## Top risks and how each is handled

1. **Key expiry (~180d)** silently kills the exit node mid-use → permanent blackout.
   *Mitigation:* disable key expiry on the exit node **and** the router in the admin console.
2. **Boot race / restart gap** — WAN comes up before the kill switch exists.
   *Mitigation:* `init.d` START=05 pre-network `apply`, **plus** re-arm on every WAN `ifup`
   via hotplug, **plus** a 5-minute self-heal cron. Rule 5280 is never absent while WAN is up.
3. **Established-flow bypass** — open connections keep flowing after a drop (conntrack
   fast-path). *Mitigation:* `conntrack -F` on every state change. Residual: a few-second
   window can exist on a sudden tunnel death before flows are flushed (see residuals).
4. **DNS leak** — a non-tunnel resolver answers queries. *Mitigation:*
   `tailscale set --accept-dns=true`; verify `resolv.conf` = `100.100.100.100`.
5. **IPv6 via SLAAC / rogue RA** despite UCI `ipv6=0` (which only kills DHCPv6).
   *Mitigation:* kernel `disable_ipv6=1` + `accept_ra=0` on the WAN via sysctl + hotplug, a
   v6 dead-end rule, and an `ip6tables FORWARD -o <WAN> DROP` belt.
6. **Firmware update wipes custom scripts.** *Mitigation:* every file is added to
   `/etc/sysupgrade.conf`; master copies live in this repo; re-run `deploy.sh` and re-verify
   after any update. Disable auto-upgrade.
7. **Toggle TOCTOU half-state.** *Mitigation:* a single atomic `flock`-guarded script with
   strict ordering and an EXIT trap that always lands in a safe state.

## Toggle design (`/usr/bin/killswitch`, flock-guarded, EXIT-trap → safe state)

- **ON** (fail = outage, never leak): `conntrack -F` → install the kill switch **first**
  (rules + `state=on`) → `tailscale set --exit-node=<IP> --exit-node-allow-lan-access=true
  --accept-dns=true` → poll until the exit node is active. The EXIT trap re-arms the kill
  switch if the script dies partway, so an abnormal death leaves you in *outage*, never *leak*.
- **OFF** (fail = brief leak, never lockout): remove the kill switch **first** (rules +
  `state=off`, plus a main-table bypass that routes *around* Tailscale's stuck
  `RouteAll`/table-52, which otherwise black-holes traffic once the exit node is cleared) →
  `conntrack -F` → `tailscale set --exit-node=`.
- **apply**: re-assert whichever rule set matches the persisted state. Used by boot, hotplug,
  and the self-heal cron — one code path, no drift.

Same script drives both the physical slide switch (`/etc/gl-switch.d/killswitch.sh`, with a
pre-flight clearnet probe that refuses ON behind an un-authed captive portal so you can't lock
yourself out) and the web CGI (`?token=<secret>&mode=on|off`). The token blocks casual LAN
CSRF; `flock` prevents concurrent runs.

## Captive portals

The kill switch blocks the portal page when ON. Two ways through:

- **Preferred:** complete the portal login from the router itself while the switch stays ON
  (a temporary FORWARD allow to just the portal host; clients stay blocked).
- **Fallback:** toggle OFF, log in with a personal browser, confirm internet, toggle ON, and
  verify your egress IP is the exit node before trusting it again.

The web CGI is reachable on the LAN even with the WAN down, so it's also your recovery path.

## Residual risks (accept these)

- **Device-level telemetry is a different layer.** IP routing cannot change what an endpoint
  reports about itself (timezone, locale, nearby Wi-Fi/BSSID geolocation, GPS, managed-device
  agents). If hiding location is your goal, the device matters as much as the IP.
- **Established-flow gap:** a few-second leak window can exist on an *unexpected* tunnel drop
  before conntrack is flushed.
- **Latency/RTT:** routing through a distant exit node adds round-trip time; avoid real-time
  apps if that matters.
- **Exit-node IP rotation:** if your home ISP rotates the exit node's public IP, your egress
  IP changes too — monitor via DDNS if you depend on a stable value.
- **Local-network visibility:** DERP SNI / UDP-41641 make "this device uses a VPN/mesh"
  visible to the local network operator (not your traffic, just the fact of it).

## Verification checklist (run before trusting it)

1. **Baseline (ON):** a client's `curl ifconfig.me` = the exit node's IP;
   `tailscale status` shows the exit node active/direct.
2. **DNS:** `dnsleaktest.com` + `dig +short myip.opendns.com @resolver1.opendns.com` show
   only the exit node's network; router `resolv.conf` = `100.100.100.100`.
3. **IPv6:** `test-ipv6.com` shows no v6; `ip -6 addr show <WAN>` has no global address;
   `ip -6 rule` has 5280.
4. **WebRTC:** `browserleaks.com/webrtc` srflx = exit node only.
5. **Rule state:** `ip rule show | sort -n` — 5280 present, below Tailscale's rule.
6. **Active kill test:** `killswitch-test` — drops the tunnel; new connections MUST fail (no
   fallthrough); `tcpdump` on the WAN shows ZERO clearnet egress; conntrack is flushed;
   restart recovers.
7. **Reboot test (boot-race proof):** with `state=on`, reboot; an upstream capture shows ZERO
   clearnet packets at any point; after boot the exit-node IP returns; 5280 present from
   WAN-up.
8. **Toggle test:** slide ON→OFF→ON and via CGI; verify each state; confirm `flock` blocks a
   double-run; confirm half-state recovery (kill mid-ON → kill switch stays; mid-OFF → no
   stranded lockout).
9. **Captive-portal dry run**, and re-verify everything after any firmware update.
