#!/bin/sh
# WARP Auto & AmneziaWG — Универсальный OpenWrt онлайн-инсталлер
# Запуск одной командой на роутере:
#   sh <(wget -O - https://raw.githubusercontent.com/mmikhnev/awg-warp-auto/main/install.sh)
# или:
#   sh -c "$(wget -O - https://raw.githubusercontent.com/mmikhnev/awg-warp-auto/main/install.sh)"

set -eu

REPO_OWNER="mmikhnev"
REPO_NAME="awg-warp-auto"
BRANCH="main"
RELEASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/release/awg-warp-auto-release.tar.gz"

case "$(id -u)" in
	0) ;;
	*) echo "ОШИБКА: Скрипт должен быть запущен от пользователя root на роутере OpenWrt." >&2; exit 1 ;;
esac

if [ ! -f /etc/openwrt_release ]; then
	echo "ОШИБКА: /etc/openwrt_release не найден. Скрипт предназначен только для OpenWrt." >&2
	exit 1
fi

echo "======================================================================"
echo "          WARP Auto & AmneziaWG — Управление на OpenWrt               "
echo "======================================================================"
echo ""
echo "Выберите действие:"
echo "  [1] Установка  — полная установка AmneziaWG v3.1 + WARP Auto"
echo "  [2] Обновление — обновление компонентов и LuCI UI (пул сохраняется)"
echo "  [3] Удаление   — полное удаление AmneziaWG и WARP Auto (Forkop цел)"
echo ""
printf "Ваш выбор [1/2/3] (Enter = 1): "
read -r choice || choice=""

ACTION="install"
case "$choice" in
	2) ACTION="update" ;;
	3) ACTION="uninstall" ;;
	*) ACTION="install" ;;
esac

echo ""

# --------------------------------------------------------------------
# 1. РЕЖИМ УДАЛЕНИЯ
# --------------------------------------------------------------------
if [ "$ACTION" = "uninstall" ]; then
	echo "=== Полное удаление WARP Auto & AmneziaWG ==="
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

	echo "[5/6] Удаление файлов приложения, модулей и настроек..."
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
	exit 0
fi

# --------------------------------------------------------------------
# 2. СКАЧИВАНИЕ РЕЛИЗНОГО ПАКЕТА
# --------------------------------------------------------------------
ARCHIVE="/tmp/awg-warp-auto-release.tar.gz"
WORK_DIR="/tmp/awg-warp-auto-release"

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
if [ -f "$SCRIPT_DIR/dist/awg-warp-auto-release.tar.gz" ]; then
	echo "Используется локальный релизный архив из $SCRIPT_DIR/dist/..."
	cp "$SCRIPT_DIR/dist/awg-warp-auto-release.tar.gz" "$ARCHIVE"
elif [ -f "$SCRIPT_DIR/release/awg-warp-auto-release.tar.gz" ]; then
	echo "Используется локальный релизный архив из $SCRIPT_DIR/release/..."
	cp "$SCRIPT_DIR/release/awg-warp-auto-release.tar.gz" "$ARCHIVE"
else
	echo "Скачивание релизного пакета с GitHub..."
	rm -f "$ARCHIVE"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 --max-time 180 "$RELEASE_URL" -o "$ARCHIVE" || true
	fi
	if [ ! -s "$ARCHIVE" ]; then
		wget -q -O "$ARCHIVE" "$RELEASE_URL" || true
	fi
	if [ ! -s "$ARCHIVE" ]; then
		echo "ОШИБКА: Не удалось скачать релизный архив с GitHub ($RELEASE_URL)!" >&2
		echo "Проверьте доступность интернета на роутере." >&2
		exit 1
	fi
fi

echo "Распаковка пакета..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
tar -xzf "$ARCHIVE" -C "$WORK_DIR"
rm -f "$ARCHIVE"

# --------------------------------------------------------------------
# 3. УСТАНОВКА / ОБНОВЛЕНИЕ
# --------------------------------------------------------------------
if [ "$ACTION" = "update" ]; then
	echo "=== Обновление компонентов WARP Auto ==="
	/etc/init.d/awg-warp-auto stop 2>/dev/null || true
	cd "$WORK_DIR"
	sh ./install.sh
	/etc/init.d/awg-warp-auto start 2>/dev/null || true
	rm -rf "$WORK_DIR"
	echo ""
	echo "======================================================================"
	echo " [УСПЕХ] WARP Auto успешно обновлен!                                  "
	echo " Все текущие профили и настройки сохранены.                           "
	echo " Веб-интерфейс: Services -> AmneziaWG                                 "
	echo "======================================================================"
	exit 0
fi

# Чистая установка
echo "=== Установка AmneziaWG v3.1 и WARP Auto ==="
cd "$WORK_DIR"
sh ./install.sh
rm -rf "$WORK_DIR"

# Попытка динамической загрузки модуля ядра без ребута
if ! lsmod | grep -q amneziawg; then
	kmod_dir="/lib/modules/$(uname -r)"
	if [ -f "$kmod_dir/amneziawg.ko" ]; then
		echo "Загрузка модуля ядра AmneziaWG (на лету)..."
		insmod "$kmod_dir/amneziawg.ko" 2>/dev/null || true
	fi
fi

# --------------------------------------------------------------------
# 4. ИНТЕГРАЦИЯ С FORKOP
# --------------------------------------------------------------------
echo ""
echo "=== Проверка Forkop ==="
if [ -f /etc/init.d/forkop ] || command -v forkop >/dev/null 2>&1; then
	echo "[OK] Forkop обнаружен на роутере."
	echo "  В интерфейсе Forkop выберите сетевой интерфейс 'YTwarp' для секции YouTube."
else
	echo "[ИНФО] Forkop не обнаружен на роутере."
	echo "  Forkop позволяет направлять трафик отдельных сервисов (YouTube, Discord и др.)"
	echo "  в туннель WARP, оставляя весь остальной трафик прямым."
	printf "Хотите установить Forkop прямо сейчас? [y/N]: "
	read -r install_forkop || install_forkop=""
	case "$install_forkop" in
		[yY]|[yY][eE][sS]|[дД]|[дД][аА])
			echo "Запуск официальной установки Forkop..."
			sh -c "$(wget -O - https://raw.githubusercontent.com/ushan0v/forkop/main/install.sh)" || true
			;;
		*)
			echo "Пропуск установки Forkop."
			;;
	esac
fi

# --------------------------------------------------------------------
# 5. ПЕРВЫЙ ПРОФИЛЬ (BOOTSTRAP)
# --------------------------------------------------------------------
echo ""
echo "=== Начальная настройка WARP ==="
if lsmod | grep -q amneziawg; then
	printf "Сгенерировать и активировать первый WARP-профиль прямо сейчас? [Y/n]: "
	read -r gen_first || gen_first=""
	case "$gen_first" in
		[nN]|[nN][oO]|[нН]|[нН][еЕ][тТ])
			echo "Вы можете сгенерировать профиль позже через LuCI: Services -> AmneziaWG"
			;;
		*)
			echo "Генерация первого рабочего WARP-профиля (Native Cloudflare API)..."
			/usr/libexec/awg-warp-auto/daemon.sh bootstrap || true
			if uci -q get network.YTwarp >/dev/null 2>&1; then
				echo "[OK] Интерфейс YTwarp успешно создан и активирован!"
			fi
			;;
	esac
else
	echo "[ИНФО] Модуль ядра AmneziaWG будет активирован после разовой перезагрузки."
fi

echo ""
echo "======================================================================"
echo " [УСПЕХ] Установка WARP Auto завершена!                               "
echo " Веб-интерфейс: Services -> AmneziaWG                                 "
echo " Рекомендуется перезагрузить роутер: reboot                           "
echo "======================================================================"
