# tailscale-exit-killswitch

A **fail-closed kill switch** that forces all traffic behind a GL.iNet / OpenWrt router
through a chosen **Tailscale exit node**. If the tunnel or the exit node goes down, the
router's internet **stops** instead of falling back to the bare WAN — so the upstream
network never sees your real WAN IP, not even for a moment.

Every device you plug into the router (or join its Wi-Fi) inherits this automatically,
with no client software. A physical slide switch and a phone-friendly web page let you
flip it off for captive-portal logins and back on in a couple of taps.

> **Why fail-closed?** A normal VPN/exit-node setup leaks: when the tunnel drops, the OS
> happily routes around it over the bare WAN until something reconnects. This project makes
> the *absence* of the tunnel mean *no internet*, enforced in the kernel routing table
> below Tailscale's own rule, so it survives even a `tailscaled` crash.

## What it is good for

- Putting a travel router on an untrusted hotel/café/airport network and guaranteeing all
  your traffic exits from a trusted home/server location, with zero-leak if it drops.
- Giving a whole LAN segment a single, enforced egress point without configuring each device.
- A hardened reference for "exit-node-or-nothing" routing on OpenWrt.

## What it does NOT do (honest scope)

- It enforces **IP-level** egress. It cannot change what an *application or device* reports
  out-of-band (timezone, locale, GPS, telemetry from managed-device agents). IP routing and
  device fingerprint are different layers.
- Routing through a distant exit node adds latency (RTT). Expect a hit on real-time apps.
- It is not a substitute for endpoint security on the clients behind it.

## Requirements

- A **GL.iNet** router (developed on a GL-MT3600BE / "Beryl 7", GL.iNet 4.x / OpenWrt 21.02,
  firewall backend **fw3 / iptables**). Should adapt to other OpenWrt fw3 devices; the
  physical-switch binding is GL.iNet-specific.
- **Tailscale installed and logged in on the router**, with `NetfilterMode=2` (Tailscale owns
  its `ts-*` chains). GL.iNet ships a Tailscale plugin; or install the OpenWrt package.
- An **always-on exit node** on your tailnet (a home server, Mac/Linux box, Pi, etc.) already
  advertising itself: `tailscale up --advertise-exit-node`, approved in the admin console.
- `conntrack`, `ip`, `ip6tables` present (standard on these images).

> **Disable Tailscale key expiry** on *both* the router and the exit node in the admin
> console. Otherwise a key expires mid-trip and the kill switch turns into a permanent
> blackout (fail-closed, as designed — but you won't be able to fix it remotely).

## Install

```sh
git clone <this-repo> tailscale-exit-killswitch
cd tailscale-exit-killswitch
cp config.env.example config.env
$EDITOR config.env          # set ROUTER, EXIT_NODE, WAN_IF
sh deploy.sh
```

`deploy.sh` is idempotent — re-run it any time (e.g. after a firmware update) to restore
every file. It generates a random web token on-device on first run and prints it.

## Operate

| Action | How |
|---|---|
| Physical toggle | Slide switch: **ON** = enforced via exit node, **OFF** = local internet |
| Phone / browser | `http://<LAN_IP>:8090/cgi-bin/killswitch?token=<TOKEN>` (token printed by deploy) |
| SSH | `ssh root@<router> killswitch on` / `off` / `status` |

**Joining a new network (hotel/café):** the kill switch blocks the captive-portal page when
ON, so go **OFF** first, complete the portal login, confirm you have internet, then flip
**ON** and confirm your egress IP is the exit node before trusting it.

## Verify it actually fails closed

```sh
ssh root@<router> killswitch-test   # then: cat /tmp/killswitch-test.log
```

This drops the tunnel and proves, with `tcpdump` on the WAN, that **zero** clearnet packets
leak while it's down — then auto-restores. Also worth checking manually:

- Egress IP (`ifconfig.me`) = the exit node's IP, on ON.
- DNS: `dnsleaktest.com` shows only the exit node's network; router `resolv.conf` =
  `100.100.100.100`.
- IPv6: `test-ipv6.com` shows no v6 leak.
- `ip rule show | sort -n` — rule `5280` (the dead-end) is present and **below** Tailscale's
  own rule when ON.

See [DESIGN.md](DESIGN.md) for the full mechanism, the boot-race / hotplug / self-heal
hardening, and the complete verification checklist. [CHEATSHEET.md](CHEATSHEET.md) is the
one-page day-to-day operating guide.

## How it works (one paragraph)

A kernel policy-routing rule at priority `5280` points at an `unreachable` dead-end,
installed **below** Tailscale's own routing rule. A healthy tunnel grabs traffic first; if it
drops, traffic falls through to the dead-end and stops — it can never reach the WAN default
route. The rule is re-asserted pre-network on boot (`init.d` START=05), on every WAN `ifup`
(hotplug), and every 5 minutes (cron self-heal), so it is never absent while the WAN is up.
IPv6 is locked down in parallel (sysctl + a v6 dead-end + an `ip6tables` belt). Turning it
**off** removes the dead-end and adds a main-table bypass so traffic routes normally again.

## License

MIT — see [LICENSE](LICENSE).
