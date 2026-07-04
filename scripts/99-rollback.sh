#!/bin/sh
# 99-rollback.sh — undo the cutover: stop mihomo, re-enable the original spider.
# Use if anything goes wrong. Keeps mihomo files in place (just disabled).
# Run:  sh scripts/99-rollback.sh
set -e

ROUTER="${ROUTER:-root@192.168.1.1}"
PORT="${PORT:-222}"
R="ssh -o ConnectTimeout=10 -p $PORT $ROUTER"

echo ">> Stopping + un-supervising mihomo"
$R 'monit unmonitor mihomo 2>/dev/null || true; vpn stop 2>/dev/null || true'
$R 'mv -f /opt/etc/monit.d/mihomo.conf /opt/etc/monit.d/mihomo.conf.disabled 2>/dev/null || true'
$R 'chmod -x /opt/etc/init.d/S06mihomo 2>/dev/null || true'

echo ">> Re-enabling spider"
$R 'chmod +x /opt/etc/init.d/S05spider 2>/dev/null || true'
$R 'mv -f /opt/etc/monit.d/spider.conf.disabled /opt/etc/monit.d/spider.conf 2>/dev/null || true'
$R 'chmod +x /opt/etc/ndm/netfilter.d/99-spider.sh /opt/etc/ndm/wan.d/10-spider.sh 2>/dev/null || true'

echo ">> Reloading monit + starting spider"
$R 'monit reload 2>/dev/null || /opt/etc/init.d/S99monit restart 2>/dev/null || true; sleep 2; spd start'
sleep 2
$R 'spd status'

echo
echo "Rolled back to spider. To re-enable mihomo later: re-run 02-cutover.sh"
