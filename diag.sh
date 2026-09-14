#!/bin/sh
echo "=== 1. SYSTEM ==="
uname -a
grep -E "DISTRIB_RELEASE|DISTRIB_TARGET|DISTRIB_ARCH" /etc/openwrt_release 2>/dev/null || true

echo "=== 2. AWG MODULE & PROTO ==="
lsmod | grep amneziawg || echo "kmod-amneziawg NOT loaded"
ls -l /lib/netifd/proto/amneziawg.sh /usr/bin/quic-i1 2>/dev/null || true

echo "=== 3. NATIVE GENERATE ==="
mkdir -p /tmp/awg-warp-auto/generated
sh -x /usr/libexec/awg-warp-auto/native-provider.sh /tmp/awg-warp-auto/generated/diag_test.conf 2>&1
echo "GEN_EXIT=$?"

echo "=== 4. PROBE TEST ==="
if [ -f /tmp/awg-warp-auto/generated/diag_test.conf ]; then
    grep -E "^Address|^Endpoint" /tmp/awg-warp-auto/generated/diag_test.conf || true
    sh -x /usr/libexec/awg-warp-auto/candidate-test.sh /tmp/awg-warp-auto/generated/diag_test.conf 10 51822 2>&1
    echo "PROBE_EXIT=$?"
else
    echo "NO_CONF_GENERATED"
fi

echo "=== 5. DNS & CONNECTIVITY ==="
nslookup www.youtube.com 77.88.8.8 2>&1 | tail -n 4
curl -sS -k -I --connect-timeout 5 --resolve api.cloudflareclient.com:443:162.159.192.1 https://api.cloudflareclient.com/v0a2158/reg 2>&1 | head -n 2
