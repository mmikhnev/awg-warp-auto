# WARP Auto & AmneziaWG v3.1 для OpenWrt

[![VirusTotal](https://img.shields.io/badge/VirusTotal-Clean%20(0%20detections)-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/url/aHR0cHM6Ly9naXRodWIuY29tL21taWtobmV2L2F3Zy13YXJwLWF1dG8)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.x-00aae7?logo=openwrt)](https://openwrt.org)

Универсальный инструмент для OpenWrt, объединяющий:
- **Автоматический генератор и менеджер пула Cloudflare WARP** с мониторингом задержки, автопереключением (failover) и защитой от блокировок по протоколу AmneziaWG v3.1.
- **Удобный веб-интерфейс (LuCI)** для импорта и настройки любых `.conf` профилей AmneziaWG (v1.0, v2.0, v3.0, v3.1) и WireGuard в один клик.

Поддерживает OpenWrt 24.10 (`opkg`) и 25.x (`apk`) на архитектурах `aarch64`, `x86_64`, `mipsel`, `mips`, `arm`.

---

## Быстрый старт

Подключитесь к роутеру по SSH и выполните:

```sh
sh <(wget -qO- https://raw.githubusercontent.com/mmikhnev/awg-warp-auto/main/install.sh)
```
*(Для стандартной командной строки Busybox также подходит: `sh -c "$(wget -qO- https://raw.githubusercontent.com/mmikhnev/awg-warp-auto/main/install.sh)"`)*.

---

## Что умеет инсталлер

Скрипт автоматически определяет систему, архитектуру процессора и пакетный менеджер, предлагая интерактивное меню:

```text
======================================================================
          WARP Auto & AmneziaWG — Управление на OpenWrt               
======================================================================

  [1] Установка  — чистая установка AmneziaWG v3.1 + WARP Auto
  [2] Обновление — обновление компонентов и LuCI UI (пул сохраняется)
  [3] Удаление   — удаление AmneziaWG и WARP Auto
```

- **[1] Установка**:
  - Устанавливает необходимые системные зависимости (`curl`, `ca-bundle`, крипто-модули ядра).
  - Ставит модуль ядра AmneziaWG v3.1 и загружает его на лету (`insmod`) без обязательной перезагрузки.
  - Устанавливает утилиту `awg`, генератор пакетов QUIC `quic-i1` и веб-интерфейс для LuCI.
  - Предлагает сразу сгенерировать и поднять рабочий интерфейс `YTwarp`.
  - При желании помогает установить [Forkop](https://github.com/ushan0v/forkop) в один шаг, если он еще не установлен.

- **[2] Обновление**:
  - Обновляет бинарные файлы и интерфейс LuCI до актуальной версии.
  - Полностью сохраняет накопленный пул рабочих профилей и все настройки в `/etc/config/awg-warp-auto`.

- **[3] Удаление**:
  - Корректно удаляет интерфейс `YTwarp`, связанные маршруты и правила.
  - Не затрагивает сторонние интерфейсы, другие VPN-соединения и системные службы.

---

## Установка с компьютера (Windows / Linux / macOS)

Если роутер еще не имеет прямого доступа в интернет или удобнее выполнить установку с ПК:

1. Скачайте архив [`dist/awg-warp-auto-installer.zip`](https://github.com/mmikhnev/awg-warp-auto/raw/main/dist/awg-warp-auto-installer.zip).
2. Распакуйте архив в любую папку.
3. Запустите подходящий файл:
   - **Windows:** `install-windows.bat` (или `install-windows.ps1`)
   - **Linux / macOS:** `./install-linux.sh`
4. Скрипт запросит IP-адрес роутера (по умолчанию `192.168.10.1`), подключится по SSH и выполнит установку всех компонентов.

---

## Совместная работа с Forkop и другими VPN

Интерфейс `YTwarp` создается как стандартный сетевой интерфейс OpenWrt с изолированной таблицей маршрутизации (таблица 101, fwmark `0x01000000`). Это позволяет использовать его в любых сценариях выборочного обхода блокировок:

1. В веб-интерфейсе **Forkop**:
   - Перейдите в секцию (например, **YouTube** или **Discord**).
   - В поле **Network Interface** выберите интерфейс **`YTwarp`**.
   - Сохраните изменения.
2. Трафик выбранных сервисов пойдет через туннель Cloudflare WARP с защитой от DPI (AmneziaWG v3.1), а весь остальной трафик пойдет напрямую через провайдера либо через ваш основной рабочий VPN.

---

## Импорт любых конфигураций AmneziaWG в 1 клик

Помимо работы с пулом Cloudflare WARP, веб-интерфейс позволяет удобно управлять сторонними туннелями AmneziaWG и WireGuard без ручного редактирования файлов конфигурации:

1. Откройте в браузере **Services -> AmneziaWG**.
2. В блоке **Import AWG Profile** перетащите `.conf` файл или вставьте его текст. Поддерживаются:
   - **WireGuard** (стандартные конфигурации)
   - **AmneziaWG 1.0 / 2.0** (`Jc`, `Jmin`, `Jmax`, `S1`..`S4`, `H1`..`H4`)
   - **AmneziaWG 3.0 / 3.1** (`I1`..`I5`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `RandomTrailers`, `DisableCookies`)
3. Выберите существующий интерфейс (`YTwarp`) или введите имя для нового (например, `awg_vpn`).
4. Нажмите **Import & Apply** — параметры обфускации, ключи, адреса и пиры автоматически запишутся в сетевые настройки системы.
5. Чекбокс **Validate connectivity** позволяет сразу провести сквозную проверку туннеля и handshakes.

---

## Системные требования

Решение оптимизировано для устройств с небольшим объемом накопителя и памяти:
- **Размер на Flash (ROM):** **менее 1 МБ** (~700 КБ суммарно со всеми модулями).
  - `kmod-amneziawg`: ~100 КБ
  - `amneziawg-tools`: ~100 КБ
  - `awg-warp-auto-quic`: ~25 КБ
  - `luci-proto-amneziawg`: ~450 КБ
- **Оперативная память (RAM):** ~3–5 МБ при работе фонового сервиса.

---

## Безопасность и проверка на VirusTotal

Проект полностью открыт (Open Source), не содержит сторонней телеметрии или скрытых модулей. Контрольные суммы файлов и результаты онлайн-проверки:

| Компонент / Ссылка | SHA-256 контрольная сумма | Отчет VirusTotal |
| :--- | :--- | :--- |
| **Репозиторий проекта** (`GitHub URL`) | `https://github.com/mmikhnev/awg-warp-auto` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-Clean%20URL-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/url/aHR0cHM6Ly9naXRodWIuY29tL21taWtobmV2L2F3Zy13YXJwLWF1dG8) |
| **Онлайн-инсталлер** (`install.sh`) | `16fc1f12e596677802aed691163ffbbeba715b1b013a1cd9eeb11e592f471cf0` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-0%2F65-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/file/16fc1f12e596677802aed691163ffbbeba715b1b013a1cd9eeb11e592f471cf0) |
| **Релизный архив** (`awg-warp-auto-release.tar.gz`) | `729c8cdbc43bcc57d2ff205887de97541f346791bf6d3b742b972da22919fdae` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-0%2F65-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/file/729c8cdbc43bcc57d2ff205887de97541f346791bf6d3b742b972da22919fdae) |
| **Офлайн-установщик** (`awg-warp-auto-installer.zip`) | `6c57d2ccf0db4ad99cf4bb48ba9da2f95c891a0cf8099c899fe2432944fdd38f` | [![VirusTotal](https://img.shields.io/badge/VirusTotal-0%2F65-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/file/6c57d2ccf0db4ad99cf4bb48ba9da2f95c891a0cf8099c899fe2432944fdd38f) |


