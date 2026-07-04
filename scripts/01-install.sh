#!/bin/sh
# 01-install.sh — Phase 1 (NON-disruptive): install mihomo + deploy the router/ tree.
# Nothing is cut over here: routing is untouched, mihomo is not started.
# Safe to re-run: an existing /opt/etc/mihomo/config.yaml (with your subscription)
# is preserved — the repo version is pushed as config.yaml.new instead.
#
# Usage:  sh scripts/01-install.sh
#         ROUTER=root@10.0.0.1 PORT=22 sh scripts/01-install.sh   # override target
set -e

ROUTER="${ROUTER:-root@192.168.1.1}"
PORT="${PORT:-222}"
R="ssh -o ConnectTimeout=10 -p $PORT $ROUTER"

HERE=$(cd "$(dirname "$0")" && pwd)
TREE="$HERE/../router"

MIHOMO_VER="v1.19.27"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-arm64-${MIHOMO_VER}.gz"
UI_URL="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz"

echo ">> Creating directories"
$R 'mkdir -p /opt/etc/mihomo/providers /opt/share/mihomo/ui /opt/var/run /opt/var/log /opt/bin /opt/etc/monit.d /opt/etc/ndm/wan.d'

echo ">> Downloading mihomo ${MIHOMO_VER} (arm64) on the router"
$R "curl -fsSL '${MIHOMO_URL}' -o /tmp/mihomo.gz && gunzip -f /tmp/mihomo.gz && mv /tmp/mihomo /opt/sbin/mihomo && chmod +x /opt/sbin/mihomo && /opt/sbin/mihomo -v | head -1"

echo ">> Downloading metacubexd web UI"
$R "curl -fsSL '${UI_URL}' -o /tmp/ui.tgz && tar xzf /tmp/ui.tgz -C /opt/share/mihomo/ui --strip-components=1 && rm -f /tmp/ui.tgz && echo UI files: \$(ls /opt/share/mihomo/ui | wc -l)"

echo ">> Deploying router/ tree -> /opt"
if $R 'test -f /opt/etc/mihomo/config.yaml'; then
    echo "   config.yaml already on the router — keeping it, repo copy goes to config.yaml.new"
    tar -C "$TREE" --exclude './etc/mihomo/config.yaml' -cf - . | $R 'tar -C /opt -xf -'
    $R 'cat > /opt/etc/mihomo/config.yaml.new' < "$TREE/etc/mihomo/config.yaml"
else
    tar -C "$TREE" -cf - . | $R 'tar -C /opt -xf -'
fi

echo ">> Setting permissions"
$R 'chmod +x /opt/bin/mihomo-route /opt/bin/vpn /opt/etc/ndm/wan.d/10-mihomo.sh /opt/etc/init.d/S06mihomo'

echo ">> Validating mihomo config"
$R '/opt/sbin/mihomo -t -d /opt/etc/mihomo' || {
    echo "!! config validation FAILED — fix before cutover"; exit 1; }

echo
echo "Phase 1 done. Nothing was started or rerouted."
echo "Next:"
echo "  1) cut over:                 sh scripts/02-cutover.sh"
echo "  2) set your subscription:    $R 'vpn sub \"https://your-sub-url\"'"
