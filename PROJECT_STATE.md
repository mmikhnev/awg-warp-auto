# Project state — факты на 2026-09-05

## Назначение

WARP Auto — LuCI-надстройка в `Services -> AmneziaWG` для WARP/AmneziaWG
profile pool: ручной import, Remote и Native provider, isolated candidate
test, activation, rollback, health/failover, export `.conf`.

## Реально проверено на роутере

- Native Cloudflare registration создаёт новый WARP config.
- Native берёт `Endpoint` из `result.config.peers[0].endpoint.host` ответа
  registration. Фактический endpoint на роутере: `engage.cloudflareclient.com:2408`.
- При пустом Custom Endpoint Pool были созданы два Native профиля в `READY`.
- Каждый READY прошёл disposable AWG interface, handshake, transfer и
  YouTube HTTPS check до попадания в pool.
- `YTwarp` не переименовывался и не удалялся. Прямой YouTube health-check
  после последнего фикса: два последовательных `OK`.
- Old hardcoded native endpoints удалены из Native default/fallback logic.
- Remote/Naitve provider abstraction, pool rows, per-row actions, `.conf`
  download route и LuCI ACL ранее внедрены; текущая release содержит их.

## Текущая архитектура

### Providers

`provider-fetch.sh` — общий dispatcher.

- `warp-gen-provider.uc`: Remote provider, получает profiles с URL в Settings.
- `native-provider.sh`: Cloudflare registration, local keypair, WARP config,
  AWG preset/I1 fallback.

### Endpoint source

Native Settings:

- `Auto`: endpoint из Cloudflare registration response.
- `Custom only`: operator-supplied `host:port` list.
- `Auto + custom fallback`: Auto first, then custom candidates.

Custom entries никогда не маркируются как official Cloudflare endpoints.

### Pool lifecycle

NEW -> isolated test -> READY -> activation -> ACTIVE.

FAILED entries удаляются по умолчанию, чтобы не копить keys/строки. Для
диагностики можно установить `retain_failed_profiles=1` вручную через UCI.
Если после failover READY pool пуст, Native разрешает один emergency
replenishment не чаще раза в 60 секунд; обычный registration interval и
backoff сохраняются.

### Health

`candidate-test.sh` и `health-check.sh` используют отдельную policy route,
требуют AWG transfer/handshake и YouTube HTTPS. Они очищают зависшие
probe rule/table перед запуском. DNS lookup теперь пробует 1.1.1.1, 8.8.8.8,
9.9.9.9, потому что на текущей сети 1.1.1.1 иногда возвращал ложный NXDOMAIN.

## Последняя подтверждённая проблема и fix

Пустой UI pool был не Cloudflare generation failure. После DNS false-negative
READY candidates были удалены как disposable, stale `active_id` остался без
stored `.conf`, а normal Native rate-limit задерживал refill. Исправлено:

1. ACTIVE entry не удаляется только из-за временного FAILED state.
2. stale active pointer с отсутствующим file очищается, не трогая live
   network interface.
3. Empty READY pool включает bounded emergency refill.
4. DNS и stale probe rule больше не должны давать этот ложный каскад.

## Обновления от 2026-09-05 (вечер)

1. **Конфигурируемый DNS-резолвер**:
   - `health_resolvers` вынесен в UCI и LuCI UI Settings.
   - По умолчанию используются `1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8 77.88.8.1`.
   - Резолверы передаются в `candidate-test.sh` и `health-check.sh`.
2. **UI & Provenance**:
   - Бейджи состояний: `ACTIVE` (зеленый), `READY` (синий), `FAILED` (красный), `NEW` (нейтральный), Health `OK`/`FAIL`.
   - Модальное окно детализации «Details» по профилю: провайдер (Native Cloudflare / Remote / Custom), источник эндпоинта, временные метки, последняя ошибка (без раскрытия приватных ключей).
   - Кнопка «Download active profile» корректно отключается/скрывается при отсутствии активного или неуправляемом интерфейсе.
   - Убраны жестко зашитые цвета табов, применен адаптивный LuCI theme style.
3. **Ручное форсированное пополнение (Force replenish)**:
   - Добавлено действие `force_replenish` с защитным 30-секундным cooldown против флуда API Cloudflare.
4. **Автоматизация и безопасность стенда**:
   - Созданы `scripts/router-backup.sh`, `scripts/router-rollback.sh` и `scripts/deploy-to-router.sh`.
   - Развертывание проверено на живом стенде: Forkop и активные соединения не перезапускались, рабочий канал сохранен.
   - Создан расширенный офлайн набор тестов `source/luci-proto-amneziawg/tests/extended-integration-test.sh`.
