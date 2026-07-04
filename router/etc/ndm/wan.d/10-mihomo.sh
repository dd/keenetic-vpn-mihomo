#!/bin/sh
# /opt/etc/ndm/wan.d/10-mihomo.sh
# NDM runs wan.d/ scripts with $1=start|stop on internet connection changes.
# On WAN up, re-assert our policy routing (idempotent) in case the kernel/NDM
# rebuilt routing during the reconnect. Must be fast (NDM timeout is 24s).

PIDFILE=/opt/var/run/mihomo.pid

[ "$1" = "start" ] || exit 0

# only act if mihomo is actually running
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    /opt/bin/te-vpn route add >/dev/null 2>&1
    logger -t te-vpn "wan.d hook: reapplied routing (iface=${interface:-?} gw=${gateway:-?})"
fi
exit 0
