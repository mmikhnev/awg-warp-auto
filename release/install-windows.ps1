# Requires -Version 5.1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "        Установка WARP Auto & AmneziaWG на роутер OpenWrt             " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# Проверка клиента OpenSSH
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "[ОШИБКА] Клиент ssh не найден в системе Windows." -ForegroundColor Red
    Write-Host "Установите OpenSSH: Параметры -> Приложения -> Дополнительные компоненты -> OpenSSH Client."
    Read-Host "Нажмите Enter для выхода..."
    exit 1
}

if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Write-Host "[ОШИБКА] Утилита scp не найдена в системе Windows." -ForegroundColor Red
    Read-Host "Нажмите Enter для выхода..."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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
Read-Host "Нажмите Enter для начала установки..."

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
