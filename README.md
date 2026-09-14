# WARP Auto & AmneziaWG v3.1 для OpenWrt

[![VirusTotal](https://img.shields.io/badge/VirusTotal-Clean%20(0%20detections)-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/url/aHR0cHM6Ly9naXRodWIuY29tL21taWtobmV2L2F3Zy13YXJwLWF1dG8)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.x-00aae7?logo=openwrt)](https://openwrt.org)

Автоматический генератор и менеджер отказоустойчивого пула Cloudflare WARP, а также **универсальный веб-интерфейс для создания сетевых интерфейсов AmneziaWG в 1 клик из любых `.conf` файлов** (поддержка обфускации v1.0, v2.0, v3.0 и v3.1).

Поддерживает OpenWrt 24.10 (`opkg`) и 25.x (`apk`) на всех популярных архитектурах роутеров (aarch64, x86_64, mipsel, mips, arm).

---

## Быстрая установка в одну команду

Подключитесь к роутеру по SSH и выполните:

```sh
sh <(wget -qO- https://raw.githubusercontent.com/mmikhnev/awg-warp-auto/main/install.sh)
```
*(Для стандартного busybox `ash` на чистом роутере также подходит: `sh -c "$(wget -qO- https://raw.githubusercontent.com/mmikhnev/awg-warp-auto/main/install.sh)"`)*.

---

## Системные требования и занимаемое место

Комплекс оптимизирован для минимального потребления ресурсов встраиваемых роутеров:
- **Размер на флеш-памяти (Flash / ROM):** **менее 1 МБ** (~700 КБ суммарно со всеми модулями).
  - `kmod-amneziawg`: ~100 КБ
  - `amneziawg-tools`: ~100 КБ
  - `awg-warp-auto-quic`: ~25 КБ
  - `luci-proto-amneziawg`: ~450 КБ
- **Оперативная память (RAM):** ~3–5 МБ в фоновом режиме демона.

---

## Возможности скрипта установки

При запуске доступно интерактивное меню:

```text
======================================================================
          WARP Auto & AmneziaWG — Управление на OpenWrt               
======================================================================

  [1] Установка  — полная установка AmneziaWG v3.1 + WARP Auto
  [2] Обновление — обновление компонентов и LuCI UI (пул сохраняется)
  [3] Удаление   — полное удаление AmneziaWG и WARP Auto (Forkop цел)
```

1. **[1] Установка:**
   - Автоматически устанавливает зависимости (`curl`, `ca-bundle`, крипто-модули ядра и `kmod-udptunnel`).
   - Устанавливает модуль ядра AmneziaWG v3.1 и загружает его **на лету** (`insmod`), исключая обязательную немедленную перезагрузку.
   - Устанавливает `amneziawg-tools` (v3.1 `awg`), локальный генератор `quic-i1` и веб-интерфейс `luci-proto-amneziawg`.
   - **Интеграция с Forkop:** проверяет наличие Forkop на роутере. Если Forkop не установлен — предлагает установить его в один клик из официального репозитория [Forkop](https://github.com/ushan0v/forkop).
   - **Первый запуск:** предлагает сразу же сгенерировать и поднять первый рабочий профиль (интерфейс `YTwarp`) через прямое Cloudflare Registration API.

2. **[2] Обновление:**
   - Обновляет бинарники, сервисы и интерфейс LuCI.
   - Полностью сохраняет текущий пул профилей и пользовательские настройки в `/etc/config/awg-warp-auto`.

3. **[3] Полное удаление:**
   - Динамически определяет и удаляет все интерфейсы с `proto='amneziawg'`.
   - Очищает связанные правила маршрутизации, удаляет установленные `.apk` пакеты и выгружает модуль ядра.
   - **Никогда не ломает Forkop** и общие системные утилиты.

---

## Установка с компьютера (Windows / Linux)

Если на роутере нет прямого доступа к GitHub во время первоначальной настройки:

1. Скачайте архив [`dist/awg-warp-auto-installer.zip`](https://github.com/mmikhnev/awg-warp-auto/raw/main/dist/awg-warp-auto-installer.zip).
2. Распакуйте архив на компьютере.
3. Запустите:
   - **Windows:** двойным кликом `install-windows.bat`.
   - **Linux / macOS:** `./install-linux.sh`.
4. Скрипт сам спросит IP роутера (по умолчанию `192.168.10.1`), подключится по SSH, скопирует файлы и выполнит установку или удаление.

---

## Совместная работа с Forkop

Приложение идеально дополняет **Forkop** (раздельное туннелирование на базе Sing-box):

1. В WARP Auto создается интерфейс **`YTwarp`** с активным AmneziaWG туннелем до Cloudflare.
2. В веб-интерфейсе **Forkop**:
   - Перейдите в секцию (например, `YouTube`).
   - В пункте **Network Interface** выберите интерфейс **`YTwarp`**.
   - Сохраните настройки.
3. Весь трафик выбранной секции (YouTube, Discord и т.д.) пойдет через устойчивый к блокировкам AmneziaWG v3.1 туннель, а остальной трафик провайдера останется прямым.

---

## Создание AmneziaWG интерфейсов из любых конфигов (в 1 клик)

Помимо автономной генерации пула Cloudflare WARP, наш веб-интерфейс решает главную боль настройки AmneziaWG на OpenWrt — **ручной перенос десятков параметров обфускации и ключей в UCI**:

1. В LuCI откройте меню **Services -> AmneziaWG**.
2. В секции **Import AWG Profile** перетащите `.conf` файл (или вставьте его текст) от любого стороннего VPN-сервиса либо личного VPS:
   - **WireGuard** (стандартные профили без обфускации)
   - **AmneziaWG 1.0 / 2.0** (`Jc`, `Jmin`, `Jmax`, `S1`..`S4`, `H1`..`H4`)
   - **AmneziaWG 3.0 / 3.1** (`I1`..`I5`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `RandomTrailers`, `DisableCookies`)
3. Выберите существующий интерфейс (например, `YTwarp`) или введите имя для создания нового интерфейса (например, `awg_vps`).
4. Нажмите **Import & Apply**:
   - Парсер мгновенно пропишет в систему сетевой интерфейс, пиров, крипто-ключи, эндпоинты и параметры маскировки в `/etc/config/network`.
   - Больше никакой ручной правки конфигов через терминал!
5. Опциональный чекбокс **Validate connectivity** сразу же проверит handshake и фактическую доступность сети/YouTube через созданный интерфейс.

---

## Ключевые особенности

- **Провайдер Native по умолчанию:** Генерация ключей и прямая регистрация через официальный эндпоинт Cloudflare. Не зависит от внешних сайтов с готовыми конфигами, которые могут быть заблокированы провайдером.
- **Байпас DNS Fake-IP:** Запросы регистрации защищены от зависаний при первичном старте Sing-box / Forkop.
- **Поддержка AWG v3.0 и v3.1:** Полная поддержка всех современных версий протокола AmneziaWG с защитой от DPI и блокировок.
- **Умное управление пулом:**
  - Активный профиль всегда закреплен первой строкой в таблице.
  - Кандидаты автоматически ранжируются по реальной скорости скачивания и задержке (RTT).
  - Кнопка **Delete all except active** открывает диалоговое окно с выбором количества профилей для автогенерации (по умолчанию `0` — только очистка без лишней траты лимитов).
  - Автоматический failover на лучший профиль при деградации текущего туннеля.

---

## Безопасность и проверка на VirusTotal

Проект является на 100% открытым (Open Source), не содержит скрытых модулей, майнеров или сторонней телеметрии. Все скрипты и релизные сборки верифицированы антивирусными движками VirusTotal:

| Компонент / Ссылка | SHA-256 контрольная сумма | Отчет VirusTotal |
| :--- | :--- | :--- |
| **Репозиторий проекта** (`GitHub URL`) | `https://github.com/mmikhnev/awg-warp-auto` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-Clean%20URL-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/url/aHR0cHM6Ly9naXRodWIuY29tL21taWtobmV2L2F3Zy13YXJwLWF1dG8) |
| **Онлайн-инсталлер** (`install.sh`) | `deda58f126c966e8a6ca4de4b7994fda77ea319a147f1f9e4bbafa6436b6aef5` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-0%2F65-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/file/deda58f126c966e8a6ca4de4b7994fda77ea319a147f1f9e4bbafa6436b6aef5) |
| **Релизный архив** (`awg-warp-auto-release.tar.gz`) | `2b9bb20634222328828cea3b2ffcc41c8c1fea4d1f452ed48078b4930ac34533` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-0%2F65-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/file/2b9bb20634222328828cea3b2ffcc41c8c1fea4d1f452ed48078b4930ac34533) |
| **Офлайн-установщик** (`awg-warp-auto-installer.zip`) | `6843f7984f56eed65dd1e03531496bd9f9cb1d0560ff6504414422b7eec48f32` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-0%2F65-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/file/6843f7984f56eed65dd1e03531496bd9f9cb1d0560ff6504414422b7eec48f32) |

