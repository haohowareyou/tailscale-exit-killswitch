#!/bin/sh
# Physical slide-switch handler. GL.iNet's /etc/rc.button/switch calls this with on|off
# depending on the slide position (pressed=on, released=off).
# Bound via: uci set switch-button.@main[0].func='killswitch'
logger -t killswitch-switch "slide -> $1"
case "$1" in
  on)
    # Pre-flight: if there's no clearnet right now (e.g. behind an un-authed captive
    # portal), refuse ON so the kill switch can't lock you out. Log in first, then flip.
    if ! curl -s --max-time 5 -o /dev/null http://connectivitycheck.gstatic.com/generate_204 2>/dev/null \
       && ! curl -s --max-time 5 -o /dev/null http://1.1.1.1 2>/dev/null; then
      logger -t killswitch-switch "no clearnet (captive portal?) — staying OFF to avoid lockout"
      exit 0
    fi
    /usr/bin/killswitch on
    ;;
  off) /usr/bin/killswitch off ;;
  *) exit 0 ;;
esac
