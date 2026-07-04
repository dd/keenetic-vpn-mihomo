#!/bin/sh
# /opt/etc/ndm/wan.d/10-mihomo.sh
# NDM runs wan.d/ scripts with $1=start|stop on internet connection changes.
# Must be instant (NDM timeout is 24s — no sleeps that can stall).
#
# On WAN up we re-assert our policy route (idempotent) in case the kernel/NDM
# rebuilt routing during the reconnect, and nudge mihomo to re-detect its
# outbound interface.

PIDFILE=/opt/var/run/mihomo.pid

[ "$1" = "start" ] || exit 0

# only act if mihomo is actually running
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    /opt/bin/mihomo-route add >/dev/null 2>&1
    logger -t mihomo "wan.d hook: reapplied routing (iface=${interface:-?} gw=${gateway:-?})"
fi
exit 0
