#!/bin/sh
# Lightweight diagnostic pre-check for AmneziaWG & WARP Auto
# Checks OS, kernel, DNS, Cloudflare API, Anycast endpoints and Forkop
set -u

C_RESET=$(printf '\033[0m' 2>/dev/null || true)
C_RED=$(printf '\033[1;31m' 2>/dev/null || true)
C_GREEN=$(printf '\033[1;32m' 2>/dev/null || true)
C_YELLOW=$(printf '\033[1;33m' 2>/dev/null || true)
C_CYAN=$(printf '\033[1;36m' 2>/dev/null || true)
C_BOLD=$(printf '\033[1m' 2>/dev/null || true)

PASS_ICON="${C_GREEN}[✓]${C_RESET}"
WARN_ICON="${C_YELLOW}[!]${C_RESET}"
FAIL_ICON="${C_RED}[✗]${C_RESET}"

WARNINGS=0
ERRORS=0

echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
echo "${C_BOLD}${C_CYAN}      WARP Auto & AmneziaWG — Экспресс-диагностика системы            ${C_RESET}"
echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
echo ""

# --------------------------------------------------------------------
# 1. СИСТЕМА И ОКРУЖЕНИЕ
# --------------------------------------------------------------------
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

MEM_FREE=$(awk '/MemAvailable/ { print int($2/1024) }' /proc/meminfo 2>/dev/null || awk '/MemFree/ { print int($2/1024) }' /proc/meminfo 2>/dev/null || echo 0)
echo "   Свободно RAM : ${MEM_FREE} MB"
if [ "$MEM_FREE" -lt 30 ] && [ "$MEM_FREE" -gt 0 ]; then
	echo "   $WARN_ICON Мало свободной памяти (<30MB)"
	WARNINGS=$((WARNINGS + 1))
fi

# --------------------------------------------------------------------
# 2. МОДУЛЬ AMNEZIAWG
# --------------------------------------------------------------------
echo ""
echo "${C_BOLD}2. Состояние AmneziaWG:${C_RESET}"
if lsmod 2>/dev/null | grep -q amneziawg; then
	echo "   $PASS_ICON Модуль ядра kmod-amneziawg: загружен"
else
	kmod_file="/lib/modules/$(uname -r 2>/dev/null)/amneziawg.ko"
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

# --------------------------------------------------------------------
# 3. DNS РЕЗОЛВЕРЫ
# --------------------------------------------------------------------
echo ""
echo "${C_BOLD}3. Доступность DNS-серверов:${C_RESET}"
check_dns() {
	local ip=$1 name=$2
	local res
	res=$(nslookup -timeout=2 www.google.com "$ip" 2>/dev/null | awk '/^Address:|^Address [0-9]+:/ { if ($NF !~ /:53$/) { print $NF; exit } }' || true)
	if [ -z "$res" ]; then
		res=$(nslookup www.google.com "$ip" 2>/dev/null | awk '/^Address:|^Address [0-9]+:/ { if ($NF !~ /:53$/) { print $NF; exit } }' || true)
	fi
	if [ -n "$res" ]; then
		echo "   $PASS_ICON $name ($ip): OK (IP: $res)"
		return 0
	else
		echo "   $FAIL_ICON $name ($ip): НЕТ ОТВЕТА (возможно, блокируется провайдером)"
		return 1
	fi
}

dns_ok=0
check_dns "77.88.8.8" "Yandex DNS" && dns_ok=1 || true
check_dns "8.8.8.8" "Google DNS" && dns_ok=1 || true
check_dns "1.1.1.1" "Cloudflare DNS" && dns_ok=1 || true

if [ "$dns_ok" -eq 0 ]; then
	echo "   $FAIL_ICON Все внешние DNS-серверы заблокированы или недоступны!"
	ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------
# 4. CLOUDFLARE WARP API
# --------------------------------------------------------------------
echo ""
echo "${C_BOLD}4. Доступность Cloudflare WARP Registration API:${C_RESET}"

check_cf_api() {
	local resolve_ip=$1
	local label=$2
	local dummy_pub
	if command -v awg >/dev/null 2>&1; then
		dummy_pub=$(awg genkey 2>/dev/null | awg pubkey 2>/dev/null || echo "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")
	else
		dummy_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
	fi
	local tos
	tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "2026-09-14T00:00:00.000Z")
	local body="{\"install_id\":\"\",\"tos\":\"$tos\",\"key\":\"$dummy_pub\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}"
	local t_start t_end latency
	t_start=$(date +%s%3N 2>/dev/null || date +%s000)

	local code
	code=$(curl -sS -k -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 7 \
		-A 'okhttp/3.12.1' -H 'Content-Type: application/json' \
		--resolve api.cloudflareclient.com:443:"$resolve_ip" \
		-d "$body" "https://api.cloudflareclient.com/v0i1909051800/reg" 2>/dev/null || true)
	code=$(printf '%s' "$code" | tail -c 3)

	t_end=$(date +%s%3N 2>/dev/null || date +%s000)
	latency=$((t_end - t_start))
	[ "$latency" -ge 0 ] 2>/dev/null || latency=0

	case "$code" in
		200|201)
			echo "   $PASS_ICON $label ($resolve_ip): HTTP $code OK (${latency}ms) — Регистрация РАБОТАЕТ!"
			return 0
			;;
		401|400)
			echo "   $PASS_ICON $label ($resolve_ip): HTTP $code OK (${latency}ms) — API доступен и отвечает!"
			return 0
			;;
		429)
			echo "   $WARN_ICON $label ($resolve_ip): HTTP 429 Rate Limited (${latency}ms) — API доступен, но действует временный лимит Cloudflare (нужно подождать 5-10 мин)"
			WARNINGS=$((WARNINGS + 1))
			return 0
			;;
		000|'')
			echo "   $FAIL_ICON $label ($resolve_ip): ТАЙМАУТ / БЛОКИРОВКА (HTTP 000)"
			return 1
			;;
		*)
			echo "   $WARN_ICON $label ($resolve_ip): HTTP $code (${latency}ms)"
			return 0
			;;
	esac
}

cf_ok=0
check_cf_api "162.159.192.1" "Anycast IP #1" && cf_ok=1 || true
check_cf_api "162.159.193.1" "Anycast IP #2" && cf_ok=1 || true

if [ "$cf_ok" -eq 0 ]; then
	echo "   $FAIL_ICON Прямой доступ к API регистрации Cloudflare заблокирован провайдером!"
	ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------
# 5. СЕТЕВЫЕ ПОРТЫ WARP (UDP)
# --------------------------------------------------------------------
echo ""
echo "${C_BOLD}5. Проверка портов туннелей WARP:${C_RESET}"
echo "   (WARP использует AmneziaWG поверх портов 500, 4500, 1701, 7559 и 2408)"
for p in 500 4500 1701 7559 2408; do
	case "$p" in
		500)  desc="IKE / IPsec NAT-T (наиболее надежный в РФ)" ;;
		4500) desc="IPsec NAT-T (наиболее надежный в РФ)" ;;
		1701) desc="L2TP standard" ;;
		7559) desc="Cloudflare high-port" ;;
		2408) desc="Стандартный порт Wireguard/WARP (часто заблокирован ТСПУ)" ;;
	esac
	echo "   • Порт $p: $desc"
done

# --------------------------------------------------------------------
# 6. ТЕКУЩИЙ ДОСТУП К YOUTUBE
# --------------------------------------------------------------------
echo ""
echo "${C_BOLD}6. Проверка прямого доступа к YouTube:${C_RESET}"
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

# --------------------------------------------------------------------
# 7. FORKOP (SING-BOX)
# --------------------------------------------------------------------
echo ""
echo "${C_BOLD}7. Статус Forkop:${C_RESET}"
if [ -f /etc/init.d/forkop ]; then
	if /etc/init.d/forkop running 2>/dev/null; then
		echo "   $PASS_ICON Forkop установлен и ЗАПУЩЕН"
	else
		echo "   $WARN_ICON Forkop установлен, но остановлен"
	fi
	existing_secs=$(uci -q show forkop 2>/dev/null | grep '=section$' | cut -d. -f2 | cut -d= -f1 | tr '\n' ' ' || true)
	if [ -n "$existing_secs" ]; then
		echo "   Секции Forkop: $existing_secs"
	fi
else
	echo "   $WARN_ICON Forkop не установлен на роутере (установщик предложит поставить автоматически)"
fi

# --------------------------------------------------------------------
# 8. ИТОГОВЫЙ ВЕРДИКТ
# --------------------------------------------------------------------
echo ""
echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
if [ "$ERRORS" -eq 0 ] && [ "$cf_ok" -eq 1 ]; then
	echo "${C_BOLD}${C_GREEN} [✓] СИСТЕМА ПОЛНОСТЬЮ ГОТОВА К УСТАНОВКЕ WARP AUTO!                   ${C_RESET}"
	echo "     API регистрации Cloudflare отвечает, Anycast-маршрутизация открыта."
	echo "     Можно смело запускать скрипт установки."
elif [ "$cf_ok" -eq 0 ]; then
	echo "${C_BOLD}${C_RED} [✗] ВНИМАНИЕ: Cloudflare API заблокирован провайдером.                ${C_RESET}"
	echo "     Для генерации профилей потребуется рабочий обход или ручной импорт .conf"
else
	echo "${C_BOLD}${C_YELLOW} [!] СИСТЕМА ГОТОВА, НО ИМЕЮТСЯ ПРЕДУПРЕЖДЕНИЯ (см. выше).           ${C_RESET}"
fi
echo "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
echo ""
