#!/bin/sh
set -eu

echo "======================================================================"
echo "        WARP Auto & AmneziaWG — Router Installation Helper            "
echo "======================================================================"
echo ""

ACTION="install"
for arg in "$@"; do
	case "$arg" in
		--uninstall|-u) ACTION="uninstall" ;;
	esac
done

if [ "$ACTION" != "uninstall" ]; then
	echo "Что вы хотите сделать?"
	echo "  [1] Установить / Обновить WARP Auto & AmneziaWG (по умолчанию)"
	echo "  [2] Полностью удалить WARP Auto & AmneziaWG (чистое состояние)"
	printf "Ваш выбор [1/2] (Enter = 1): "
	read -r act_choice || act_choice=""
	case "$act_choice" in
		2) ACTION="uninstall" ;;
	esac
	echo ""
fi

echo "Выберите IP-адрес роутера OpenWrt:"
echo "  [1] 192.168.10.1 (по умолчанию)"
echo "  [2] 192.168.1.1  (стандартный OpenWrt)"
echo "  [3] Ввести вручную"
printf "Ваш выбор [1, 2, 3] (Enter = 192.168.10.1): "
read -r choice || choice=""

case "$choice" in
	2) ROUTER_IP="192.168.1.1" ;;
	3)
		printf "Введите IP-адрес роутера: "
		read -r ROUTER_IP || ROUTER_IP=""
		[ -z "$ROUTER_IP" ] && ROUTER_IP="192.168.10.1"
		;;
	*) ROUTER_IP="192.168.10.1" ;;
esac

ROUTER_USER="root"
BASE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

echo ""
echo "Подключение к $ROUTER_USER@$ROUTER_IP..."
echo "Если установлен пароль, введите его при запросе."
echo ""

if [ "$ACTION" = "uninstall" ]; then
	echo "Запуск полного удаления на роутере..."
	ssh -t -o StrictHostKeyChecking=accept-new "$ROUTER_USER@$ROUTER_IP" "sh -s" << 'EOF'
echo "[1/6] Остановка сервиса awg-warp-auto..."
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

echo "[3/6] Удаление пакетов apk..."
apk del luci-proto-amneziawg awg-warp-auto-quic amneziawg-tools kmod-amneziawg 2>/dev/null || true

echo "[4/6] Выгрузка модуля ядра..."
rmmod amneziawg 2>/dev/null || true

echo "[5/6] Удаление бинарников, модулей и настроек..."
rm -f /usr/bin/quic-i1 /usr/bin/awg
rm -f /lib/modules/*/amneziawg.ko
rm -f /lib/netifd/proto/amneziawg.sh
rm -rf /etc/config/awg-warp-auto /etc/init.d/awg-warp-auto /etc/awg-warp-auto /usr/libexec/awg-warp-auto
rm -f /usr/share/rpcd/ucode/luci.amneziawg /usr/share/rpcd/acl.d/luci-amneziawg.json /usr/share/luci/menu.d/luci-proto-amneziawg.json /usr/share/ucode/luci/controller/awgdownload.uc
rm -rf /www/luci-static/resources/view/amneziawg /www/luci-static/resources/protocol/amneziawg.js /www/luci-static/resources/icons/amneziawg.svg
rm -rf /tmp/luci-indexcache /tmp/awg-warp-auto* /tmp/quic*

echo "[6/6] Перезапуск сети и веб-интерфейса..."
/etc/init.d/network reload 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true

echo ""
echo "======================================================================"
echo " [УСПЕХ] WARP Auto и AmneziaWG полностью удалены с роутера!           "
echo " Forkop сохранен и не затронут.                                       "
echo " Рекомендуется перезагрузить роутер: reboot                           "
echo "======================================================================"
EOF
	exit 0
fi

ARCHIVE_FILE="$BASE_DIR/awg-warp-auto-release.tar.gz"
if [ ! -f "$ARCHIVE_FILE" ]; then
	ARCHIVE_FILE=$(find "$BASE_DIR" -name "awg-warp-auto-*.tar.gz" | head -n 1)
fi

[ -f "$ARCHIVE_FILE" ] || {
	echo "ОШИБКА: Архив с пакетами не найден в $BASE_DIR!" >&2
	exit 1
}

echo "[1/2] Копирование установочного пакета..."
scp -o StrictHostKeyChecking=accept-new "$ARCHIVE_FILE" "$ROUTER_USER@$ROUTER_IP:/tmp/awg-warp-auto-release.tar.gz" || \
scp -O -o StrictHostKeyChecking=accept-new "$ARCHIVE_FILE" "$ROUTER_USER@$ROUTER_IP:/tmp/awg-warp-auto-release.tar.gz"

echo ""
echo "[2/2] Установка на роутере..."
ssh -t -o StrictHostKeyChecking=accept-new "$ROUTER_USER@$ROUTER_IP" \
  "cd /tmp && rm -rf awg-warp-auto-release && tar -xzf awg-warp-auto-release.tar.gz && cd awg-warp-auto-release && sh ./install.sh && rm -f /tmp/awg-warp-auto-release.tar.gz"

echo ""
echo "======================================================================"
echo " Установка успешно завершена!"
echo " Веб-интерфейс: http://$ROUTER_IP/cgi-bin/luci/admin/services/amneziawg"
echo "======================================================================"
