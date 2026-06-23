# Cheatsheet

One-page day-to-day operation. `<LAN_IP>` is your router's LAN address (GL.iNet default
`192.168.8.1`); `<router>` is its LAN or Tailscale address; `<TOKEN>` was printed by `deploy.sh`.

---

## The toggle

| Physical switch | State | Meaning |
|---|---|---|
| **ON**  | Enforced  | All traffic exits via the Tailscale exit node. Tunnel drops → internet dies (no leak). |
| **OFF** | Local     | Straight out the local WAN. Use for captive-portal login / normal internet. |

Phone/browser toggle (same effect):
`http://<LAN_IP>:8090/cgi-bin/killswitch?token=<TOKEN>`

SSH status check:
`ssh root@<router> killswitch status`   → `egress=<exit-node IP>` means it's working.

---

## Connecting to a NEW network (hotel / café / airport) — every time

The kill switch blocks the captive-portal page when ON, so always go OFF first:

1. Switch **OFF**.
2. Browser → `http://<LAN_IP>` (GL.iNet admin) → **Internet** → join the Wi-Fi (Repeater)
   or plug in Ethernet.
3. Complete the captive-portal login; confirm you have internet.
4. Switch **ON**.
5. Confirm egress before trusting it: open `https://ifconfig.me` → must show the **exit
   node's IP**.

If step 5 isn't the exit node's IP → stay off, recheck `killswitch status` / the tunnel.

---

## Daily checks

- [ ] Switch is **ON**.
- [ ] `ifconfig.me` = the exit node's IP.
- [ ] No DNS leak: `dnsleaktest.com` shows only the exit node's network.
- [ ] No IPv6 leak: `test-ipv6.com` shows no v6.

---

## If something breaks

- No internet when OFF: `ssh root@<router> killswitch off` (re-applies the WAN bypass).
- Stuck / half state: `ssh root@<router> killswitch apply` (re-asserts the persisted state).
- Self-heal cron runs every 5 min; `init.d` re-arms on boot; rules survive firmware "keep
  settings".
- Full re-deploy (e.g. after a firmware wipe): re-run `sh deploy.sh` from this repo.

---

## Note on scope

This enforces **IP-level** egress. It does not change what a *device or app* reports about
itself out-of-band (timezone, locale, nearby-Wi-Fi geolocation, GPS, managed-device agents).
If your goal involves location privacy, the device settings matter as much as the IP — see
the "Residual risks" section of [DESIGN.md](DESIGN.md).
