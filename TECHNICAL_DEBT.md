# Technical debt / remaining work

## P0 — проверить после следующей прошивки

- Собрать и установить `.apk` именно под target, kernel и ABI новой OpenWrt
  25 firmware; kernel module нельзя переносить между build'ами.
- Прогнать blank-router flow: base AWG install -> overlay/package -> create
  interface -> Native Auto -> READY -> activate -> ForkOp route -> YouTube.
- Проверить bootstrap, Remote refresh/rollback и reboot recovery на чистом
  router. Текущий роутер имеет долгую историю ручных изменений, поэтому не
  является чистым стендом.

## P1 — production hardening

- [x] UI: when target interface is unmanaged and active pool pointer is cleared,
  hide/disable “Download active profile” instead of showing a dead action. (Реализовано)
- [x] Revisit health destination policy: добавлен конфигурируемый список DNS-резолверов
  (`health_resolvers` в UCI, UI Settings, candidate-test.sh и health-check.sh,
  default: 1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8 77.88.8.1). (Реализовано)
- [x] Добавить automated integration test, который моделирует recovery, stale rule cleanup,
  empty pool emergency replenish и force refresh cooldown: добавлен
  `source/luci-proto-amneziawg/tests/extended-integration-test.sh`. (Реализовано)
- [x] Rollback & deployment tooling: автоматические скрипты удаленного резервного копирования
  (`scripts/router-backup.sh`), отката (`scripts/router-rollback.sh`) и безопасного
  развертывания (`scripts/deploy-to-router.sh`) без перезагрузки сетевого стека или Forkop.
- Сделать настоящие OpenWrt 25 `apk` packages из matching SDK/feed, а не
  только overlay installer. Нужны versioning, architecture metadata,
  dependencies и upgrade test.
- Проверить installer на APK firmware: `apk update/add`, availability feeds,
  matching `kmod-amneziawg`, then LuCI cache/rpcd/procd restart.

## P2 — QUIC/I1

- `source/awg-warp-auto-quic/` — optional local helper/package source.
- Compatibility I1 preset реально работает; dynamic Mini-QUIC generator
  source and parity/reference tests есть, но target binary не собран и не
  проверен на router architecture из-за отсутствия matching SDK/Linux build.
- Собрать helper via OpenWrt SDK, run parity vectors, then Native SNI -> I1 ->
  READY/ACTIVE/YouTube regression. Keep preset fallback until this passes.

## P3 — observability / product polish

- [x] Add profile provenance column or details dialog: provider, endpoint source,
  registration time, last exact failure class — without exposing keys. (Реализовано:
  модальное окно «Details», кликабельный профиль, экспорт в ucode RPC).
- [x] Add an explicit “manual refresh bypasses normal wait once” UX, protected by
  a cooldown, rather than requiring UCI intervention for emergency debugging.
  (Реализовано: `force_replenish` с 30-секундным cooldown в daemon.sh, RPC и кнопка в UI).
- [x] UI visual polish: цветовые бейджи для статусов профилей (ACTIVE, READY, FAILED, NEW)
  и состояния здоровья (Health: OK/FAIL), адаптивные стили табов.
- Bound and rotate logs at explicit size; current LuCI log display is capped,
  but system log retention belongs to firmware configuration.

## Security constraints to preserve

- Never log/export PrivateKey except inside a user-requested downloaded `.conf`.
- Do not claim custom/hardcoded endpoints are official Cloudflare endpoints.
- Candidate test must remain isolated: do not activate candidate before it
  passes handshake, RX/TX and YouTube.
- Do not stop ForkOp or globally restart network from WARP Auto.
