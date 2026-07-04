#!/bin/sh
# install.sh — self-contained install of the mihomo VPN stack on any Keenetic
# (or other Entware) router. Everything the stack needs is installed here.
#
# What it does, over SSH:
#   1. installs missing dependencies via opkg (curl, iptables, monit)
#   2. detects the router CPU arch and downloads the matching mihomo binary
#   3. downloads the metacubexd web UI
#   4. deploys the router/ tree to /opt (preserving an existing config.yaml,
#      vpn.conf and devices.list — repo versions land as *.new)
#   5. creates the Keenetic access policy "$POLICY_NAME" so devices can be
#      routed into the VPN straight from the web UI
#   6. validates the config and starts mihomo under monit supervision
#
# Safe to re-run (idempotent, acts as an updater).
#
# Usage:  sh scripts/install.sh
#         ROUTER=root@10.0.0.1 PORT=22 sh scripts/install.sh   # another router
#         POLICY_NAME=MyVPN sh scripts/install.sh              # policy name
#         WAN_IF=PPPoE0 sh scripts/install.sh                  # non-default WAN
#         NO_POLICY=1 sh scripts/install.sh                    # devices.list only
#         NO_MONIT=1 sh scripts/install.sh                     # skip monit
#         NO_START=1 sh scripts/install.sh                     # deploy only
set -e

ROUTER="${ROUTER:-root@192.168.1.1}"
PORT="${PORT:-222}"
POLICY_NAME="${POLICY_NAME:-Mihomo}"
WAN_IF="${WAN_IF:-ISP}"
R="ssh -o ConnectTimeout=10 -p $PORT $ROUTER"

HERE=$(cd "$(dirname "$0")" && pwd)
TREE="$HERE/../router"

MIHOMO_VER="v1.19.27"
UI_URL="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz"

echo ">> Checking the router is reachable"
$R 'echo "  $(cat /proc/version 2>/dev/null | cut -c1-60)"'

echo ">> Detecting CPU architecture"
ARCH=$($R 'uname -m')
case "$ARCH" in
    aarch64)        MARCH=arm64 ;;
    armv7*)         MARCH=armv7 ;;
    armv5*)         MARCH=armv5 ;;
    mips)           MARCH=mips-softfloat ;;
    mipsel|mipsle)  MARCH=mipsle-softfloat ;;
    x86_64)         MARCH=amd64 ;;
    *) echo "!! unsupported arch: $ARCH — pick a build at https://github.com/MetaCubeX/mihomo/releases"; exit 1 ;;
esac
echo "   $ARCH -> mihomo-linux-${MARCH}"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-${MARCH}-${MIHOMO_VER}.gz"

echo ">> Installing dependencies (opkg)"
WANT="curl iptables"
[ -z "${NO_MONIT:-}" ] && WANT="$WANT monit"
$R 'need=""
    for p in '"$WANT"'; do command -v "$p" >/dev/null || need="$need $p"; done
    if [ -n "$need" ]; then
        echo "   installing:$need"; opkg update >/dev/null && opkg install $need
    else
        echo "   all present"
    fi'

echo ">> Creating directories"
$R 'mkdir -p /opt/sbin /opt/bin /opt/etc/mihomo/providers /opt/share/mihomo/ui \
             /opt/var/run /opt/var/log /opt/etc/monit.d \
             /opt/etc/ndm/wan.d /opt/etc/ndm/netfilter.d'

echo ">> Downloading mihomo ${MIHOMO_VER} (${MARCH}) on the router"
$R "curl -fsSL '${MIHOMO_URL}' -o /tmp/mihomo.gz && gunzip -f /tmp/mihomo.gz && mv /tmp/mihomo /opt/sbin/mihomo && chmod +x /opt/sbin/mihomo && /opt/sbin/mihomo -v | head -1"

echo ">> Downloading metacubexd web UI"
$R "curl -fsSL '${UI_URL}' -o /tmp/ui.tgz && tar xzf /tmp/ui.tgz -C /opt/share/mihomo/ui --strip-components=1 && rm -f /tmp/ui.tgz && echo \"   UI files: \$(ls /opt/share/mihomo/ui | wc -l)\""

echo ">> Deploying router/ tree -> /opt"
# Live files that may carry local state (subscription, device list, marks)
# are never overwritten: the repo version goes to <file>.new instead.
KEEP=""
for f in etc/mihomo/config.yaml etc/mihomo/vpn.conf etc/mihomo/devices.list; do
    if $R "test -f /opt/$f"; then
        echo "   /opt/$f exists — keeping it, repo copy goes to $f.new"
        KEEP="$KEEP --exclude=./$f"
        $R "cat > /opt/$f.new" < "$TREE/$f"
    fi
done
# shellcheck disable=SC2086
tar -C "$TREE" $KEEP -cf - . | $R 'tar -C /opt -xf -'

echo ">> Setting permissions"
$R 'chmod +x /opt/bin/mihomo-route /opt/bin/te-vpn /opt/etc/init.d/S06mihomo \
             /opt/etc/ndm/wan.d/10-mihomo.sh /opt/etc/ndm/netfilter.d/50-mihomo.sh'

if [ -z "${NO_POLICY:-}" ]; then
    echo ">> Ensuring Keenetic access policy \"$POLICY_NAME\" exists"
    # The policy is how devices are put on the VPN from the web UI: the
    # firmware connmarks its members, mihomo-route picks that mark up by name.
    # 'permit global $WAN_IF' fills the policy's own routing table with a
    # default route -> if mihomo is down, member devices fall back to direct.
    $R "if ! command -v ndmc >/dev/null 2>&1; then
            echo '   ndmc not found (not a Keenetic?) — skipping, use: te-vpn add'
        elif ndmc -c 'show ip policy' 2>/dev/null | grep -q 'name = $POLICY_NAME,'; then
            echo '   already exists'
        else
            ndmc -c 'ip policy $POLICY_NAME'
            ndmc -c 'ip policy $POLICY_NAME description $POLICY_NAME'
            ndmc -c 'ip policy $POLICY_NAME permit global $WAN_IF' \
                || echo \"   WARN: 'permit global $WAN_IF' failed — set WAN_IF to your WAN connection name\"
            ndmc -c 'system configuration save'
            echo '   created (assign devices to it in the web UI)'
        fi"
    # keep the live vpn.conf pointed at this policy (also upgrades old installs)
    $R "grep -q '^POLICY_NAME=' /opt/etc/mihomo/vpn.conf 2>/dev/null \
            && sed -i 's/^POLICY_NAME=.*/POLICY_NAME=$POLICY_NAME/' /opt/etc/mihomo/vpn.conf \
            || printf '\nPOLICY_NAME=%s\n' '$POLICY_NAME' >> /opt/etc/mihomo/vpn.conf"
else
    $R "sed -i 's/^POLICY_NAME=.*/POLICY_NAME=/' /opt/etc/mihomo/vpn.conf 2>/dev/null || true"
fi

if [ -z "${NO_MONIT:-}" ]; then
    echo ">> Wiring monit"
    $R 'grep -q "/opt/etc/monit.d" /opt/etc/monitrc 2>/dev/null || \
        printf "\ninclude /opt/etc/monit.d/*.conf\n" >> /opt/etc/monitrc
        pidof monit >/dev/null 2>&1 && monit reload 2>/dev/null || \
        /opt/etc/init.d/S99monit start 2>/dev/null || true'
fi

echo ">> Validating mihomo config"
$R '/opt/sbin/mihomo -t -d /opt/etc/mihomo' || {
    echo "!! config validation FAILED — fix /opt/etc/mihomo/config.yaml"; exit 1; }

if [ -z "${NO_START:-}" ]; then
    echo ">> Starting mihomo"
    $R '/opt/bin/te-vpn restart'
    sleep 3
    echo
    echo ">> Status:"
    $R '/opt/bin/te-vpn status'
fi

echo
echo "Install done. Next steps (on the router or via ssh):"
echo "  1) subscription:   te-vpn sub \"https://your-subscription-url\""
echo "  2) add devices:    te-vpn add <mac-or-ip> [comment]"
echo "  3) pick a server:  te-vpn servers && te-vpn select \"<name>\"   (or: te-vpn auto)"
