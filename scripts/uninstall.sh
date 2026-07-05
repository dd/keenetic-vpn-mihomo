#!/bin/sh
# uninstall.sh — remove the mihomo VPN stack from the router.
# Routing/marking is torn down first, so devices fall back to direct internet.
# Config with your subscription and device list (/opt/etc/mihomo) is KEPT
# unless you set PURGE=1.
#
# Usage:  sh scripts/uninstall.sh
#         PURGE=1 sh scripts/uninstall.sh    # also delete config + logs
set -e

ROUTER="${ROUTER:-root@192.168.1.1}"
PORT="${PORT:-222}"
R="ssh -o ConnectTimeout=10 -p $PORT $ROUTER"

echo ">> Stopping + un-supervising mihomo"
$R 'command -v monit >/dev/null && monit unmonitor mihomo 2>/dev/null; true'
$R '/opt/bin/te-vpn down 2>/dev/null || true'
$R '/opt/bin/te-vpn route del 2>/dev/null || true'

echo ">> Removing the Keenetic access policy (its devices revert to default internet)"
$R 'PN=$(sed -n "s/^POLICY_NAME=//p" /opt/etc/mihomo/te-vpn.conf 2>/dev/null | head -1)
    if [ -n "$PN" ] && command -v ndmc >/dev/null 2>&1; then
        ndmc -c "no ip policy $PN" 2>/dev/null && ndmc -c "system configuration save" >/dev/null 2>&1
        echo "   removed: $PN"
    else
        echo "   (none configured)"
    fi'

echo ">> Removing files"
$R 'rm -f /opt/sbin/mihomo /opt/bin/te-vpn \
          /opt/etc/init.d/S06mihomo /opt/etc/monit.d/mihomo.conf \
          /opt/etc/ndm/wan.d/10-mihomo.sh /opt/etc/ndm/netfilter.d/50-mihomo.sh \
          /opt/var/run/te-vpn.policy_mark /opt/var/run/te-vpn.conntrack_flush
    rm -rf /opt/etc/mihomo/ui /opt/share/mihomo'
$R 'command -v monit >/dev/null && monit reload 2>/dev/null; true'

if [ -n "${PURGE:-}" ]; then
    echo ">> PURGE=1: removing config, subscription cache and logs"
    $R 'rm -rf /opt/etc/mihomo /opt/var/log/mihomo.log /opt/var/run/mihomo.pid'
else
    echo ">> Keeping /opt/etc/mihomo (config, subscription, device list)."
    echo "   Delete later with PURGE=1, or re-run install.sh to reuse it."
fi

echo
echo "Uninstalled. Devices route directly again."
