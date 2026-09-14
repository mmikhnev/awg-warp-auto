#!/bin/sh
echo "=== 1. SYSTEM ==="
uname -a
grep -E "DISTRIB_RELEASE|DISTRIB_TARGET|DISTRIB_ARCH" /etc/openwrt_release 2>/dev/null || true

echo "=== 2. AWG MODULE & PROTO ==="
lsmod | grep amneziawg || echo "kmod-amneziawg NOT loaded"
ls -l /lib/netifd/proto/amneziawg.sh /usr/bin/quic-i1 2>/dev/null || true
if [ -x /usr/bin/quic-i1 ]; then
    /usr/bin/quic-i1 test.com 2>&1 | head -c 20 || echo "quic-i1 failed"
    echo ""
fi

echo "=== 3. CF API & DNS ==="
curl -I -sS --connect-timeout 5 https://api.cloudflareclient.com/v0a2158/reg 2>&1 | head -n 3
nslookup www.youtube.com 1.1.1.1 2>&1 | tail -n 5

echo "=== 4. UCI MAIN ==="
uci show awg-warp-auto.main 2>/dev/null || true

echo "=== 5. DAEMON LOGS ==="
logread | grep awg-warp-auto | tail -n 35

echo "=== 6. MANUAL BOOTSTRAP ==="
/usr/libexec/awg-warp-auto/daemon.sh bootstrap 2>&1
echo "bootstrap exit code: $?"
