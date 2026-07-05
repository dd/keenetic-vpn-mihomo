#!/bin/sh
# install.sh — self-contained install of the mihomo VPN stack on any Keenetic
# (or other Entware) router. Everything the stack needs is installed here.
#
# What it does, over SSH:
#   1. installs missing dependencies via opkg (curl, iptables, monit)
#   2. detects the router CPU arch and downloads the matching mihomo binary
#   3. downloads the metacubexd web UI
#   4. deploys the router/ tree to /opt (preserving local te-vpn.conf and
#      devices.list; config.yaml keeps subscription/local settings but is
#      upgraded in-place for the current transparent-proxy mode)
#   5. creates the Keenetic access policy "$POLICY_NAME" so devices can be
#      routed into the VPN straight from the web UI
#   6. validates the config and starts mihomo under monit supervision
#
# Safe to re-run (idempotent, acts as an updater).
#
# Usage:  sh scripts/install.sh
#         ROUTER=root@10.0.0.1 PORT=22 sh scripts/install.sh   # another router
#         POLICY_NAME=MyVPN sh scripts/install.sh              # policy name
#         WAN_IF=PPPoE0 sh scripts/install.sh                  # WAN fallback if auto-detect fails
#         NO_POLICY=1 sh scripts/install.sh                    # devices.list only
#         NO_MONIT=1 sh scripts/install.sh                     # skip monit
#         NO_START=1 sh scripts/install.sh                     # deploy only
set -e

ROUTER="${ROUTER:-root@192.168.1.1}"
PORT="${PORT:-222}"
POLICY_NAME="${POLICY_NAME:-te-vpn}"
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
$R 'mkdir -p /opt/sbin /opt/bin /opt/etc/mihomo/providers \
             /opt/var/run /opt/var/log /opt/etc/monit.d \
             /opt/etc/ndm/wan.d /opt/etc/ndm/netfilter.d'

echo ">> Downloading mihomo ${MIHOMO_VER} (${MARCH}) on the router"
$R "curl -fsSL '${MIHOMO_URL}' -o /tmp/mihomo.gz && gunzip -f /tmp/mihomo.gz && mv /tmp/mihomo /opt/sbin/mihomo && chmod +x /opt/sbin/mihomo && /opt/sbin/mihomo -v | head -1"

echo ">> Downloading metacubexd web UI"
# UI lives under the mihomo working dir (/opt/etc/mihomo) so it passes mihomo's
# external-ui path guard. busybox tar has no --strip-components: extract to a
# temp dir, then move the single top-level dir into place.
$R "curl -fsSL '${UI_URL}' -o /tmp/ui.tgz \
    && rm -rf /tmp/ui-x && mkdir -p /tmp/ui-x && tar xzf /tmp/ui.tgz -C /tmp/ui-x \
    && inner=\$(find /tmp/ui-x -mindepth 1 -maxdepth 1 -type d | head -1) \
    && rm -rf /opt/etc/mihomo/ui && mv \"\$inner\" /opt/etc/mihomo/ui \
    && rm -rf /tmp/ui.tgz /tmp/ui-x \
    && echo \"   UI files: \$(ls /opt/etc/mihomo/ui | wc -l)\""

# Point metacubexd at its own origin by default, so opening the panel needs no
# manual backend setup: mihomo serves the API and UI on one port, so the
# backend is always the host you opened the panel from. Rewritten every install
# because the UI download above replaces config.js with an empty default.
$R "cat > /opt/etc/mihomo/ui/config.js <<'EOF'
window.__METACUBEXD_CONFIG__ = {
  defaultBackendURL: window.location.origin,
}
EOF"

echo ">> Deploying router/ tree -> /opt"
# Live files that may carry local state are not blindly overwritten: the repo
# version goes to <file>.new instead. config.yaml is upgraded in-place below so
# old installs get the current transparent-proxy technical settings while
# keeping their subscription URL.
KEEP=""
for f in etc/mihomo/config.yaml etc/mihomo/te-vpn.conf etc/mihomo/devices.list; do
    if $R "test -f /opt/$f"; then
        echo "   /opt/$f exists — keeping it, repo copy goes to $f.new"
        KEEP="$KEEP --exclude=./$f"
        $R "cat > /opt/$f.new" < "$TREE/$f"
    fi
done
# shellcheck disable=SC2086
tar -C "$TREE" $KEEP -cf - . | $R 'tar -C /opt -xf -'

echo ">> Ensuring live te-vpn settings have current defaults"
$R 'conf=/opt/etc/mihomo/te-vpn.conf
    ensure_setting() {
        key=$1
        val=$2
        grep -q "^$key=" "$conf" 2>/dev/null || printf "%s=%s\n" "$key" "$val" >> "$conf"
    }
    ensure_setting REDIR_PORT 7892
    ensure_setting TPROXY_PORT 7895
    ensure_setting TPROXY_MARK 0x1
    ensure_setting BLOCK_QUIC 1
    ensure_setting CONNTRACK_FLUSH 1
    ensure_setting CONNTRACK_FLUSH_INTERVAL 20'

echo ">> Ensuring live mihomo config matches transparent-proxy mode"
$R 'cat > /tmp/te-vpn-upgrade-config.awk <<'"'"'AWK'"'"'
BEGIN { skip=0; inserted=0 }
/^sniffer:/ { skip=1; next }
skip && /^[^[:space:]]/ { skip=0 }
skip { next }
/^mixed-port:/ {
    print
    print "redir-port: " redir_port "          # TCP transparent proxy entrypoint used by te-vpn"
    print "tproxy-port: " tproxy_port "         # UDP transparent proxy entrypoint used by te-vpn"
    next
}
/^redir-port:/ || /^tproxy-port:/ { next }
/store-fake-ip:/ { print "  store-fake-ip: false"; next }
!inserted && /^tun:/ {
    print "# --- Sniffing ---------------------------------------------------------------"
    print "# Transparent proxy gives mihomo the original IP. Sniffing recovers HTTP Host /"
    print "# TLS SNI so rule matching, connection display and app edge-cases work like"
    print "# normal proxying."
    print "sniffer:"
    print "  enable: true"
    print "  force-dns-mapping: true"
    print "  parse-pure-ip: true"
    print "  override-destination: true"
    print "  sniff:"
    print "    HTTP:"
    print "      ports:"
    print "        - 80"
    print "        - 8080-8880"
    print "      override-destination: true"
    print "    TLS:"
    print "      ports:"
    print "        - 443"
    print "        - 8443"
    print "    QUIC:"
    print "      ports:"
    print "        - 443"
    print "        - 8443"
    print ""
    inserted=1
}
in_tun && /^  enable:/ { print "  enable: false"; next }
/^tun:/ { in_tun=1; print; next }
in_tun && /^[^[:space:]]/ { in_tun=0 }
/enhanced-mode:/ { print "  enhanced-mode: redir-host"; next }
{ print }
AWK
    redir_port=$(sed -n "s/^REDIR_PORT=//p" /opt/etc/mihomo/te-vpn.conf | tail -1)
    tproxy_port=$(sed -n "s/^TPROXY_PORT=//p" /opt/etc/mihomo/te-vpn.conf | tail -1)
    redir_port=${redir_port:-7892}
    tproxy_port=${tproxy_port:-7895}
    cp /opt/etc/mihomo/config.yaml /opt/etc/mihomo/config.yaml.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
    awk -v redir_port="$redir_port" -v tproxy_port="$tproxy_port" \
        -f /tmp/te-vpn-upgrade-config.awk /opt/etc/mihomo/config.yaml > /opt/etc/mihomo/config.yaml.tmp
    mv /opt/etc/mihomo/config.yaml.tmp /opt/etc/mihomo/config.yaml'

echo ">> Setting permissions"
$R 'chmod +x /opt/bin/te-vpn /opt/etc/init.d/S06mihomo \
             /opt/etc/ndm/wan.d/10-mihomo.sh /opt/etc/ndm/netfilter.d/50-mihomo.sh'

if [ -z "${NO_POLICY:-}" ]; then
    echo ">> Ensuring Keenetic access policy \"$POLICY_NAME\" exists"
    # The policy is how devices are put on the VPN from the web UI: the
    # firmware connmarks its members, te-vpn picks that mark up by name.
    # The permits fill the policy's own routing table with default routes ->
    # if mihomo is down, member devices fall back to direct internet. We
    # permit every WAN (global) connection + future ones ('permit auto') so
    # the policy behaves like the default one whenever the VPN is out of the
    # picture. \$WAN_IF is only the fallback if auto-detection finds nothing.
    $R "if ! command -v ndmc >/dev/null 2>&1; then
            echo '   ndmc not found (not a Keenetic?) — skipping, use: te-vpn add'
        elif ndmc -c 'show ip policy' 2>/dev/null | grep -q 'name = $POLICY_NAME[,:]'; then
            echo '   already exists'
        else
            ndmc -c 'ip policy $POLICY_NAME'
            ndmc -c 'ip policy $POLICY_NAME description $POLICY_NAME'
            wans=\$(ndmc -c 'show running-config' 2>/dev/null \
                    | awk '/^interface /{i=\$2} /^[[:space:]]+ip global/{print i}')
            [ -n \"\$wans\" ] || wans='$WAN_IF'
            for w in \$wans; do
                ndmc -c \"ip policy $POLICY_NAME permit global \$w\" \
                    || echo \"   WARN: 'permit global \$w' failed\"
            done
            ndmc -c 'ip policy $POLICY_NAME permit auto'
            ndmc -c 'system configuration save'
            echo '   created (assign devices to it in the web UI)'
        fi"
    # keep the live te-vpn.conf pointed at this policy (also upgrades old installs)
    $R "grep -q '^POLICY_NAME=' /opt/etc/mihomo/te-vpn.conf 2>/dev/null \
            && sed -i 's/^POLICY_NAME=.*/POLICY_NAME=$POLICY_NAME/' /opt/etc/mihomo/te-vpn.conf \
            || printf '\nPOLICY_NAME=%s\n' '$POLICY_NAME' >> /opt/etc/mihomo/te-vpn.conf"
else
    $R "sed -i 's/^POLICY_NAME=.*/POLICY_NAME=/' /opt/etc/mihomo/te-vpn.conf 2>/dev/null || true"
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
