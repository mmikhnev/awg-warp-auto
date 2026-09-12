#!/bin/sh
set -eu

echo "======================================================================"
echo "        WARP Auto & AmneziaWG — Router Installation Helper            "
echo "======================================================================"
echo ""

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
ARCHIVE_FILE="$BASE_DIR/awg-warp-auto-release.tar.gz"

if [ ! -f "$ARCHIVE_FILE" ]; then
	ARCHIVE_FILE=$(find "$BASE_DIR" -name "awg-warp-auto-*.tar.gz" | head -n 1)
fi

[ -f "$ARCHIVE_FILE" ] || {
	echo "ОШИБКА: Архив с пакетами не найден в $BASE_DIR!" >&2
	exit 1
}

echo ""
echo "Подключение к $ROUTER_USER@$ROUTER_IP..."
echo "Если установлен пароль, введите его при запросе."
echo ""

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
