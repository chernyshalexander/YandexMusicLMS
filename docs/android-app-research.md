# Отчёт по реверс-инжинирингу официального приложения Yandex Music (Android) для доработки LMS-плагина

Дата: 2026-07-06
Источник: декомпилированный APK `ru.yandex.music`, версия `2026.06.2`
(внутренний build id `24026322`), путь `Projects/android_yandex/app/src/main`.
Адресат: разработчик уровня middle, дорабатывающий плагин `Projects/yandex`
(Lyrion Music Server). Особый фокус — **протокол Ynison**.

Связанные документы этого репозитория:
- `docs/ynison-upgrade-plan.md` — план доработки Ynison (составлен по Python-
  провайдеру Music Assistant и go-yaynison). Настоящий отчёт **подтверждает,
  уточняет и в ряде мест исправляет** его выводы данными из первоисточника —
  официального клиента Яндекса.

---

## 0. Методология и главный вывод

### 0.1. Что за код мы читаем

APK декомпилирован в Java (JADX). Java-идентификаторы обфусцированы
(`d2y`, `hwv`, `q3d` — бессмысленные имена классов), **но**:

- **Kotlin-метаданные сохранились**: имена `.kt`-файлов и полные имена
  пакетов/классов видны в аннотациях `@k7c(... f="Ynison.kt")` и строках
  `com.yandex.music.shared.ynison.*`. Это позволяет находить нужные модули по
  осмысленным именам.
- **Protobuf-схемы сохранились полностью.** Классы сообщений —
  это `GeneratedMessageLite` (базовый класс здесь называется `tpj`). У каждого
  есть метод `mo8658final(...)`, возвращающий `new xly(DEFAULT_INSTANCE, "<info>",
  new Object[]{...})` — это стандартный `newMessageInfo`. Массив `Object[]`
  содержит **реальные имена полей** (`playerQueue_`, `progressMs_`,
  `muteEventsIfPassive_`), а константы `*_FIELD_NUMBER` дают номера полей. Из
  этих двух источников восстанавливается точная `.proto`-схема: имена, номера,
  типы, `oneof`, enum'ы.

Именно поэтому данные ниже — **первоисточник**, а не реконструкция по трафику:
это те же самые определения, из которых Яндекс генерирует и сервер, и клиент.

**Верификация (2026-07-06).** Все типовые утверждения ниже перепроверены
напрямую по Java-объявлениям полей в APK (`private long` = `int64`,
`private int` = `int32`/enum, `private double`, `private boolean`,
`private String`, `de40` = `StringValue`). Сверены: типы всех полей
`PlayingStatus`/`Version`/`PlayerQueue`/redirect-ответа (int64-список —
точно), карта `oneof` `PutYnisonStateRequest` (номера полей ↔ классы
сообщений), enum `activity_interception_type`, имена сервисов
(`ynison_state.YnisonStateService`/`ynison_redirect.YnisonRedirectService`),
хосты (`ynison.music.yandex.net:443`, QA), заголовок
`YandexMusicAndroid/24026322`, наличие/отсутствие `track_source_key`
(отсутствует — 0 совпадений). Найдены и исправлены два неточных места
исходной версии отчёта: тип устройства в `update_full_state` (`wg70`, а не
`q3d`) и природа `*_optional`-строк (`StringValue`-обёртки).

### 0.2. Главный архитектурный вывод: транспорт разный, схема одна

| | Официальное приложение (Android) | LMS-плагин (`Ynison.pm`) |
|---|---|---|
| Транспорт | **native gRPC поверх HTTP/2** | WebSocket + JSON (ручной фрейминг) |
| Redirect-хост | `ynison.music.yandex.net:443` (gRPC) | `wss://ynison.music.yandex.ru/...` (WS-мост) |
| Сериализация | protobuf binary | protobuf-JSON mapping |
| Метод состояния | `ynison_state.YnisonStateService/PutYnisonState` (bidi-stream) | тот же путь, но через WS-шлюз |
| Метод редиректа | `ynison_redirect.YnisonRedirectService/GetRedirectToYnison` (unary) | `redirector.YnisonRedirectService/GetRedirectToYnison` |

Приложение вообще не использует WebSocket для Ynison — это gRPC (grpc-java/
grpc-kotlin). LMS-плагину переезжать на gRPC **не нужно и нецелесообразно**
(в Perl это дорого, а WS-мост Яндекса работает). **Ценность приложения для
плагина в другом: оно даёт эталонную protobuf-схему.** Поскольку WS-мост
передаёт те же сообщения в виде protobuf-JSON, все правила отображения
(в частности `int64 → строка JSON`) и все имена полей/enum'ов берутся отсюда
и являются истиной в последней инстанции.

> **Ключевой факт для всего плана 1.x:** в protobuf-JSON поля `int64`/`uint64`
> сериализуются **как строки**. Все «загадочные разрывы WS из-за int вместо
> строки» (Задача 1.1 плана) — прямое следствие того, что соответствующие поля
> объявлены `int64` в схеме (см. §1.4). Это не эвристика из MA, а требование
> формата protobuf-JSON.

Расхождение в имени gRPC-пакета редиректора (`ynison_redirect` в приложении
против `redirector` в рабочем WS-URL плагина) — норма: WS-мост Яндекса
экспонирует сервис под своим путём. Менять рабочий URL плагина не нужно;
факт зафиксирован для полноты.

---

## 1. Ynison — эталонная protobuf-схема (ядро отчёта)

Все имена ниже — реальные имена полей из приложения. Тип `int64` помечен явно,
потому что именно он обязан сериализоваться строкой в исходящем JSON плагина.

### 1.1. Транспорт и подключение

**Redirect (unary gRPC), сервис `ynison_redirect.YnisonRedirectService`,
метод `GetRedirectToYnison`.**
Источник: `java/p000/hsb0.java`, хост в `java/p000/wq1.java:44`.

Ответ `GetRedirectToYnisonResponse` (класс `quy`):

| # | Поле | Тип | Назначение |
|---|------|-----|-----------|
| 1 | `host` | string | Хост state-сервиса для второго шага |
| 2 | `redirect_ticket` | string | Тикет, передаётся при подключении к state |
| 3 | `session_id` | **int64** | Идентификатор сессии |
| 4 | `keep_alive_params` | message | Параметры keepalive (см. ниже) |

`keep_alive_params` (класс `ojm`):

| # | Поле | Тип |
|---|------|-----|
| 1 | `keep_alive_time_seconds` | int |
| 2 | `keep_alive_timeout_seconds` | int |

> **Находка против плана:** плагин шлёт keepalive-ping жёстко каждые 20 с.
> Сервер сам сообщает интервал (`keep_alive_time_seconds`) и таймаут в ответе
> редиректора. Правильнее брать значение оттуда, а 20 с оставить как fallback.
> `session_id` — **int64**, т. е. в JSON это строка.

**State (bidi-stream gRPC), сервис `ynison_state.YnisonStateService`,
метод `PutYnisonState`.** Источник: `java/p000/xcb0.java:63`. Двунаправленный
стрим: клиент шлёт `PutYnisonStateRequest`, сервер — поток
`PutYnisonStateResponse`.

Авторизация в приложении — gRPC-метаданные (`Authorization: OAuth <token>`).
В плагине через WS это уже реализовано (заголовок `Authorization` +
идентификация устройства в `Sec-WebSocket-Protocol`), менять не требуется.

### 1.2. Исходящее сообщение: `PutYnisonStateRequest` (класс `d2y`)

Это `oneof parameters` + три общих поля. **Полная карта — сравните со своим
`Ynison.pm`, где сейчас реализована только часть кейсов:**

| # | Поле (oneof `parameters`) | Тип сообщения | В плагине? |
|---|---------------------------|---------------|-----------|
| 1 | `update_full_state` | `UpdateFullState` | ✅ регистрация устройства |
| 2 | `update_active_device` | `UpdateActiveDevice` | ❌ (нужно для «играть здесь», план 2.5) |
| 3 | `update_playing_status` | `UpdatePlayingStatus` | ❌ (нужно для heartbeat/seek, план 2.1/2.4) |
| 4 | `update_player_state` | `UpdatePlayerState` | ✅ play/pause/cast |
| 5 | `update_volume` (**deprecated**) | `UpdateVolume` | — не использовать |
| 6 | `update_player_queue_inject` | `UpdatePlayerQueueInject` | ❌ (см. ниже) |
| 9 | `update_session_params` | `UpdateSessionParams` | ❌ (план 2.6) |
| 11 | `update_volume_info` | `UpdateVolumeInfo` | ❌ (исходящая громкость, план 3.5) |
| 12 | `sync_state_from_eov` | `SyncStateFromEov` | ❌ (см. ниже) |

Общие поля (вне oneof):

| # | Поле | Тип | Примечание |
|---|------|-----|-----------|
| 7 | `player_action_timestamp_ms` | **int64** | → строка в JSON |
| 8 | `rid` | string | request id |
| 10 | `activity_interception_type` | enum | значения ниже |

Enum `activity_interception_type` (класс `d2y$a`) — **подтверждает строку из
плана дословно:**
```
DO_NOT_INTERCEPT_BY_DEFAULT = 0
INTERCEPT_IF_NO_ONE_ACTIVE  = 1
INTERCEPT_EAGER             = 2
```

Содержимое кейсов oneof:

- `UpdateFullState` (`fh70`): `{ player_state, is_currently_active (bool),
  device (`wg70`), sync_state_from_eov_optional }`.
  > **Уточнение (проверено по APK):** поле `device` здесь — тип **`wg70`**,
  > **облегчённый** дескриптор устройства = `{ info, volume, capabilities,
  > volume_info }`, **без** `session` и `is_offline`. Это НЕ тот же тип, что
  > `Device` (`q3d`) в ответном `devices[]` (§1.6), — там полей больше. При
  > регистрации плагин отправляет именно `wg70`. Поля `can_be_player`/
  > `volume_info` живут **внутри** этого дескриптора (`device.capabilities.
  > can_be_player`, `device.volume_info`), а не на верхнем уровне.
- `UpdatePlayerState` (`hh70`): `{ player_state }`.
- `UpdatePlayingStatus` (`ih70`): `{ playing_status }` — **лёгкое** сообщение
  только со статусом (прогресс/пауза), без пересборки очереди. Именно его
  надо слать в heartbeat/seek (план 2.1/2.3/2.4).
- `UpdateActiveDevice` (`qg70`): `{ device_id_optional (string) }` — «играть
  здесь»/перехват активности.
- `UpdateSessionParams` (`ph70`): `{ mute_events_if_passive (bool) }` —
  **имя поля подтверждено дословно** (план 2.6).
- `UpdatePlayerQueueInject` (`gh70`): `{ player_queue_inject }` — механизм
  «подмешивания» треков в очередь без полной пересборки. Потенциально
  элегантнее ручного `update_player_state` для радио-пополнения (план 2.2),
  но схема inject сложнее; на первом этапе оставить `update_player_state`.
- `UpdateVolumeInfo` (`yh70`): `{ device_id (string), volume_info (VolumeInfo) }`.
- `SyncStateFromEov` (`p050`): `{ actual_queue_id }` — синхронизация «end of
  version»; служебное, плагину не требуется.

### 1.3. Входящее сообщение: `PutYnisonStateResponse` (класс `e2y`)

| # | Поле | Тип | Назначение |
|---|------|-----|-----------|
| 1 | `player_state` | `PlayerState` | Полное состояние плеера |
| 2 | `devices` | repeated `Device` | Все устройства аккаунта |
| 3 | `active_device_id_optional` | string | Кто сейчас активен (перехват — план 2.5) |
| 4 | `timestamp_ms` | **int64** | Серверное время |
| 5 | `rid` | string | request id |

### 1.4. `PlayerState` и его составляющие

`PlayerState` (класс `msv`):

| # | Поле | Тип |
|---|------|-----|
| 1 | `status` | `PlayingStatus` |
| 2 | `player_queue` | `PlayerQueue` |
| 3 | `player_queue_inject_optional` | message |

`PlayingStatus` (класс `hwv`) — **вот источник правила «строки»:**

| # | Поле | Тип | В JSON |
|---|------|-----|--------|
| 1 | `progress_ms` | **int64** | **строка** |
| 2 | `duration_ms` | **int64** | **строка** |
| 3 | `paused` | bool | true/false |
| 4 | `playback_speed` | **double** | число (не строка!) |
| 5 | `version` | `Version` | объект |

`Version` (класс `wh70`) — **источник правила эхо-детекта:**

| # | Поле | Тип | В JSON |
|---|------|-----|--------|
| 1 | `device_id` | string | строка |
| 2 | `version` | **int64** | **строка** |
| 3 | `timestamp_ms` | **int64** | **строка** |

> **Подтверждение планов 1.1 и 1.3 из первоисточника:**
> - `version.version` и `version.timestamp_ms` — **int64** ⇒ обязаны быть
>   строками в JSON. То же для `progress_ms`, `duration_ms`,
>   `player_action_timestamp_ms`, `session_id`, `timestamp_ms`.
> - `playback_speed` — **double**, его строкой оборачивать **не надо**
>   (частая ошибка «на всякий случай завернуть всё в строку»).
> - Авторство определяется полем `version.device_id` — оно есть и в
>   `player_queue.version`, и в `status.version`. Двойной authorship-чек из
>   плана 1.3 схемно корректен.

### 1.5. `PlayerQueue` (класс `dhv`) — полная схема

| # | Поле | Тип | Примечание |
|---|------|-----|-----------|
| 1 | `entity_id` | string | id альбома/плейлиста/станции |
| 2 | `entity_type` | enum | тип контейнера (ниже) |
| 3 | `current_playable_index` | int32 | текущий индекс |
| 4 | `playable_list` | repeated `Playable` | видимая очередь |
| 5 | `options` | `QueueOptions` | `{ repeat_mode }` |
| 6 | `version` | `Version` | авторство очереди |
| 7 | `shuffle_optional` | message | шафл |
| 8 | `entity_context` | enum | контекст (ниже) |
| 9 | `from_optional` | string-wrapper | источник запуска |
| 10 | `initial_entity_optional` | message | исходная сущность |
| 11 | `adding_options_optional` | message | опции добавления |
| 12 | **`queue`** | `Queue` | **вложенная очередь (wave_queue и др.)** |
| 13 | `navigation_id_optional` | string-wrapper | |
| 14 | `filter_optional` | string-wrapper | |
| 15 | `playback_action_id_optional` | string-wrapper | |

> **Что такое «string-wrapper».** Поля `*_optional` типа `de40` — это
> `google.protobuf.StringValue` (`de40 = { value: string }`). В protobuf-JSON
> `StringValue` сериализуется как **обычная строка** (или `null`, когда поле
> отсутствует), поэтому через WS-мост плагин видит их как простые строки —
> дополнительной обёртки `{value:...}` в JSON нет. Нюанс важен только при
> работе с бинарным protobuf (не наш случай).

> **Подтверждение и уточнение плана 1.5 (баг wave_queue).** Поле №12 `queue` —
> отдельное вложенное сообщение, **не** часть `playable_list`. Ручная пересборка
> `player_queue` в `build_change_track_request` теряет его. План 1.5 предлагает
> клонировать весь `player_queue` — это верно. Полная схема ниже показывает,
> **что именно** там теряется.

`Queue` (`dhv$...`, класс `C14145f`) — это `oneof`:
```
1 wave_queue        (WaveQueue)      ← «Моя волна» и радио
2 generative_queue  (GenerativeQueue)
3 fm_radio_queue    (FmRadioQueue)
4 video_wave_queue  (VideoWaveQueue)
5 local_tracks_queue(LocalTracksQueue)
```

`WaveQueue`:

| # | Поле | Тип |
|---|------|-----|
| 1 | `recommended_playable_list` | repeated `Playable` (предзагруженные рекомендации) |
| 2 | `live_playable_index` | int (индекс «живого» воспроизведения) |
| 3 | `entity_options` | `EntityOptions` |
| 4 | `navigation_id_optional` | string-wrapper |
| 5 | `playback_action_id_optional` | string-wrapper |

`EntityOptions`: `{ 1: wave_entity_optional, 2: track_sources[] }`.
`track_sources[]` item: `{ 1: key, 2: wave_source, 3: phonoteka_source }`, где
`phonoteka_source` = `{ album_id | artist_id | playlist_id, entity_context }`.

Именно этот подграф отвечает за продолжение персонализации волны в приложении
после ручного skip на LMS. Клонирование `player_queue` целиком (планы 1.5/2.2)
сохраняет его без необходимости знать внутренности.

`Playable` (класс `suu`) — элемент очереди:

| # | Поле | Тип | Примечание |
|---|------|-----|-----------|
| 1 | `playable_id` | string | id трека |
| 2 | `album_id_optional` | string | |
| 3 | `playable_type` | enum | `TRACK=1, LOCAL_TRACK=2, INFINITE=3, VIDEO_CLIP=4` |
| 4 | `from` | string | контекст-тег воспроизведения |
| 5 | `title` | string | |
| 6 | `cover_url_optional` | string | |
| 7 | `video_clip_info` (oneof) | message | |
| 8 | `track_info` (oneof) | `TrackInfo` | см. ниже — **изменилось!** |
| 9 | `navigation_id_optional` | string | |
| 10 | `playback_action_id_optional` | string | |

> **Уточнение плана 2.2 (важно).** В плане (по старому перехваченному трафику
> `test/ynison_events.jsonl`) `track_info = { track_source_key: 0 }`. В текущей
> версии приложения (`2026.06`) `TrackInfo` (класс `y580`) = **`{ 1:
> recommendation_type }`** с enum:
> ```
> UNSPECIFIED=0, RECOMMENDED=1, ON_DEMAND=2, SEARCH=3, ARTIST=4, OWN=5,
> EDITORIAL_CHOICE=6
> ```
> То есть поле `track_source_key` в схеме `Playable.track_info` **больше не
> присутствует** — схема эволюционировала. Практический вывод для плагина
> прежний и даже усиливается: **не синтезируйте `track_info` для треков,
> которые добавляете сами** (дозапрошенные через rotor-API). Поле опционально,
> его семантика менялась между версиями, и подделка значения рискованна.
> Для треков, пришедших с телефона, `track_info` сохраняется автоматически
> при клонировании `player_queue`.

### 1.6. `Device` и связанные сообщения

**Важно: в протоколе два разных «устройства».**

`Device` (класс `q3d`) — **входящий**, элемент `devices[]` в
`PutYnisonStateResponse`:

| # | Поле | Тип |
|---|------|-----|
| 1 | `info` | `DeviceInfo` |
| 2 | `volume` | double |
| 3 | `capabilities` | `Capabilities` |
| 4 | `session` | `Session` `{ id: string }` |
| 5 | `is_offline` | bool |
| 6 | `volume_info` | `VolumeInfo` |

`Device` (класс `wg70`) — **исходящий**, поле `device` в `update_full_state`
(регистрация нашего устройства). **Облегчённый**: без `session` и `is_offline`:

| # | Поле | Тип |
|---|------|-----|
| 1 | `info` | `DeviceInfo` |
| 2 | `volume` | double |
| 3 | `capabilities` | `Capabilities` |
| 4 | `volume_info` | `VolumeInfo` |

`DeviceInfo` (`m4d`): `{ device_id, title, type, app_name, app_version }`.
`Capabilities` (`z3d`): `{ can_be_player (bool), can_be_remote_controller
(bool), volume_granularity }`.
`VolumeInfo` (`v5d`): `{ volume (double), version (Version) }`.

> При регистрации плагин отправляет `wg70`; расположение полей:
> `can_be_player` → `device.capabilities.can_be_player`; `volume_info` →
> `device.volume_info`. Для **исходящей** синхронизации громкости (план 3.5)
> есть готовое сообщение `update_volume_info` = `{ device_id, volume_info: {
> volume, version } }` (не deprecated `update_volume`).

### 1.7. Enum'ы `PlayerQueue`

`entity_type` (тип контейнера):
```
UNSPECIFIED=0, ARTIST=1, PLAYLIST=2, ALBUM=3, RADIO=4, VARIOUS=5,
GENERATIVE=6, FM_RADIO=7, VIDEO_WAVE=8, LOCAL_TRACKS=9
```
> Для радио-пополнения (план 2.2) целевой признак — `entity_type ∈ {RADIO(4),
> GENERATIVE(6), FM_RADIO(7)}`, а не только строка «RADIO».

`entity_context`:
```
BASED_ON_ENTITY_BY_DEFAULT=0, USER_TRACKS=1, DOWNLOADED_TRACKS=2, SEARCH=3,
MUSIC_HISTORY=4, MUSIC_HISTORY_SEARCH=5, ARTIST_MY_COLLECTION=6,
ARTIST_FAMILIAR_FROM_WAVE=7
```

`repeat_mode` (`QueueOptions`): `UNSPECIFIED=0, NONE=1, ONE=2, ALL=3`.

### 1.8. Итог по Ynison: что менять в плане

| Пункт плана | Вердикт по первоисточнику |
|---|---|
| 1.1 (int→строка) | **Подтверждён и расширен.** Точный список int64-полей: `progress_ms`, `duration_ms`, `version.version`, `version.timestamp_ms`, `player_action_timestamp_ms`, `session_id`, ответный `timestamp_ms`. **Не** оборачивать `playback_speed` (double) и `paused` (bool). |
| 1.2 (клампинг) | Ортогонален схеме; оставить как есть (защита от 400030001). |
| 1.3 (эхо по авторству) | **Подтверждён.** `version.device_id` присутствует и в queue-, и в status-версии — двойной чек схемно корректен. |
| 1.4 (коды ребаланса) | Не выводится из схемы (ошибки — уровень gRPC/шлюза); оставить по плану. |
| 1.5 (wave_queue) | **Подтверждён точной схемой** (§1.5). Клонирование `player_queue` — верный подход. |
| 1.6 (фреймы >64 КБ) | Свойство WS-моста, к схеме отношения не имеет; оставить. |
| 2.1/2.3/2.4 (heartbeat/seek) | Использовать `update_playing_status` (`ih70`, лёгкое сообщение), не `update_player_state`. |
| 2.2 (радио-пополнение) | Триггер — `entity_type ∈ {RADIO, GENERATIVE, FM_RADIO}`. **Не** синтезировать `track_info` (§1.5). Рассмотреть `update_player_queue_inject` в будущем. |
| 2.5 (перехват) | Читать `active_device_id_optional` из ответа (§1.3). |
| 2.6 (`mute_events_if_passive`) | **Имя поля подтверждено дословно.** |
| 3.5 (исходящая громкость) | Готовое сообщение `update_volume_info` (§1.6), не deprecated `update_volume`. |
| keepalive | **Новое:** брать интервал из `keep_alive_params.keep_alive_time_seconds` (ответ редиректора), 20 с — fallback. |

---

## 2. REST API: хосты, эндпоинты, заголовки, авторизация

### 2.1. Хосты (по частоте в коде)

| Хост | Назначение |
|---|---|
| `api.music.yandex.net` | Основной REST API (каталог, аккаунт, лайки, rotor) |
| `ynison.music.yandex.net:443` | Ynison gRPC (prod); QA: `qa.ynison.music.yandex.net:443` |
| `music-custom-wave-media.music.yandex.net` | Медиа-агенты кастомных волн (Build My Vibe) |
| `avatars.yandex.net`, `avatars.mds.yandex.net` | Обложки (шаблон с `%%`-плейсхолдером размера) |
| `strm.yandex.ru` | HLS-стриминг |
| `passport.yandex.ru` | Авторизация (OAuth) |
| `plus.yandex.net`, `mediabilling.yandex.ru` | Подписка Плюс/биллинг |
| `quasar.yandex.ru/.net` | Умные колонки (Quasar) — связано с Ynison-экосистемой |

### 2.2. Обязательные заголовки запросов (`java/p000/npk.java`, `ds6.java`, `ppk.java`)

```
X-Yandex-Music-Client:      YandexMusicAndroid/24026322
X-Yandex-Music-Client-Now:  <ISO-8601 текущее время клиента>
X-Yandex-Music-Content-Type:<тип контента: обычный/детский/без NSFW>
X-Yandex-Music-Device:      os=Android; os_version=<ver>; manufacturer=<...>;
                            model=<...>; clid=<clid>; uuid=<uuid>;
                            display_size=<WxH>; dpi=<dpi>; mcc=<mcc>;
                            mnc=<mnc>; device_id=<device_id>
X-Yandex-PUID:              <passport uid>
X-Yandex-TestIds:           <экспериментальные флаги>
Authorization:              OAuth <token>
```

> **Практический вывод.** Плагин выиграет от отправки заголовков
> `X-Yandex-Music-Client: YandexMusicAndroid/24026322` и осмысленного
> `X-Yandex-Music-Device` (можно синтезировать стабильный `device_id`/`uuid`
> на инсталляцию). Это (а) уменьшает шанс попасть под антибот-эвристики,
> (б) даёт доступ к тем же выдачам, что и мобильный клиент. `X-Yandex-Music-
> Client-Now` — время клиента в ISO-8601.

---

## 3. Стриминг, кодеки, download-info, шифрование

### 3.1. Карта эндпоинтов получения файла (`java/p000/lzs.java`)

| Логическое имя | Путь | Назначение |
|---|---|---|
| `download_info` | `tracks/<id>/download-info` | Список вариантов (codec/bitrate/link) |
| `file_download_info` | `file-download-info` | Прямая ссылка на файл |
| `strm_master_play_list` | `music/.../master.m3u8` | HLS master-плейлист |
| `strm_media_play_list` | `music/.../index-a1.m3u8` | HLS media-плейлист (аудио) |
| `strm_key` | `.../key` | **AES-ключ для HLS** |
| `get_file_info` | `get-file-info` | Старый подписанный эндпоинт |

### 3.2. `DownloadInfoDto` (`java/p000/r9d.java`)

Поля варианта загрузки: `codec`, `bitrate` (int), `link`, `container`,
**`gain`**. Приложение выбирает вариант по кодеку и битрейту.

- **Кодеки** (строки в коде): `flac`, `flac-mp4`, `aac`, `aac-mp4`, `he-aac`,
  `mp3`. **Уровни качества:** `lq`, `nq`, `hq`, `lossless`.
  Полностью совпадает с заявленной поддержкой плагина.
- **`gain`** — коэффициент нормализации громкости, приходит вместе с
  download-info. Плагин сейчас его, судя по всему, не применяет.
  > **Идея для доработки:** пробрасывать `gain` как ReplayGain-метаданные трека,
  > чтобы LMS выравнивал громкость между треками так же, как приложение.

### 3.3. Два пути стриминга

1. **HLS (современный, в приложении основной):** `master.m3u8` → `index-a1.m3u8`
   → сегменты, зашифрованные `METHOD=AES-128` (парсер HLS-тегов —
   `java/p000/c9b0.java`, `vuk.java`; поддерживаются `AES-128`, `SAMPLE-AES`,
   `SAMPLE-AES-CENC`, `SAMPLE-AES-CTR`). Ключ берётся с эндпоинта `strm_key`.
2. **download-info (то, что использует плагин):** прямая ссылка на
   зашифрованный файл, расшифровка AES-CTR на лету (`Decode/AES128.pm`,
   `ProtocolHandler.pm`).

> Плагин уже реализует путь №2 и демультиплексирование FLAC/AAC-in-MP4 —
> менять не требуется. Путь HLS зафиксирован как альтернатива на случай, если
> download-info для части контента перестанет отдаваться (Яндекс постепенно
> смещает клиентов на HLS).

---

## 4. Магические константы и ресурсы для browse-дерева

### 4.1. Каталог станций «Колеса настроения» (`java/p000/c0a0.java`)

Захардкоженный fallback-набор волн (id → строковый ресурс → media-агент →
обложка → цвет фона). Полезен как эталон id и как офлайн-набор, если
rotor-dashboard недоступен:

| id станции | media-агент (`music-custom-wave-media...`) |
|---|---|
| `activity:wake-up` | `/JVsyUlrs9Y` |
| `activity:road-trip` | `/Foah9sRLsS` |
| `activity:work-background` | `/tsXpFHIBjM` |
| `activity:workout` | `/PexWCCcEc9` |
| `activity:fall-asleep` | `/J9QAoYnnPe` |
| `mood:energetic` | `/e6Ptlara08` |
| `mood:happy` | `/EzOBeQmIXi` |
| `mood:sad` | `/rrF2I4tUvZ` |

Каждая станция несёт: заголовок (`R.string.wave_title_*`), заголовок группы
(`R.string.wave_header_activity` / `..._mood`), обложку
(`avatars.mds.yandex.net/get-music-misc/.../rotor-*-agent-cover-*/%%`, где `%%`
заменяется на размер, напр. `200x200`) и HEX-цвет фона карточки.
Полная таксономия волн (жанры/эпохи/языки) приходит из rotor-API — плагин это
уже умеет; данный список — курируемый минимум приложения.

### 4.2. Обложки

Шаблон URL обложки содержит плейсхолдер `%%`, который клиент заменяет на
размер (`200x200`, `400x400`, `1000x1000` и т. д.). Для LMS уместно
запрашивать `400x400`/`600x600`.

### 4.3. Прочее

- Внутренний build id клиента: **`24026322`** (использовать в
  `X-Yandex-Music-Client`).
- Ассеты `assets/main_feed*.json`, `assets/divkit/` — серверно-управляемый
  UI (DivKit); для LMS не воспроизводим, но подтверждают, что структура
  главной страницы («лендинг») задаётся сервером, а не зашита в клиент, —
  поэтому плагину правильно строить главное меню из ответа landing-API, а не
  хардкодить.

---

## 5. Приоритизированные рекомендации (сводка)

**Ynison (приоритет пользователя):**
1. **Реализовать план 1.1 по точному списку int64-полей из §1.4/§1.8**,
   не оборачивая в строку `playback_speed` и `paused`.
2. **Двойной authorship-чек (план 1.3)** — схемно подтверждён, внедрять.
3. **Клонировать `player_queue` целиком (планы 1.5 и 2.2)** — вместо ручной
   пересборки, чтобы сохранять `queue.wave_queue` (§1.5).
4. **Heartbeat/seek — через `update_playing_status`** (`ih70`), не через
   полный `update_player_state`.
5. **keepalive — из `keep_alive_params`** ответа редиректора (§1.1), 20 с как
   fallback.
6. **`track_info` для самодобавленных треков не синтезировать** — поле сменило
   семантику между версиями (§1.5).
7. Перехват активности — по `active_device_id_optional` (§1.3);
   `update_session_params.mute_events_if_passive` — имя подтверждено;
   исходящая громкость — `update_volume_info` (§1.6).

**REST/стриминг (вторичный приоритет):**
8. Слать заголовки `X-Yandex-Music-Client`/`-Device`/`-Content-Type` как
   мобильный клиент (§2.2).
9. Пробрасывать `gain` из download-info в ReplayGain-метаданные (§3.2).
10. Главное меню строить из landing-API, а не хардкодить (§4.3); станции из
    §4.1 — как офлайн-fallback.

---

## Приложение A. Индекс обфусцированных классов Ynison

| Класс | proto-сообщение |
|---|---|
| `d2y` | `PutYnisonStateRequest` |
| `e2y` | `PutYnisonStateResponse` |
| `quy` / `puy` | `GetRedirectToYnisonResponse` / `...Request` |
| `ojm` | `KeepAliveParams` |
| `msv` | `PlayerState` |
| `hwv` | `PlayingStatus` |
| `dhv` | `PlayerQueue` |
| `C14145f` (вложен в `dhv`) | `Queue` (oneof wave/generative/fm/video/local) |
| `suu` | `Playable` |
| `y580` | `TrackInfo` (`{ recommendation_type }`) |
| `wh70` | `Version` |
| `q3d` | `Device` (входящий, `devices[]`: +session/is_offline) |
| `wg70` | `Device` (исходящий, `update_full_state.device`: облегчённый) |
| `de40` | `google.protobuf.StringValue` (`{ value }`) — все `*_optional`-строки |
| `m4d` | `DeviceInfo` |
| `z3d` | `Capabilities` |
| `ha10` | `Session` |
| `v5d` | `VolumeInfo` |
| `fh70`/`hh70`/`ih70`/`qg70`/`ph70`/`gh70`/`yh70`/`xh70`/`p050` | кейсы oneof `PutYnisonStateRequest.parameters` (см. §1.2) |

Файлы-исходники транспорта: `xcb0.java` (PutYnisonState), `hsb0.java`
(GetRedirectToYnison), `wq1.java` (хост), `ds6.java`/`npk.java`/`ppk.java`
(REST-заголовки), `lzs.java`/`r9d.java` (download/HLS), `c0a0.java` (станции).
