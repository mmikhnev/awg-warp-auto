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

# Цвета и оформление терминала
C_RESET=$(printf '\033[0m')
C_RED=$(printf '\033[1;31m')
C_GREEN=$(printf '\033[1;32m')
C_YELLOW=$(printf '\033[1;33m')
C_BLUE=$(printf '\033[1;34m')
C_MAGENTA=$(printf '\033[1;35m')
C_CYAN=$(printf '\033[1;36m')
C_BOLD=$(printf '\033[1m')
C_DIM=$(printf '\033[2m')

case "$(id -u)" in
	0) ;;
	*) echo "${C_RED}[ОШИБКА] Скрипт должен быть запущен от пользователя root на роутере OpenWrt.${C_RESET}" >&2; exit 1 ;;
esac

if [ ! -f /etc/openwrt_release ]; then
	echo "${C_RED}[ОШИБКА] /etc/openwrt_release не найден. Скрипт предназначен только для OpenWrt.${C_RESET}" >&2
	exit 1
fi

clear 2>/dev/null || true
echo "${C_CYAN}======================================================================${C_RESET}"
echo "${C_BOLD}${C_CYAN}          WARP Auto & AmneziaWG — Управление на OpenWrt               ${C_RESET}"
echo "${C_CYAN}======================================================================${C_RESET}"
echo ""
echo "${C_BOLD}Выберите действие:${C_RESET}"
echo "  ${C_GREEN}[1] Установка${C_RESET}  — полная установка AmneziaWG v3.1 + WARP Auto"
echo "  ${C_CYAN}[2] Обновление${C_RESET} — обновление компонентов и LuCI UI (пул сохраняется)"
echo "  ${C_RED}[3] Удаление${C_RESET}   — полное удаление AmneziaWG и WARP Auto (Forkop не трогаем)"
echo ""
printf "${C_BOLD}${C_YELLOW}Ваш выбор [1/2/3] (Enter = 1): ${C_RESET}"
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
	echo "${C_RED}=== Полное удаление WARP Auto & AmneziaWG ===${C_RESET}"
	echo "${C_CYAN}[1/6]${C_RESET} Остановка сервиса awg-warp-auto..."
	/etc/init.d/awg-warp-auto stop 2>/dev/null || true
	/etc/init.d/awg-warp-auto disable 2>/dev/null || true

	echo "${C_CYAN}[2/6]${C_RESET} Удаление всех интерфейсов и маршрутов с proto=amneziawg..."
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

	echo "${C_CYAN}[3/6]${C_RESET} Удаление пакетов apk..."
	apk del luci-proto-amneziawg awg-warp-auto-quic amneziawg-tools kmod-amneziawg 2>/dev/null || true

	echo "${C_CYAN}[4/6]${C_RESET} Выгрузка модуля ядра..."
	rmmod amneziawg 2>/dev/null || true

	echo "${C_CYAN}[5/6]${C_RESET} Удаление файлов приложения, модулей и настроек..."
	rm -f /usr/bin/quic-i1 /usr/bin/awg
	rm -f /lib/modules/*/amneziawg.ko
	rm -f /lib/netifd/proto/amneziawg.sh
	rm -rf /etc/config/awg-warp-auto /etc/init.d/awg-warp-auto /etc/awg-warp-auto /usr/libexec/awg-warp-auto
	rm -f /usr/share/rpcd/ucode/luci.amneziawg /usr/share/rpcd/acl.d/luci-amneziawg.json /usr/share/luci/menu.d/luci-proto-amneziawg.json /usr/share/ucode/luci/controller/awgdownload.uc
	rm -rf /www/luci-static/resources/view/amneziawg /www/luci-static/resources/protocol/amneziawg.js /www/luci-static/resources/icons/amneziawg.svg
	rm -rf /tmp/luci-indexcache /tmp/awg-warp-auto* /tmp/quic*

	echo "${C_CYAN}[6/6]${C_RESET} Перезапуск сети и веб-интерфейса..."
	/etc/init.d/network reload 2>/dev/null || true
	/etc/init.d/rpcd restart 2>/dev/null || true

	echo ""
	echo "${C_GREEN}======================================================================${C_RESET}"
	echo "${C_BOLD}${C_GREEN} [✓] WARP Auto и AmneziaWG полностью удалены с роутера!              ${C_RESET}"
	echo "     Forkop сохранен и не затронут.                                   "
	echo "     Рекомендуется перезагрузить роутер: reboot                       "
	echo "${C_GREEN}======================================================================${C_RESET}"
	exit 0
fi

# --------------------------------------------------------------------
# 2. СКАЧИВАНИЕ РЕЛИЗНОГО ПАКЕТА
# --------------------------------------------------------------------
ARCHIVE="/tmp/awg-warp-auto-release.tar.gz"

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
if [ -f "$SCRIPT_DIR/dist/awg-warp-auto-release.tar.gz" ]; then
	echo "${C_CYAN}---> Используется локальный релизный архив из dist/...${C_RESET}"
	cp "$SCRIPT_DIR/dist/awg-warp-auto-release.tar.gz" "$ARCHIVE"
elif [ -f "$SCRIPT_DIR/release/awg-warp-auto-release.tar.gz" ]; then
	echo "${C_CYAN}---> Используется локальный релизный архив из release/...${C_RESET}"
	cp "$SCRIPT_DIR/release/awg-warp-auto-release.tar.gz" "$ARCHIVE"
else
	echo "${C_CYAN}---> Скачивание релизного пакета с GitHub...${C_RESET}"
	rm -f "$ARCHIVE"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 --max-time 180 "$RELEASE_URL" -o "$ARCHIVE" || true
	fi
	if [ ! -s "$ARCHIVE" ]; then
		wget -q -O "$ARCHIVE" "$RELEASE_URL" || true
	fi
	if [ ! -s "$ARCHIVE" ]; then
		echo "${C_RED}[ОШИБКА] Не удалось скачать релизный архив с GitHub ($RELEASE_URL)!${C_RESET}" >&2
		echo "Проверьте доступность интернета на роутере." >&2
		exit 1
	fi
fi

echo "${C_CYAN}---> Распаковка пакета...${C_RESET}"
rm -rf /tmp/awg-warp-auto-release
tar -xzf "$ARCHIVE" -C /tmp
rm -f "$ARCHIVE"

WORK_DIR="/tmp/awg-warp-auto-release"
if [ ! -f "$WORK_DIR/install.sh" ] && [ -f "$WORK_DIR/awg-warp-auto-release/install.sh" ]; then
	WORK_DIR="$WORK_DIR/awg-warp-auto-release"
fi

if [ ! -f "$WORK_DIR/install.sh" ]; then
	echo "${C_RED}[ОШИБКА] Файл инсталлера не найден в $WORK_DIR/install.sh!${C_RESET}" >&2
	exit 1
fi

# --------------------------------------------------------------------
# 3. УСТАНОВКА / ОБНОВЛЕНИЕ
# --------------------------------------------------------------------
if [ "$ACTION" = "update" ]; then
	echo "${C_CYAN}=== Обновление компонентов WARP Auto ===${C_RESET}"
	/etc/init.d/awg-warp-auto stop 2>/dev/null || true
	(cd "$WORK_DIR" && sh ./install.sh)
	/etc/init.d/awg-warp-auto start 2>/dev/null || true
	rm -rf /tmp/awg-warp-auto-release
	echo ""
	echo "${C_GREEN}======================================================================${C_RESET}"
	echo "${C_BOLD}${C_GREEN} [✓] WARP Auto успешно обновлен!                                      ${C_RESET}"
	echo "     Все текущие профили и настройки сохранены.                       "
	echo "     Веб-интерфейс: Services -> AmneziaWG                             "
	echo "${C_GREEN}======================================================================${C_RESET}"
	exit 0
fi

# Чистая установка
echo "${C_CYAN}=== Установка AmneziaWG v3.1 и WARP Auto ===${C_RESET}"
(cd "$WORK_DIR" && sh ./install.sh)
rm -rf /tmp/awg-warp-auto-release

# Попытка динамической загрузки модуля ядра без ребута
if ! lsmod | grep -q amneziawg; then
	kmod_dir="/lib/modules/$(uname -r)"
	if [ -f "$kmod_dir/amneziawg.ko" ]; then
		echo "${C_CYAN}---> Загрузка модуля ядра AmneziaWG (на лету)...${C_RESET}"
		insmod "$kmod_dir/amneziawg.ko" 2>/dev/null || true
	fi
fi

# --------------------------------------------------------------------
# 4. ИНТЕГРАЦИЯ С FORKOP
# --------------------------------------------------------------------
echo ""
echo "${C_CYAN}=== Проверка Forkop ===${C_RESET}"
if [ -f /etc/init.d/forkop ] || command -v forkop >/dev/null 2>&1; then
	echo "${C_GREEN}[✓] Forkop обнаружен на роутере.${C_RESET}"
	echo "    В интерфейсе Forkop выберите сетевой интерфейс ${C_BOLD}YTwarp${C_RESET} для секции YouTube."
else
	echo "${C_YELLOW}[!] Forkop не обнаружен на роутере.${C_RESET}"
	echo "    Forkop позволяет направлять трафик отдельных сервисов (YouTube, Discord и др.)"
	echo "    в туннель WARP, оставляя весь остальной трафик прямым."
	printf "${C_BOLD}${C_YELLOW}Хотите установить Forkop прямо сейчас? [y/N]: ${C_RESET}"
	read -r install_forkop || install_forkop=""
	case "$install_forkop" in
		[yY]|[yY][eE][sS]|[дД]|[дД][аА])
			echo "${C_CYAN}---> Запуск официальной установки Forkop...${C_RESET}"
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
echo "${C_CYAN}=== Начальная настройка WARP ===${C_RESET}"
if lsmod | grep -q amneziawg; then
	printf "${C_BOLD}${C_YELLOW}Сгенерировать и активировать первый WARP-профиль прямо сейчас? [Y/n]: ${C_RESET}"
	read -r gen_first || gen_first=""
	case "$gen_first" in
		[nN]|[nN][oO]|[нН]|[нН][еЕ][тТ])
			echo "Вы можете сгенерировать профиль позже через LuCI: Services -> AmneziaWG"
			;;
		*)
			echo "${C_CYAN}---> Генерация первого рабочего WARP-профиля (Native Cloudflare API)...${C_RESET}"
			/usr/libexec/awg-warp-auto/daemon.sh bootstrap || true
			if uci -q get network.YTwarp >/dev/null 2>&1; then
				echo "${C_GREEN}[✓] Интерфейс YTwarp успешно создан и активирован!${C_RESET}"
			fi
			;;
	esac
else
	echo "${C_YELLOW}[!] Модуль ядра AmneziaWG будет активирован после разовой перезагрузки: reboot${C_RESET}"
fi

echo ""
echo "${C_GREEN}======================================================================${C_RESET}"
echo "${C_BOLD}${C_GREEN} [✓] Установка WARP Auto завершена!                                   ${C_RESET}"
echo "     Веб-интерфейс: Services -> AmneziaWG                             "
echo "     Рекомендуется перезагрузить роутер: reboot                       "
echo "${C_GREEN}======================================================================${C_RESET}"
