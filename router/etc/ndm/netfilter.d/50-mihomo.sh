#!/bin/sh
# /opt/etc/ndm/netfilter.d/50-mihomo.sh
# NDM rebuilds the firewall on config changes / reconnects and then runs
# netfilter.d hooks with $type (iptables/ip6tables) and $table set.
# Our device-marking chain lives in mangle — re-apply it after each rebuild.
# Must be fast (NDM timeout): sync only, no waiting.

[ "$type" = "ip6tables" ] && exit 0
[ "$table" = "mangle" ] || exit 0

PIDFILE=/opt/var/run/mihomo.pid
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    /opt/bin/te-vpn route sync >/dev/null 2>&1
fi
exit 0
