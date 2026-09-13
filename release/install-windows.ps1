param(
    [switch]$Uninstall
)

# Requires -Version 5.1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Action = if ($Uninstall) { "uninstall" } else { "install" }

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "     WARP Auto & AmneziaWG — Управление пакетами на OpenWrt           " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# Проверка клиента OpenSSH
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "[ОШИБКА] Клиент ssh не найден в системе Windows." -ForegroundColor Red
    Write-Host "Установите OpenSSH: Параметры -> Приложения -> Дополнительные компоненты -> OpenSSH Client."
    Read-Host "Нажмите Enter для выхода..."
    exit 1
}

if (-not $Uninstall) {
    Write-Host "Что вы хотите сделать?" -ForegroundColor Yellow
    Write-Host "  [1] Установить / Обновить WARP Auto & AmneziaWG (по умолчанию)"
    Write-Host "  [2] Полностью удалить WARP Auto & AmneziaWG (чистое состояние)"
    Write-Host ""
    $actChoice = Read-Host "Ваш выбор [1/2] (нажмите Enter для установки)"
    if ($actChoice -eq "2") {
        $Action = "uninstall"
    }
    Write-Host ""
}

if ($Action -eq "install" -and -not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Write-Host "[ОШИБКА] Утилита scp не найдена в системе Windows." -ForegroundColor Red
    Read-Host "Нажмите Enter для выхода..."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Выберите IP-адрес вашего роутера OpenWrt:" -ForegroundColor Yellow
Write-Host "  [1] 192.168.10.1 (по умолчанию)"
Write-Host "  [2] 192.168.1.1  (стандартный адрес OpenWrt)"
Write-Host "  [3] Ввести другой IP-адрес вручную"
Write-Host ""
$choice = Read-Host "Ваш выбор [1, 2, 3] (нажмите Enter для 192.168.10.1)"

$RouterIp = "192.168.10.1"
if ($choice -eq "2") {
    $RouterIp = "192.168.1.1"
} elseif ($choice -eq "3") {
    $custom = Read-Host "Введите IP-адрес роутера"
    if (-not [string]::IsNullOrWhiteSpace($custom)) {
        $RouterIp = $custom.Trim()
    }
}

$RouterUser = "root"
Write-Host ""
Write-Host ("Подключение к: " + $RouterUser + "@" + $RouterIp) -ForegroundColor Green
Write-Host "----------------------------------------------------------------------"
Write-Host "При запросе пароля введите пароль пользователя root вручную."
Write-Host "(Если роутер только что прошит и пароль еще не задан, нажмите Enter)."
Write-Host "----------------------------------------------------------------------"
Write-Host ""

if ($Action -eq "uninstall") {
    Read-Host "Нажмите Enter для начала удаления..."
    Write-Host ""
    Write-Host "[1/1] Запуск полного удаления на роутере..." -ForegroundColor Yellow
    $remoteHost = $RouterUser + "@" + $RouterIp
    $uninstallCmd = "echo '[1/6] Остановка сервиса awg-warp-auto...'; " +
        "/etc/init.d/awg-warp-auto stop 2>/dev/null || true; /etc/init.d/awg-warp-auto disable 2>/dev/null || true; " +
        "echo '[2/6] Удаление всех интерфейсов и маршрутов с proto=amneziawg...'; " +
        "for iface in `$(uci -q show network | grep '\.proto=.amneziawg.' | cut -d. -f2 | cut -d= -f1); do " +
        "  ifdown `$iface 2>/dev/null || true; " +
        "  uci -q delete network.`$iface || true; " +
        "  uci -q delete network.`${iface}_ipv4_egress || true; " +
        "  uci -q delete network.`${iface}_ipv4_mark || true; " +
        "  for r in `$(uci -q show network | grep \"\.interface='`$iface'\" | cut -d. -f2 | cut -d= -f1); do " +
        "    uci -q delete network.`$r || true; " +
        "  done; " +
        "done; " +
        "for peer in `$(uci -q show network | grep '=amneziawg_' | cut -d. -f2 | cut -d= -f1); do " +
        "  uci -q delete network.`$peer || true; " +
        "done; " +
        "uci commit network 2>/dev/null || true; " +
        "echo '[3/6] Удаление пакетов apk...'; " +
        "apk del luci-proto-amneziawg awg-warp-auto-quic amneziawg-tools kmod-amneziawg 2>/dev/null || true; " +
        "echo '[4/6] Выгрузка модуля ядра...'; " +
        "rmmod amneziawg 2>/dev/null || true; " +
        "echo '[5/6] Удаление файлов приложения, модулей и настроек...'; " +
        "rm -f /usr/bin/quic-i1 /usr/bin/awg '/lib/modules/*/amneziawg.ko' /lib/netifd/proto/amneziawg.sh; " +
        "rm -rf /etc/config/awg-warp-auto /etc/init.d/awg-warp-auto /etc/awg-warp-auto /usr/libexec/awg-warp-auto; " +
        "rm -f /usr/share/rpcd/ucode/luci.amneziawg /usr/share/rpcd/acl.d/luci-amneziawg.json /usr/share/luci/menu.d/luci-proto-amneziawg.json /usr/share/ucode/luci/controller/awgdownload.uc; " +
        "rm -rf /www/luci-static/resources/view/amneziawg /www/luci-static/resources/protocol/amneziawg.js /www/luci-static/resources/icons/amneziawg.svg /tmp/luci-indexcache /tmp/awg-warp-auto* /tmp/quic*; " +
        "echo '[6/6] Перезапуск сети и веб-интерфейса...'; " +
        "/etc/init.d/network reload 2>/dev/null || true; /etc/init.d/rpcd restart 2>/dev/null || true; " +
        "echo ''; echo '======================================================================'; " +
        "echo ' [УСПЕХ] WARP Auto и AmneziaWG полностью удалены с роутера!'; " +
        "echo ' Forkop сохранен и не затронут.'; " +
        "echo ' Рекомендуется перезагрузить роутер: reboot'; " +
        "echo '======================================================================'"

    & ssh -t -o StrictHostKeyChecking=accept-new "$remoteHost" "$uninstallCmd"
    Write-Host ""
    Read-Host "Нажмите Enter для завершения..."
    exit 0
}

$ArchiveFile = Join-Path $ScriptDir "awg-warp-auto-release.tar.gz"
if (-not (Test-Path $ArchiveFile)) {
    $candidates = Get-ChildItem -Path $ScriptDir -Filter "awg-warp-auto-*.tar.gz" -ErrorAction SilentlyContinue
    if ($candidates) {
        $ArchiveFile = $candidates[0].FullName
    } else {
        Write-Host "[ОШИБКА] Файл awg-warp-auto-release.tar.gz не найден в папке со скриптом!" -ForegroundColor Red
        Read-Host "Нажмите Enter для выхода..."
        exit 1
    }
}

Write-Host ""
Write-Host ("[1/2] Копирование установочного пакета на роутер (" + $RouterIp + ")...") -ForegroundColor Yellow

$targetRemote = $RouterUser + "@" + $RouterIp + ":/tmp/awg-warp-auto-release.tar.gz"
& scp -o StrictHostKeyChecking=accept-new "$ArchiveFile" "$targetRemote"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ИНФО] Повторная попытка scp с ключом -O..." -ForegroundColor Yellow
    & scp -O -o StrictHostKeyChecking=accept-new "$ArchiveFile" "$targetRemote"
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "[ОШИБКА] Не удалось скопировать установочный пакет на роутер!" -ForegroundColor Red
        Write-Host ("Проверьте сетевой кабель, выбранный IP (" + $RouterIp + ") и пароль root.")
        Read-Host "Нажмите Enter для выхода..."
        exit 1
    }
}

Write-Host ""
Write-Host "[2/2] Распаковка и запуск установки на роутере..." -ForegroundColor Yellow
Write-Host "(При необходимости введите пароль root повторно для SSH сессии)"
Write-Host ""

$remoteHost = $RouterUser + "@" + $RouterIp
$remoteCmd = "cd /tmp && rm -rf awg-warp-auto-release && tar -xzf awg-warp-auto-release.tar.gz && cd awg-warp-auto-release && sh ./install.sh && rm -f /tmp/awg-warp-auto-release.tar.gz"
& ssh -t -o StrictHostKeyChecking=accept-new "$remoteHost" $remoteCmd

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[ОШИБКА] Скрипт установки на роутере завершился с ошибкой." -ForegroundColor Red
    Read-Host "Нажмите Enter для выхода..."
    exit 1
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host " [УСПЕХ] WARP Auto и AmneziaWG успешно установлены на роутер!         " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Веб-интерфейс доступен в LuCI:"
$webUrl = "http://" + $RouterIp + "/cgi-bin/luci/admin/services/amneziawg"
Write-Host ("  " + $webUrl) -ForegroundColor Cyan
Write-Host ""
Read-Host "Нажмите Enter для завершения..."
