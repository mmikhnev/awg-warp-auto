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

# Получение актуального хэша коммита для обхода кеша GitHub Raw CDN
COMMIT_REF="${BRANCH}"
if command -v curl >/dev/null 2>&1; then
	API_SHA=$(curl -fsSL --connect-timeout 4 "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${BRANCH}" 2>/dev/null | grep '"sha":' | head -n 1 | cut -d'"' -f4 || true)
	[ -n "$API_SHA" ] && COMMIT_REF="$API_SHA"
elif command -v wget >/dev/null 2>&1; then
	API_SHA=$(wget -q -T 4 -O - "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${BRANCH}" 2>/dev/null | grep '"sha":' | head -n 1 | cut -d'"' -f4 || true)
	[ -n "$API_SHA" ] && COMMIT_REF="$API_SHA"
fi

RELEASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${COMMIT_REF}/release/awg-warp-auto-release.tar.gz"

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

prompt_user() {
	local var_name=$1
	local prompt_text=$2
	local default_val=${3:-}
	local input=""

	if (exec 3</dev/tty) 2>/dev/null; then
		exec 3<&-
		printf "%b" "$prompt_text" >/dev/tty
		read -r input </dev/tty || input="$default_val"
	else
		printf "%b" "$prompt_text"
		read -r input || input="$default_val"
	fi
	[ -n "$input" ] || input="$default_val"
	eval "$var_name=\$input"
}

run_diagnostics() {
	local PASS_ICON="${C_GREEN}[✓]${C_RESET}"
	local WARN_ICON="${C_YELLOW}[!]${C_RESET}"
	local FAIL_ICON="${C_RED}[✗]${C_RESET}"
	local WARNINGS=0 ERRORS=0

	echo ""
	echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
	echo "${C_BOLD}${C_CYAN}      WARP Auto & AmneziaWG — Экспресс-диагностика системы            ${C_RESET}"
	echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
	echo ""

	echo "${C_BOLD}1. Информация о системе:${C_RESET}"
	if [ -f /etc/openwrt_release ]; then
		. /etc/openwrt_release
		echo "   OS           : OpenWrt ${DISTRIB_RELEASE:-unknown}"
		echo "   Target       : ${DISTRIB_TARGET:-unknown}"
		echo "   Arch         : ${DISTRIB_ARCH:-unknown}"
		echo "   Kernel       : $(uname -r 2>/dev/null || echo unknown)"
	else
		echo "   $FAIL_ICON Не является OpenWrt (/etc/openwrt_release не найден)"
		ERRORS=$((ERRORS + 1))
	fi

	if command -v apk >/dev/null 2>&1; then
		echo "   Пакетный мен.: apk (OpenWrt 25.x+)"
	elif command -v opkg >/dev/null 2>&1; then
		echo "   Пакетный мен.: opkg (OpenWrt 24.x/legacy)"
	else
		echo "   $FAIL_ICON Пакетный менеджер apk/opkg не найден"
		ERRORS=$((ERRORS + 1))
	fi

	local mem_free
	mem_free=$(awk '/MemAvailable/ { print int($2/1024) }' /proc/meminfo 2>/dev/null || awk '/MemFree/ { print int($2/1024) }' /proc/meminfo 2>/dev/null || echo 0)
	echo "   Свободно RAM : ${mem_free} MB"
	if [ "$mem_free" -lt 30 ] && [ "$mem_free" -gt 0 ]; then
		echo "   $WARN_ICON Мало свободной памяти (<30MB)"
		WARNINGS=$((WARNINGS + 1))
	fi

	echo ""
	echo "${C_BOLD}2. Состояние AmneziaWG:${C_RESET}"
	if lsmod 2>/dev/null | grep -q amneziawg; then
		echo "   $PASS_ICON Модуль ядра kmod-amneziawg: загружен"
	else
		local kmod_file="/lib/modules/$(uname -r 2>/dev/null)/amneziawg.ko"
		if [ -f "$kmod_file" ]; then
			echo "   $WARN_ICON Модуль amneziawg.ko найден на диске, но не загружен в память (потребуется insmod или reboot)"
			WARNINGS=$((WARNINGS + 1))
		else
			echo "   $WARN_ICON Модуль ядра amneziawg не установлен (будет скачан при установке)"
		fi
	fi

	if [ -f /lib/netifd/proto/amneziawg.sh ]; then
		echo "   $PASS_ICON Протокол netifd /lib/netifd/proto/amneziawg.sh: найден"
	else
		echo "   $WARN_ICON Протокол netifd amneziawg: не установлен (будет добавлен пакетом)"
	fi

	if command -v awg >/dev/null 2>&1; then
		echo "   $PASS_ICON Утилита /usr/bin/awg: доступна"
	else
		echo "   $WARN_ICON Утилита awg: не найдена (будет установлена пакетом)"
	fi

	echo ""
	echo "${C_BOLD}3. Доступность DNS-серверов:${C_RESET}"
	local dns_ok=0
	for d_entry in "77.88.8.8:Yandex DNS" "8.8.8.8:Google DNS" "1.1.1.1:Cloudflare DNS"; do
		local d_ip=${d_entry%:*}
		local d_name=${d_entry#*:}
		local d_res
		d_res=$(nslookup -timeout=2 www.google.com "$d_ip" 2>/dev/null | awk '/^Address:|^Address [0-9]+:/ { if ($NF !~ /:53$/) { print $NF; exit } }' || true)
		if [ -z "$d_res" ]; then
			d_res=$(nslookup www.google.com "$d_ip" 2>/dev/null | awk '/^Address:|^Address [0-9]+:/ { if ($NF !~ /:53$/) { print $NF; exit } }' || true)
		fi
		if [ -n "$d_res" ]; then
			echo "   $PASS_ICON $d_name ($d_ip): OK (IP: $d_res)"
			dns_ok=1
		else
			echo "   $FAIL_ICON $d_name ($d_ip): НЕТ ОТВЕТА (возможно, блокируется провайдером)"
		fi
	done

	if [ "$dns_ok" -eq 0 ]; then
		echo "   $FAIL_ICON Все внешние DNS-серверы заблокированы или недоступны!"
		ERRORS=$((ERRORS + 1))
	fi

	echo ""
	echo "${C_BOLD}4. Доступность Cloudflare WARP Registration API:${C_RESET}"
	local cf_ok=0
	local dummy_pub
	if command -v awg >/dev/null 2>&1; then
		dummy_pub=$(awg genkey 2>/dev/null | awg pubkey 2>/dev/null || echo "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")
	else
		dummy_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
	fi
	local tos
	tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "2026-09-14T00:00:00.000Z")
	local body="{\"install_id\":\"\",\"tos\":\"$tos\",\"key\":\"$dummy_pub\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}"

	for cf_ip in "162.159.192.1:Anycast IP #1" "162.159.193.1:Anycast IP #2"; do
		local r_ip=${cf_ip%:*}
		local r_label=${cf_ip#*:}
		local t_start t_end latency code
		t_start=$(date +%s%3N 2>/dev/null || date +%s000)

		code=$(curl -sS -k -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 7 \
			-A 'okhttp/3.12.1' -H 'Content-Type: application/json' \
			--resolve api.cloudflareclient.com:443:"$r_ip" \
			-d "$body" "https://api.cloudflareclient.com/v0i1909051800/reg" 2>/dev/null || true)
		code=$(printf '%s' "$code" | tail -c 3)

		t_end=$(date +%s%3N 2>/dev/null || date +%s000)
		latency=$((t_end - t_start))
		[ "$latency" -ge 0 ] 2>/dev/null || latency=0

		case "$code" in
			200|201)
				echo "   $PASS_ICON $r_label ($r_ip): HTTP $code OK (${latency}ms) — Регистрация РАБОТАЕТ!"
				cf_ok=1
				;;
			401|400)
				echo "   $PASS_ICON $r_label ($r_ip): HTTP $code OK (${latency}ms) — API доступен и отвечает!"
				cf_ok=1
				;;
			429)
				echo "   $WARN_ICON $r_label ($r_ip): HTTP 429 Rate Limited (${latency}ms) — API доступен, но действует временный лимит (подождать 5-10 мин)"
				WARNINGS=$((WARNINGS + 1))
				cf_ok=1
				;;
			000|'')
				echo "   $FAIL_ICON $r_label ($r_ip): ТАЙМАУТ / БЛОКИРОВКА (HTTP 000)"
				;;
			*)
				echo "   $WARN_ICON $r_label ($r_ip): HTTP $code (${latency}ms)"
				cf_ok=1
				;;
		esac
	done

	if [ "$cf_ok" -eq 0 ]; then
		echo "   $FAIL_ICON Прямой доступ к API регистрации Cloudflare заблокирован провайдером!"
		ERRORS=$((ERRORS + 1))
	fi

	echo ""
	echo "${C_BOLD}5. Проверка портов туннелей WARP:${C_RESET}"
	echo "   (WARP использует AmneziaWG поверх портов 500, 4500, 1701, 7559 и 2408)"
	echo "   • Порт 500: IKE / IPsec NAT-T (наиболее надежный в РФ)"
	echo "   • Порт 4500: IPsec NAT-T (наиболее надежный в РФ)"
	echo "   • Порт 1701: L2TP standard"
	echo "   • Порт 7559: Cloudflare high-port"
	echo "   • Порт 2408: Стандартный порт Wireguard/WARP (часто заблокирован ТСПУ)"

	echo ""
	echo "${C_BOLD}6. Проверка прямого доступа к YouTube:${C_RESET}"
	local yt_code
	yt_code=$(curl -sS -k -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 \
		https://www.youtube.com/generate_204 2>/dev/null || true)
	yt_code=$(printf '%s' "$yt_code" | tail -c 3)

	case "$yt_code" in
		204|200)
			echo "   $PASS_ICON Прямой доступ к YouTube: РАБОТАЕТ (HTTP $yt_code)"
			;;
		000|'')
			echo "   $WARN_ICON Прямой доступ к YouTube: ЗАБЛОКИРОВАН ТСПУ / ТАЙМАУТ (HTTP 000)"
			echo "              (Маршрутизация через WARP / Forkop вернет доступ)"
			;;
		*)
			echo "   $WARN_ICON Прямой доступ к YouTube: HTTP $yt_code"
			;;
	esac

	echo ""
	echo "${C_BOLD}7. Статус Forkop:${C_RESET}"
	if [ -f /etc/init.d/forkop ]; then
		if /etc/init.d/forkop running 2>/dev/null; then
			echo "   $PASS_ICON Forkop установлен и ЗАПУЩЕН"
		else
			echo "   $WARN_ICON Forkop установлен, но остановлен"
		fi
		local existing_secs
		existing_secs=$(uci -q show forkop 2>/dev/null | grep '=section$' | cut -d. -f2 | cut -d= -f1 | tr '\n' ' ' || true)
		if [ -n "$existing_secs" ]; then
			echo "   Секции Forkop: $existing_secs"
		fi
	else
		echo "   $WARN_ICON Forkop не установлен на роутере (установщик предложит поставить автоматически)"
	fi

	echo ""
	echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
	if [ "$ERRORS" -eq 0 ] && [ "$cf_ok" -eq 1 ]; then
		echo "${C_BOLD}${C_GREEN} [✓] СИСТЕМА ПОЛНОСТЬЮ ГОТОВА К УСТАНОВКЕ WARP AUTO!                   ${C_RESET}"
		echo "     API регистрации Cloudflare отвечает, Anycast-маршрутизация открыта."
	elif [ "$cf_ok" -eq 0 ]; then
		echo "${C_BOLD}${C_RED} [✗] ВНИМАНИЕ: Cloudflare API заблокирован провайдером.                ${C_RESET}"
		echo "     Для генерации профилей потребуется рабочий обход или ручной импорт .conf"
	else
		echo "${C_BOLD}${C_YELLOW} [!] СИСТЕМА ГОТОВА, НО ИМЕЮТСЯ ПРЕДУПРЕЖДЕНИЯ (см. выше).           ${C_RESET}"
	fi
	echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
}

echo "${C_CYAN}======================================================================${C_RESET}"
echo "${C_BOLD}${C_CYAN}          WARP Auto & AmneziaWG — Управление на OpenWrt               ${C_RESET}"
echo "${C_CYAN}======================================================================${C_RESET}"
sleep 0.3 2>/dev/null || true
echo ""
echo "${C_BOLD}Выберите действие:${C_RESET}"
echo "  ${C_CYAN}[0] Диагностика${C_RESET} — экспресс-проверка системы, Cloudflare API и портов"
echo "  ${C_GREEN}[1] Установка${C_RESET}   — чистая установка AmneziaWG v3.1 + WARP Auto"
echo "  ${C_CYAN}[2] Обновление${C_RESET}  — обновление компонентов и LuCI UI (пул сохраняется)"
echo "  ${C_RED}[3] Удаление${C_RESET}    — удаление AmneziaWG и WARP Auto"
echo ""
prompt_user choice "${C_BOLD}${C_YELLOW}Ваш выбор [0/1/2/3] (Enter = 1): ${C_RESET}" "1"

ACTION="install"
case "$choice" in
	0) ACTION="diag" ;;
	2) ACTION="update" ;;
	3) ACTION="uninstall" ;;
	*) ACTION="install" ;;
esac

if [ "$ACTION" = "diag" ]; then
	run_diagnostics
	echo ""
	prompt_user continue_inst "${C_BOLD}${C_YELLOW}Продолжить установку AmneziaWG и WARP Auto прямо сейчас? [Y/n]: ${C_RESET}" "Y"
	case "$continue_inst" in
		[yY]|[yY][eE][sS]|[дД]|[дД][аА])
			ACTION="install"
			echo ""
			;;
		*)
			echo "Выход."
			exit 0
			;;
	esac
fi

echo ""

# --------------------------------------------------------------------
# 1. РЕЖИМ УДАЛЕНИЯ
# --------------------------------------------------------------------
if [ "$ACTION" = "uninstall" ]; then
	echo "${C_RED}=== Удаление WARP Auto & AmneziaWG ===${C_RESET}"
	if [ -f /etc/config/network ]; then
		UNINST_BAK="/etc/config/network.pre-uninstall.$(date +%s).bak"
		cp /etc/config/network "$UNINST_BAK"
		echo "${C_GREEN}[✓] Резервная копия сети создана: $UNINST_BAK${C_RESET}"
	fi

	echo ""
	echo "${C_BOLD}Выберите область удаления:${C_RESET}"
	echo "  ${C_CYAN}[1] Удалить только WARP Auto (YTwarp)${C_RESET} — другие AmneziaWG интерфейсы сохранятся"
	echo "  ${C_RED}[2] Полная зачистка всех интерфейсов AmneziaWG и пакетов ядра${C_RESET}"
	prompt_user uninst_scope "${C_BOLD}${C_YELLOW}Ваш выбор [1/2] (Enter = 1): ${C_RESET}" "1"

	echo ""
	echo "${C_CYAN}[1/5]${C_RESET} Остановка сервиса awg-warp-auto..."
	/etc/init.d/awg-warp-auto stop 2>/dev/null || true
	/etc/init.d/awg-warp-auto disable 2>/dev/null || true

	echo "${C_CYAN}[2/5]${C_RESET} Удаление сетевых интерфейсов..."
	warp_iface=$(uci -q get awg-warp-auto.main.interface 2>/dev/null || true)
	[ -n "$warp_iface" ] || warp_iface="YTwarp"

	if [ "$uninst_scope" = "2" ]; then
		# Полное удаление всех amneziawg интерфейсов
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
	else
		# Безопасное удаление только YTwarp
		ifdown "$warp_iface" 2>/dev/null || true
		ip link del dev "$warp_iface" 2>/dev/null || true
		uci -q delete "network.$warp_iface" || true
		uci -q delete "network.${warp_iface}_ipv4_egress" || true
		uci -q delete "network.${warp_iface}_ipv4_mark" || true
		for r in $(uci -q show network | grep "\.interface='$warp_iface'" | cut -d. -f2 | cut -d= -f1); do
			uci -q delete "network.$r" || true
		done
		for peer in $(uci -q show network 2>/dev/null | grep -E "=amneziawg_${warp_iface}\$|warp_auto_peer_" | cut -d. -f2 | cut -d= -f1); do
			uci -q delete "network.$peer" || true
		done
		uci -q delete "network.amneziawg_${warp_iface}" || true
	fi
	uci commit network 2>/dev/null || true

	# Удаление связанной секции Forkop (только созданной нами)
	if [ -f /etc/config/forkop ]; then
		managed_forkop_sec=$(uci -q get awg-warp-auto.main.forkop_section || true)
		if [ -z "$managed_forkop_sec" ]; then
			managed_forkop_sec=$(uci -q show forkop | grep "\.name='${warp_iface:-YTwarp}'" | cut -d. -f2 | cut -d= -f1)
			[ -n "$managed_forkop_sec" ] && managed_forkop_sec=$(uci -q get "forkop.$managed_forkop_sec.section" || true)
		fi
		if [ -n "$managed_forkop_sec" ] && uci -q get "forkop.$managed_forkop_sec" >/dev/null 2>&1; then
			echo "${C_CYAN}[2.5/5]${C_RESET} Удаление секции Forkop '$managed_forkop_sec'..."
			uci -q delete "forkop.$managed_forkop_sec" || true
			for si in $(uci -q show forkop | grep "\.section='$managed_forkop_sec'" | cut -d. -f2 | cut -d= -f1); do
				uci -q delete "forkop.$si" || true
			done
			uci commit forkop 2>/dev/null || true
			/etc/init.d/forkop reload 2>/dev/null || true
			echo "${C_GREEN}[✓] Секция Forkop '$managed_forkop_sec' удалена, sing-box обновлен${C_RESET}"
		fi
	fi

	echo "${C_CYAN}[3/5]${C_RESET} Удаление компонентов приложения..."
	if [ "$uninst_scope" = "2" ]; then
		if command -v apk >/dev/null 2>&1; then
			apk del luci-proto-amneziawg awg-warp-auto-quic amneziawg-tools kmod-amneziawg 2>/dev/null || true
		elif command -v opkg >/dev/null 2>&1; then
			opkg remove luci-proto-amneziawg awg-warp-auto-quic amneziawg-tools kmod-amneziawg 2>/dev/null || true
		fi
		rmmod amneziawg 2>/dev/null || true
		rm -f /usr/bin/awg /lib/modules/*/amneziawg.ko /lib/netifd/proto/amneziawg.sh
		rm -rf /www/luci-static/resources/protocol/amneziawg.js /www/luci-static/resources/icons/amneziawg.svg
	else
		if command -v apk >/dev/null 2>&1; then
			apk del luci-proto-amneziawg awg-warp-auto-quic 2>/dev/null || true
		elif command -v opkg >/dev/null 2>&1; then
			opkg remove luci-proto-amneziawg awg-warp-auto-quic 2>/dev/null || true
		fi
	fi
	rm -f /usr/bin/quic-i1
	rm -rf /etc/config/awg-warp-auto /etc/init.d/awg-warp-auto /etc/awg-warp-auto /usr/libexec/awg-warp-auto
	rm -f /usr/share/rpcd/ucode/luci.amneziawg /usr/share/rpcd/acl.d/luci-amneziawg.json /usr/share/luci/menu.d/luci-proto-amneziawg.json /usr/share/ucode/luci/controller/awgdownload.uc
	rm -rf /www/luci-static/resources/view/amneziawg
	[ "$uninst_scope" = "2" ] && rm -rf /www/luci-static/resources/protocol/amneziawg.js /www/luci-static/resources/icons/amneziawg.svg
	rm -rf /tmp/luci-indexcache /tmp/awg-warp-auto* /tmp/quic*

	echo "${C_CYAN}[4/5]${C_RESET} Перезапуск служб сети и веб-интерфейса..."
	ubus call network reload 2>/dev/null || true
	/etc/init.d/rpcd restart 2>/dev/null || true
	if [ -f /etc/init.d/forkop ]; then
		/etc/init.d/forkop restart 2>/dev/null || true
	fi

	echo "${C_CYAN}[5/5]${C_RESET} Завершено."
	echo ""
	echo "${C_GREEN}======================================================================${C_RESET}"
	echo "${C_BOLD}${C_GREEN} [✓] Удаление успешно завершено!                                      ${C_RESET}"
	echo "     Сторонние сетевые интерфейсы и службы сохранены.                 "
	echo "${C_GREEN}======================================================================${C_RESET}"
	exit 0
fi

# --------------------------------------------------------------------
# 2. СКАЧИВАНИЕ РЕЛИЗНОГО ПАКЕТА И ПРОВЕРКА ЦЕЛОСТНОСТИ
# --------------------------------------------------------------------
ARCHIVE="/tmp/awg-warp-auto-release.tar.gz"

download_file() {
	local target="$1"
	local url="$2"
	local mirror="$3"
	rm -f "$target"
	# Прямой запрос к GitHub
	if command -v curl >/dev/null 2>&1; then
		curl -k -fsSL --connect-timeout 8 --max-time 30 "$url" -o "$target" 2>/dev/null || true
	fi
	if [ ! -s "$target" ] && command -v wget >/dev/null 2>&1; then
		wget -q --no-check-certificate -T 20 -O "$target" "$url" 2>/dev/null || true
	fi
	# Резервное зеркало только если прямой запрос вернул пустоту
	if [ ! -s "$target" ] && [ -n "$mirror" ]; then
		if command -v curl >/dev/null 2>&1; then
			curl -k -fsSL --connect-timeout 8 --max-time 30 "$mirror" -o "$target" 2>/dev/null || true
		fi
		if [ ! -s "$target" ] && command -v wget >/dev/null 2>&1; then
			wget -q --no-check-certificate -T 20 -O "$target" "$mirror" 2>/dev/null || true
		fi
	fi
	[ -s "$target" ]
}

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
if [ -f "$SCRIPT_DIR/dist/awg-warp-auto-release.tar.gz" ]; then
	echo "${C_CYAN}---> Используется локальный релизный архив из dist/...${C_RESET}"
	cp "$SCRIPT_DIR/dist/awg-warp-auto-release.tar.gz" "$ARCHIVE"
elif [ -f "$SCRIPT_DIR/release/awg-warp-auto-release.tar.gz" ]; then
	echo "${C_CYAN}---> Используется локальный релизный архив из release/...${C_RESET}"
	cp "$SCRIPT_DIR/release/awg-warp-auto-release.tar.gz" "$ARCHIVE"
else
	rm -f "$ARCHIVE"
	CACHE_BUST="?t=$(date +%s 2>/dev/null || echo 1)"
	MIRROR_URL="https://gh-proxy.com/${RELEASE_URL}"
	if ! download_file "$ARCHIVE" "${RELEASE_URL}${CACHE_BUST}" "${MIRROR_URL}${CACHE_BUST}"; then
		echo "${C_RED}[ОШИБКА] Не удалось скачать релизный архив ($RELEASE_URL)!${C_RESET}" >&2
		echo "Проверьте доступность интернета на роутере." >&2
		exit 1
	fi
fi

# Проверка целостности SHA-256
echo "${C_CYAN}---> Проверка цифровой контрольной суммы архива (SHA-256)...${C_RESET}"
CACHE_BUST="?t=$(date +%s 2>/dev/null || echo 1)"
CHECKSUM_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${COMMIT_REF}/SHA256SUMS"
MIRROR_CHECKSUM="https://gh-proxy.com/${CHECKSUM_URL}"
TMP_CHECKSUMS="/tmp/SHA256SUMS.$$"
EXPECTED_SHA=""
if download_file "$TMP_CHECKSUMS" "${CHECKSUM_URL}${CACHE_BUST}" "${MIRROR_CHECKSUM}${CACHE_BUST}"; then
	EXPECTED_SHA=$(grep "awg-warp-auto-release\.tar\.gz" "$TMP_CHECKSUMS" 2>/dev/null | awk '{print $1}' || true)
	rm -f "$TMP_CHECKSUMS"
fi

if [ -n "$EXPECTED_SHA" ]; then
	ACTUAL_SHA=$(sha256sum "$ARCHIVE" 2>/dev/null | awk '{print $1}')
	if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
		if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
			echo "${C_YELLOW}[ВНИМАНИЕ] Несовпадение SHA-256 с удаленным индексом (кеш CDN GitHub).${C_RESET}"
			echo "${C_YELLOW}           Архив валиден и успешно читается, установка продолжается.${C_RESET}"
		else
			echo "${C_RED}[КРИТИЧЕСКАЯ ОШИБКА] Контрольная сумма SHA-256 не совпадает и архив поврежден!${C_RESET}" >&2
			echo "Ожидалось: $EXPECTED_SHA" >&2
			echo "Получено:   $ACTUAL_SHA" >&2
			echo "Возможна ошибка загрузки. Установка прервана." >&2
			rm -f "$ARCHIVE"
			exit 1
		fi
	else
		echo "${C_GREEN}[✓] Целостность проверена: SHA-256 совпадает ($ACTUAL_SHA).${C_RESET}"
	fi
fi

# Резервная копия текущей сети перед распаковкой и установкой
if [ -f /etc/config/network ]; then
	PRE_INST_BAK="/etc/config/network.pre-awg-warp-auto.$(date +%s).bak"
	cp /etc/config/network "$PRE_INST_BAK"
	echo "${C_GREEN}[✓] Создан резервный бэкап сетевых настроек: $PRE_INST_BAK${C_RESET}"
fi

echo "${C_CYAN}---> Распаковка пакета...${C_RESET}"
rm -rf /tmp/awg-warp-auto-release
mkdir -p /tmp/awg-warp-auto-release
tar -xzf "$ARCHIVE" -C /tmp/awg-warp-auto-release
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
# 4. ПЕРВЫЙ ПРОФИЛЬ И ИНТЕРФЕЙС (BOOTSTRAP)
# --------------------------------------------------------------------
echo ""
echo "${C_CYAN}=== Начальная настройка WARP ===${C_RESET}"
warp_target_iface=$(uci -q get awg-warp-auto.main.interface || echo "YTwarp")
bootstrap_ok=0
if lsmod | grep -q amneziawg; then
	prompt_user gen_first "${C_BOLD}${C_YELLOW}Сгенерировать и активировать первый WARP-профиль прямо сейчас? [Y/n]: ${C_RESET}" "Y"
	case "$gen_first" in
		[nN]|[nN][oO]|[нН]|[нН][еЕ][тТ])
			echo "Вы можете сгенерировать профиль позже через LuCI: Services -> AmneziaWG"
			;;
		*)
			echo "${C_CYAN}---> Генерация первого рабочего WARP-профиля (Native Cloudflare API)...${C_RESET}"
			/etc/init.d/awg-warp-auto stop 2>/dev/null || true
			rm -rf /var/run/awg-warp-auto.lock
			for attempt in 1 2 3; do
				printf "${C_CYAN}[Попытка %d/3]${C_RESET} Регистрация и проверка AmneziaWG туннеля...\n" "$attempt"
				if /usr/libexec/awg-warp-auto/daemon.sh bootstrap; then
					if uci -q get "network.$warp_target_iface" >/dev/null 2>&1; then
						echo "${C_GREEN}[✓] Интерфейс $warp_target_iface успешно создан, активирован и протестирован!${C_RESET}"
						bootstrap_ok=1
						break
					fi
				fi
				b_state=$(uci -q get awg-warp-auto.main.bootstrap_state || true)
				b_err=$(uci -q get awg-warp-auto.main.bootstrap_error || true)
				echo "${C_YELLOW}  -> Попытка $attempt не удалась (${b_state:-failed}: ${b_err:-timeout/no response}).${C_RESET}"
				[ "$attempt" -lt 3 ] && sleep 3
			done

			if [ "$bootstrap_ok" -eq 1 ]; then
				echo "${C_GREEN}[✓] Первый WARP-туннель полностью готов к работе.${C_RESET}"
			else
				echo ""
				echo "${C_RED}[!] Не удалось автоматически создать первый профиль после 3 попыток.${C_RESET}"
				echo "${C_YELLOW}Причины:${C_RESET} временный лимит Cloudflare API (429) или блокировка DNS."
				echo "${C_BOLD}Что сделать дальше:${C_RESET}"
				echo "  1. В веб-интерфейсе: ${C_CYAN}Services -> AmneziaWG${C_RESET} -> нажмите «Сгенерировать профиль»"
				echo "  2. Или импортируйте свой .conf через вкладку «Импорт»"
				echo "  3. Или выполните в консоли: ${C_CYAN}/usr/libexec/awg-warp-auto/daemon.sh bootstrap${C_RESET}"
			fi
			;;
	esac
else
	echo "${C_YELLOW}[!] Модуль ядра AmneziaWG будет активирован после разовой перезагрузки: reboot${C_RESET}"
fi

# --------------------------------------------------------------------
# 5. ИНТЕГРАЦИЯ С FORKOP
# --------------------------------------------------------------------
echo ""
echo "${C_CYAN}=== Интеграция с Forkop (sing-box) ===${C_RESET}"
if [ -f /etc/config/forkop ] && [ -f /etc/init.d/forkop ]; then
	echo "${C_GREEN}[✓] Forkop обнаружен на роутере.${C_RESET}"
	prompt_user setup_forkop "${C_BOLD}${C_YELLOW}Создать секцию маршрутизации YouTube в Forkop для '$warp_target_iface'? [Y/n]: ${C_RESET}" "Y"
	case "$setup_forkop" in
		[nN]|[nN][oO]|[нН]|[нН][еЕ][тТ])
			echo "Пропуск настройки Forkop."
			;;
		*)
			# Find next unused name: YT, YT2, YT3...
			sec_name="YT"
			if uci -q get "forkop.$sec_name" >/dev/null 2>&1; then
				i=2
				while uci -q get "forkop.YT${i}" >/dev/null 2>&1; do
					i=$((i + 1))
				done
				sec_name="YT${i}"
			fi

			echo "${C_CYAN}---> Создание секции Forkop '$sec_name' для интерфейса '$warp_target_iface'...${C_RESET}"

			uci set "forkop.$sec_name=section"
			uci set "forkop.$sec_name.enabled=1"
			uci set "forkop.$sec_name.action=connection"
			uci set "forkop.$sec_name.sort_by_latency=1"
			uci set "forkop.$sec_name.outbound_detour_enabled=0"
			uci set "forkop.$sec_name.mixed_proxy_enabled=0"
			uci set "forkop.$sec_name.resolve_real_ip_for_routing=0"
			uci set "forkop.$sec_name.dashboard_filter_mode=disabled"
			uci set "forkop.$sec_name.domain=youtube.com
googlevideo.com
ytimg.com
youtube-nocookie.com
youtu.be
googleusercontent.com
ggpht.com
netlify.app
googleadservices.com
doubleclick.net
firebaseio.com
smarttube-tv.firebaseio.com
smarttube-tv.firebasestorage.app
sponsor.ajay.app
sponsorblock.org
dearrow.ajay.app
returnyoutubedislikeapi.com
api.github.com
raw.githubusercontent.com
objects.githubusercontent.com
yting.com
youtubekids.com
yt.be
wide-youtube.l.google.com
ytimg.l.google.com
youtubei.googleapis.com
youtube.googleapis.com
youtubeembeddedplayer.googleapis.com
youtube-ui.l.google.com
yt-video-upload.l.google.com
jnn-pa.googleapis.com
yt3.googleusercontent.com
yt.ggpht.com
yt3.ggpht.com
yt4.ggpht.com
img.youtube.com
i.ytimg.com
i1.ytimg.com
i2.ytimg.com
i3.ytimg.com
i4.ytimg.com
i5.ytimg.com
i6.ytimg.com
i7.ytimg.com
i8.ytimg.com
i9.ytimg.com
s.ytimg.com
manifest.googlevideo.com
gstatic.com
googleapis.com
l.google.com
1e100.net
gvt1.com
gvt2.com
gvt3.com
gvt4.com
play.google.com
play.googleapis.com
play-fe.googleapis.com
android.clients.google.com
play-lh.googleusercontent.com
nhacmp3youtube.com
withyoutube.com
m.youtube.com
music.youtube.com
studio.youtube.com
tv.youtube.com
kids.youtube.com
s.youtube.com
cdn.youtube.com
signaler-pa.youtube.com
speed.cloudflare.com
2ip.io"

			for s in $(uci -q show forkop | grep "\.section='$sec_name'" | cut -d. -f2 | cut -d= -f1); do
				uci -q delete "forkop.$s"
			done

			sif=$(uci add forkop section_interface)
			uci set "forkop.$sif.section=$sec_name"
			uci set "forkop.$sif.name=$warp_target_iface"
			uci set "forkop.$sif.domain_resolver_enabled=0"
			uci set "forkop.$sif.domain_resolver_dns_type=udp"
			uci set "forkop.$sif.domain_resolver_dns_server=8.8.8.8"
			uci commit forkop

			uci -q set "awg-warp-auto.main.forkop_section=$sec_name"
			uci -q commit awg-warp-auto

			/etc/init.d/forkop reload 2>/dev/null || true
			echo "${C_GREEN}[✓] Секция Forkop '$sec_name' успешно создана и применена!${C_RESET}"
			;;
	esac
else
	echo "${C_YELLOW}[!] Forkop не обнаружен на роутере.${C_RESET}"
	echo "    Forkop позволяет направлять трафик отдельных сервисов (YouTube, Discord и др.)"
	echo "    в туннель WARP, оставляя весь остальной трафик прямым."
	prompt_user install_forkop "${C_BOLD}${C_YELLOW}Хотите установить Forkop прямо сейчас? [y/N]: ${C_RESET}" "N"
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

# Запуск службы в фоне, если включена
if [ "$(uci -q get awg-warp-auto.main.enabled)" = "1" ]; then
	/etc/init.d/awg-warp-auto start 2>/dev/null || true
fi

echo ""
if [ "${bootstrap_ok:-1}" -eq 1 ]; then
	echo "${C_GREEN}======================================================================${C_RESET}"
	echo "${C_BOLD}${C_GREEN} [✓] Установка WARP Auto успешно завершена!                           ${C_RESET}"
	echo "     Интерфейс YTwarp готов для маршрутизации в Forkop.               "
	echo "     Веб-интерфейс: Services -> AmneziaWG                             "
	echo "     Рекомендуется перезагрузить роутер: reboot                       "
	echo "${C_GREEN}======================================================================${C_RESET}"
else
	echo "${C_YELLOW}======================================================================${C_RESET}"
	echo "${C_BOLD}${C_YELLOW} [!] Пакеты установлены, но профиль WARP еще не поднят.               ${C_RESET}"
	echo "     Перед включением YouTube в Forkop создайте профиль в Services -> AmneziaWG"
	echo "     Рекомендуется перезагрузить роутер: reboot                       "
	echo "${C_YELLOW}======================================================================${C_RESET}"
fi
