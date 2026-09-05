# WARP Auto / AmneziaWG — переносимый handoff

Это полный handoff текущего форка LuCI AmneziaWG с надстройкой **WARP Auto**.
Папка подготовлена для продолжения работы на Linux с другим агентом и для
сборки/install на чистый роутер после перепрошивки.

## Важное про OpenWrt 25

На OpenWrt 25 пакетный менеджер — `apk`; готовые пакеты имеют расширение
`.apk`. Не путать с Android APK. Старый `opkg`/`.ipk` нужен лишь на прежних
релизах OpenWrt и не является основной веткой этого проекта.

## Что лежит здесь

- `source/` — полный редактируемый исходный набор: upstream AWG stack,
  `luci-proto-amneziawg`, WARP Auto, optional QUIC helper и upstream installer.
- `release/` — проверенный overlay-релиз для установки на уже подготовленный
  роутер, включая `awg-warp-auto-fork.tar.gz` и checksums.
- `PROJECT_STATE.md` — что реально сделано и проверено на текущем роутере.
- `TECHNICAL_DEBT.md` — незакрытые вопросы и порядок дальнейшей работы.
- `BUILD_OPENWRT_25_APK.md` — как собрать `.apk` на Linux через matching SDK.

## Быстрый ориентир

Для продолжения правок открывай `source/luci-proto-amneziawg/`.
Реальный runtime WARP Auto находится в:

`source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/`

LuCI backend:

`source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg`

LuCI UI:

`source/luci-proto-amneziawg/htdocs/luci-static/resources/view/amneziawg/status.js`

Не копировать обратно `/etc/config/awg-warp-auto` с живого роутера: там могут
оказаться runtime state, profile IDs и приватные конфиги. Эта handoff-папка
преднамеренно не содержит router credentials, generated profiles или keys.
