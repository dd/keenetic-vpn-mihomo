#!/bin/sh
# 02-cutover.sh — Phase 3: disable spider (reversibly) and bring mihomo up.
# Reversible: spider binaries/configs are kept; only autostart is disabled.
# Run:  sh scripts/02-cutover.sh
set -e

ROUTER="${ROUTER:-root@192.168.1.1}"
PORT="${PORT:-222}"
R="ssh -o ConnectTimeout=10 -p $PORT $ROUTER"

echo ">> Stopping + un-supervising spider"
$R 'monit unmonitor spider 2>/dev/null || true; spd stop 2>/dev/null || true'

echo ">> Disabling spider autostart (reversible)"
$R 'chmod -x /opt/etc/init.d/S05spider 2>/dev/null || true'                 # boot
$R 'mv -f /opt/etc/monit.d/spider.conf /opt/etc/monit.d/spider.conf.disabled 2>/dev/null || true'  # monit
$R 'chmod -x /opt/etc/ndm/netfilter.d/99-spider.sh /opt/etc/ndm/wan.d/10-spider.sh 2>/dev/null || true'  # ndm hooks

echo ">> Reloading monit (drop spider, pick up mihomo)"
$R 'monit reload 2>/dev/null || /opt/etc/init.d/S99monit restart 2>/dev/null || true; sleep 2'

echo ">> Verifying spider firewall is gone"
$R 'iptables -t nat -S 2>/dev/null | grep -i spider && echo "WARN: SPIDER nat rules still present" || echo "  nat: clean"'

echo ">> Starting mihomo"
$R 'vpn start'
sleep 3

echo ">> Letting monit adopt mihomo"
$R 'monit monitor mihomo 2>/dev/null || true'

echo
echo ">> Status:"
$R 'vpn status'

echo
echo "Cutover done. If you haven't set a subscription yet:"
echo "  $R 'vpn sub \"https://your-sub-url\"'"
echo "Then pick a server:  $R 'vpn servers'  /  $R 'vpn select \"<name>\"'"
