#!/bin/sh
# Deploy/refresh the Tailscale exit-node kill switch onto a GL.iNet / OpenWrt router.
# Idempotent & re-runnable (e.g. after a firmware update). Run from your home box (the
# machine that hosts the Tailscale exit node) or any machine that can SSH to the router.
#
# Configure by editing config.env (copy from config.env.example) OR via env vars:
#   ROUTER     ssh target for the router, e.g. root@192.168.8.1 or root@<tailnet-ip>
#   EXIT_NODE  Tailscale IP of the exit node all traffic should route through
#   WAN_IF     router's WAN interface (default eth0)
#
# -O on scp forces legacy protocol (dropbear has no sftp-server).
set -e
cd "$(dirname "$0")"
[ -f config.env ] && . ./config.env
: "${ROUTER:?set ROUTER (e.g. root@192.168.8.1) in config.env or the environment}"
: "${EXIT_NODE:?set EXIT_NODE (the exit node's Tailscale IP) in config.env or the environment}"
WAN_IF="${WAN_IF:-eth0}"
H="$ROUTER"
D="$(pwd)/router"

ssh "$H" 'mkdir -p /etc/hotplug.d/iface /etc/gl-switch.d /etc/killswitch-web/cgi-bin'
scp -O "$D/usr/bin/killswitch"                  "$H:/usr/bin/killswitch"
scp -O "$D/usr/bin/killswitch-heal"             "$H:/usr/bin/killswitch-heal"
scp -O "$D/usr/bin/killswitch-test"             "$H:/usr/bin/killswitch-test"
scp -O "$D/etc/hotplug.d/iface/05-killswitch"   "$H:/etc/hotplug.d/iface/05-killswitch"
scp -O "$D/etc/init.d/killswitch-boot"          "$H:/etc/init.d/killswitch-boot"
scp -O "$D/etc/init.d/killswitch-web"           "$H:/etc/init.d/killswitch-web"
scp -O "$D/etc/gl-switch.d/killswitch.sh"       "$H:/etc/gl-switch.d/killswitch.sh"
scp -O "$D/etc/killswitch-web/cgi-bin/killswitch" "$H:/etc/killswitch-web/cgi-bin/killswitch"

ssh "$H" "EXIT_NODE='$EXIT_NODE' WAN_IF='$WAN_IF' sh -s" <<'REMOTE'
set -e
chmod +x /usr/bin/killswitch /usr/bin/killswitch-heal /usr/bin/killswitch-test \
         /etc/hotplug.d/iface/05-killswitch /etc/init.d/killswitch-boot \
         /etc/init.d/killswitch-web /etc/gl-switch.d/killswitch.sh \
         /etc/killswitch-web/cgi-bin/killswitch

# config: exit node + WAN interface + a stable random token. Only create if absent.
if [ ! -f /etc/killswitch.conf ]; then
  printf 'EXIT_NODE=%s\nWAN_IF=%s\nTOKEN=%s\n' \
    "$EXIT_NODE" "$WAN_IF" "$(head -c64 /dev/urandom | md5sum | cut -c1-24)" > /etc/killswitch.conf
fi
[ -f /etc/killswitch.state ] || echo on > /etc/killswitch.state

# boot persistence + web instance
/etc/init.d/killswitch-boot enable
/etc/init.d/killswitch-web enable
/etc/init.d/killswitch-web restart >/dev/null 2>&1 || /etc/init.d/killswitch-web start

# bind the physical slide switch to our handler (GL.iNet only)
uci set switch-button.@main[0].func=killswitch 2>/dev/null && uci commit switch-button || true

# cron self-heal every 5 min
touch /etc/crontabs/root
grep -q killswitch-heal /etc/crontabs/root || echo "*/5 * * * * /usr/bin/killswitch-heal" >> /etc/crontabs/root
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true

# survive firmware "keep settings" updates
for f in /usr/bin/killswitch /usr/bin/killswitch-heal /usr/bin/killswitch-test \
         /etc/hotplug.d/iface/05-killswitch /etc/init.d/killswitch-boot \
         /etc/init.d/killswitch-web /etc/gl-switch.d/killswitch.sh \
         /etc/killswitch-web/cgi-bin/killswitch /etc/killswitch.conf /etc/killswitch.state; do
  grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
done

echo "=== deployed ==="
echo "token (bookmark http://<LAN_IP>:8090/cgi-bin/killswitch?token=...): $(grep TOKEN /etc/killswitch.conf)"
echo "switch func: $(uci -q get switch-button.@main[0].func)"
echo "web: $(netstat -tlnp 2>/dev/null | grep 8090 | head -1 || echo NOT-LISTENING)"
/usr/bin/killswitch status
REMOTE
