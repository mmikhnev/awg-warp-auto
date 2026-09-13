#!/bin/sh
# Complete clean uninstaller for AmneziaWG and WARP Auto
# Preserves Forkop, network system settings, and unrelated configurations
set -eu

case "$(id -u)" in
	0) ;;
	*) echo "ERROR: Run as root on the OpenWrt router." >&2; exit 1 ;;
esac

echo "======================================================================"
echo "    Полное удаление WARP Auto & AmneziaWG с роутера OpenWrt           "
echo "======================================================================"
echo ""

echo "[1/6] Остановка и отключение сервиса awg-warp-auto..."
/etc/init.d/awg-warp-auto stop 2>/dev/null || true
/etc/init.d/awg-warp-auto disable 2>/dev/null || true

echo "[2/6] Удаление всех интерфейсов и маршрутов с proto=amneziawg..."
for iface in $(uci -q show network | grep '\.proto=.amneziawg.' | cut -d. -f2 | cut -d= -f1); do
	[ -n "$iface" ] || continue
	ifdown "$iface" 2>/dev/null || true
	uci -q delete "network.$iface" || true
	uci -q delete "network.${iface}_ipv4_egress" || true
	uci -q delete "network.${iface}_ipv4_mark" || true
	for r in $(uci -q show network | grep "\.interface='$iface'" | cut -d. -f2 | cut -d= -f1); do
		uci -q delete "network.$r" || true
	done
done
for peer in $(uci -q show network | grep '=amneziawg_' | cut -d. -f2 | cut -d= -f1); do
	uci -q delete "network.$peer" || true
done
uci commit network 2>/dev/null || true

echo "[3/6] Удаление установленных пакетов через apk..."
apk del luci-proto-amneziawg awg-warp-auto-quic amneziawg-tools kmod-amneziawg 2>/dev/null || true

echo "[4/6] Выгрузка модуля ядра amneziawg..."
rmmod amneziawg 2>/dev/null || true

echo "[5/6] Удаление файлов приложения, модулей и LuCI компонентов..."
rm -f /usr/bin/quic-i1 /usr/bin/awg
rm -f /lib/modules/*/amneziawg.ko
rm -f /lib/netifd/proto/amneziawg.sh
rm -rf /etc/config/awg-warp-auto /etc/init.d/awg-warp-auto /etc/awg-warp-auto /usr/libexec/awg-warp-auto
rm -f /usr/share/rpcd/ucode/luci.amneziawg /usr/share/rpcd/acl.d/luci-amneziawg.json /usr/share/luci/menu.d/luci-proto-amneziawg.json /usr/share/ucode/luci/controller/awgdownload.uc
rm -rf /www/luci-static/resources/view/amneziawg /www/luci-static/resources/protocol/amneziawg.js /www/luci-static/resources/icons/amneziawg.svg
rm -rf /tmp/luci-indexcache /tmp/awg-warp-auto* /tmp/quic*

echo "[6/6] Перезапуск сетевых служб и веб-интерфейса..."
/etc/init.d/network reload 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true

echo ""
echo "======================================================================"
echo " [УСПЕХ] WARP Auto и AmneziaWG полностью удалены с роутера!           "
echo " Forkop и остальные службы сохранены.                                 "
echo " Рекомендуется перезагрузить роутер: reboot                           "
echo "======================================================================"
