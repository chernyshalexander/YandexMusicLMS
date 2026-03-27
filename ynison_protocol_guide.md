# Руководство по протоколу Yandex Ynison и архитектуре интеграции с LMS

---

## Архитектура: почему нативный Perl, а не внешний бинарник

### Как это сделано в Spotty-Plugin (Spotify Connect)

В Spotty-Plugin весь Remote Control реализован **не в Perl**, а во внешнем бинарнике `spotty` — форке проекта librespot, написанного на Rust.

1. **Внешний демон** (`spotty`/librespot) открывает зашифрованное соединение с серверами Spotify и объявляет себя в локальной сети через mDNS/Zeroconf.
2. **Протокол Spirc** (Spotify Remote Procedure Call): команды приходят как Protobuf-сообщения — `kMessageTypeLoad`, `kMessageTypePlay`, `kMessageTypePause`, `kMessageTypeSeek`, `kMessageTypeVolume`.
3. **Управление LMS**: получив команду Spirc, демон `spotty` сам отправляет CLI/JSON-RPC команды на порт LMS (9000/9090):
   - `playlist play spotify://track:ID`
   - `pause 1` / `pause 0`
   - `time X` (seek)
   - `mixer volume X`
4. **Perl-плагин** в этой схеме пассивен — только парсит `spotify://` ссылки и отдаёт метаданные.

### Почему для Ynison выбран Вариант: нативный Perl внутри LMS

У Ynison нет готового бинарника. Написание внешнего хелпера (Python/Node.js) добавляет зависимости и сложность деплоя. Ynison работает через обычные WebSockets — это реализуемо на Perl средствами LMS (`Slim::Networking::Async`, `Slim::Networking::IO::Select`).

**Ключевое отличие от Spotty**: Ynison — это **двусторонний state-sync протокол**. LMS не просто принимает команды — он сам является участником сессии и публикует своё состояние. Spotty/librespot делает то же самое, но скрыто внутри Rust-бинарника.

Реализация: `Plugins::yandex::Ynison` (`Ynison.pm`) — нативный Perl WebSocket-клиент, запускается внутри event loop LMS при инициализации плеера.

---

## Общая схема подключения к Ynison

Протокол работает поверх WebSocket с JSON-сообщениями (в браузере используется Protobuf/base64, в нашей реализации — JSON).

1. **Redirector**: `wss://ynison.music.yandex.ru/redirector.YnisonRedirectService/GetRedirectToYnison` — возвращает адрес рабочего хоста сессии.
2. **Session Host**: `wss://{host}/ynison_state.YnisonStateService/PutYnisonState` — основное соединение для двустороннего обмена состоянием.

---

## Базовые структуры сообщений

### `PutYnisonStateRequest` (клиент → сервер)

| Поле | Тип | Описание |
| :--- | :--- | :--- |
| `update_full_state` | `UpdateFullState` | Полное состояние — при подключении или после обрыва |
| `update_player_state` | `UpdatePlayerState` | Изменение очереди, индекса трека |
| `update_playing_status` | `UpdatePlayingStatus` | Play/Pause/Seek — изменение статуса воспроизведения |
| `update_volume_info` | `UpdateVolumeInfo` | Изменение громкости |
| `update_active_device` | `UpdateActiveDevice` | Передача роли Master другому устройству (Cast) |
| `player_action_timestamp_ms` | `int64` | Время действия (мс) |
| `rid` | `string` | ID запроса (для корреляции ответа) |
| `activity_interception_type` | `enum` | Стратегия перехвата активности (см. ниже) |

### `PutYnisonStateResponse` (сервер → клиент, push)

| Поле | Тип | Описание |
| :--- | :--- | :--- |
| `player_state` | `PlayerState` | Текущее состояние плеера по мнению сервера |
| `devices` | `[]Device` | Все устройства в сессии с их параметрами |
| `active_device_id_optional` | `string` | ID устройства, которое сейчас является Master |
| `put_commands` | `[]Command` | Явные команды для активного плеера (Yandex-специфично) |
| `timestamp_ms` | `int64` | Время ответа сервера |
| `rid` | `string` | ID запроса |

---

## Типы исходящих сообщений (Update)

### 1. `UpdateFullState`
При холодном старте, подключении, после обрыва связи.

| Поле | Описание |
| :--- | :--- |
| `player_state` | Полная структура `PlayerState` |
| `device` | Информация об устройстве (device_id, type, title, capabilities) |
| `is_currently_active` | `true` если LMS сейчас играет или на паузе |

### 2. `UpdatePlayingStatus`
При нажатии Play/Pause или Seek.

| Поле | Описание |
| :--- | :--- |
| `progress_ms` | Текущая позиция (мс) |
| `paused` | `true` = пауза |
| `duration_ms` | Длина трека (мс) |
| `playback_speed` | Скорость (1.0 = нормальная) |

### 3. `UpdatePlayerState`
При смене трека, изменении очереди.

| Поле | Описание |
| :--- | :--- |
| `player_queue` | Актуальная очередь (`playable_list`, `current_playable_index`) |

### 4. `UpdateVolumeInfo`
Синхронизация громкости.

| Поле | Описание |
| :--- | :--- |
| `device_id` | Наш device_id |
| `volume_info.volume` | Громкость от `0.0` до `1.0` |

### 5. `UpdateActiveDevice`
Явная передача роли Master (Cast).

| Поле | Описание |
| :--- | :--- |
| `device_id_optional` | ID устройства, которое должно стать Master |

---

## Вложенные структуры

### `PlayerState`
- **`player_queue`** (`PlayerQueue`): очередь воспроизведения
- **`status`** (`PlayingStatus`): прогресс и статус play/pause

### `PlayerQueue`
- **`playable_list`** (`[]Playable`): список треков
- **`current_playable_index`** (`int`): индекс текущего трека
- **`entity_id`** (`string`): контекст (например `playlist:user123:45`, `album:778899`)
- **`entity_type`** (`enum`): `ALBUM`, `PLAYLIST`, `TRACK`, `VARIOUS`

### `Playable` (элемент очереди)
- **`playable_id`** (`string`): ID трека
- **`playable_type`** (`enum`): `TRACK`, `INFINITE` (радио), `LOCAL_TRACK`
- **`album_id_optional`** (`string`)
- **`from`** (`string`): контекст метрики (`desktop_win_radio`, `auto_next`, ...)
- **`title`** (`string`)
- **`cover_url_optional`** (`string`)

### `PlayingStatus`
- **`progress_ms`** (`int64`): текущая позиция
- **`duration_ms`** (`int64`): длина трека
- **`paused`** (`bool`)
- **`playback_speed`** (`float`): 1.0 = нормальная
- **`timestamp_ms`** (`int64`): локальное время клиента — сервер использует для экстраполяции позиции на пультах без ожидания следующего push

### `DeviceCapabilities`
- **`can_be_player`** (`bool`): устройство воспроизводит звук
- **`can_be_remote_controller`** (`bool`): устройство является пультом
- **`volume_granularity`** (`int`): шаг регулировки громкости

### `UpdateVersion` (версионность)
Каждое состояние сопровождается объектом версии для Optimistic Locking:
```json
{ "device_id": "...", "version": "1234567890", "timestamp_ms": "0" }
```
Если пришедшая версия старее сохранённой на сервере — обновление игнорируется.

---

## Роли устройств

| Роль | Флаги | Поведение |
| :--- | :--- | :--- |
| **Master (Active)** | `is_currently_active=true` | Воспроизводит звук. Единственный источник истины для `progress_ms`. |
| **Slave (Remote)** | `can_be_remote_controller=true`, `is_currently_active=false` | Пульт: отображает состояние Master, отправляет команды. Звук не воспроизводит. |
| **Passive** | `mute_events_if_passive=true` | Только слушает статус, не участвует в управлении. |

## `activity_interception_type`

| Значение | Когда использовать |
| :--- | :--- |
| `DO_NOT_INTERCEPT_BY_DEFAULT` | Обновление состояния без смены Master. Для рутинных state update. |
| `INTERCEPT_IF_NO_ONE_ACTIVE` | Стать Master только если нет активного устройства. **Использовать при подключении LMS.** |
| `INTERCEPT_EAGER` | Принудительно стать Master (Cast). Использовать при загрузке очереди на LMS по команде. |

---

## Роль LMS в протоколе Ynison

### LMS — всегда Master (Active Player)

LMS физически воспроизводит звук, поэтому он **всегда является Master**:

| Флаг | Значение для LMS |
| :--- | :--- |
| `can_be_player` | `true` |
| `can_be_remote_controller` | `false` |
| `is_currently_active` | `true` когда играет или на паузе; `false` когда остановлен |

Мобильное приложение и браузер — **Remote Controller (Slave)**. Они не воспроизводят звук, только отображают состояние и отправляют команды.

### Что сервер отправляет активному плееру

Сервер push-ует `PutYnisonStateResponse` всем устройствам. Дополнительно **активному плееру** (`active_device_id == наш device_id`) приходят `put_commands` — явные команды к исполнению.

#### Команды в `put_commands` (явные)

| Команда | Действие LMS |
| :--- | :--- |
| `PLAY` | `execute(['play'])` |
| `PAUSE` | `execute(['pause', 1])` |
| `NEXT` | `execute(['playlist', 'index', '+1'])` |
| `PREV` | `execute(['playlist', 'index', '-1'])` |
| `SEEK` | `execute(['time', $progress_ms / 1000])` |
| `STOP` | `execute(['stop'])` |

После выполнения каждой команды — немедленно отправить `update_player_state` с новым состоянием.

#### State-based изменения (из `player_state` в response)

Ynison — **state-based протокол**: Remote Controller не шлёт команду PAUSE — он отправляет `UpdatePlayingStatus` с `paused=true`, сервер ретранслирует всем. LMS реагирует на изменения в `player_state`:

| Изменение | Действие LMS |
| :--- | :--- |
| `status.paused` изменился | Синхронизировать play/pause |
| `player_queue.current_playable_index` изменился | **Не реагировать** — уже выполнено через `put_commands` NEXT/PREV |
| `status.progress_ms` резкий скачок | **Не синхронизировать** — вызывает рестарт стрима каждые 2-3 сек (интервал push Яндекса) |

### Что LMS отправляет серверу и когда

| Событие | Тип сообщения | `is_currently_active` |
| :--- | :--- | :--- |
| Подключение (холодный старт) | `UpdateFullState` | по факту |
| Начало воспроизведения | `UpdatePlayerState` | `true` |
| Пауза / возобновление | `UpdatePlayerState` | `true` |
| Смена трека (авто, конец трека) | `UpdatePlayerState` | `true` |
| Выполнена команда из `put_commands` | `UpdatePlayerState` | `true` |
| Изменение громкости | `UpdateVolumeInfo` | — |
| Остановка плеера | `UpdatePlayerState` | `false` |

Периодические (polling) обновления прогресса **не нужны** — `timestamp_ms` в `PlayingStatus` позволяет пультам самостоятельно экстраполировать позицию.

### Cast: передача воспроизведения на LMS

Сценарий: пользователь играет на телефоне, нажимает «Слушать на [LMS]».

1. Сервер устанавливает `active_device_id = наш device_id`
2. В `player_state` приходит `playable_list` с треками и `current_playable_index`
3. LMS обнаруживает: `active_device_id == наш id` И трек изменился
4. Действия LMS:
   - `playlist clear`
   - Загрузить все треки из `playable_list` как `yandexmusic://{playable_id}`
   - `playlist index {current_playable_index}`
   - Если `status.paused == false` → `play`
5. Отправить `UpdateFullState` с `is_currently_active=true`, `INTERCEPT_EAGER`

### Что LMS НЕ должен делать

- **Разрешать контексты** (`entity_id` типа `playlist:user:123`) — LMS управляет своей очередью сам.
  В Ynison есть два уровня описания воспроизведения: `entity_id` (абстрактный контекст — ссылка на плейлист/альбом) и `playable_list` (конкретные треки с ID). "Разрешить контекст" — значит пойти в API Яндекса, получить полный список треков по `entity_id` и построить из них `playable_list` (именно это делает librespot через `context_resolver.rs`). LMS этого не делает: при Cast сервер уже присылает готовый `playable_list` с конкретными треками, LMS берёт их напрямую как `yandexmusic://{playable_id}`. `entity_id` в этом случае — просто метаданные "откуда взята очередь", они игнорируются.
- **Синхронизировать state при `active_device_id != наш id`** — другой плеер активен, это не наши команды.
- **Seek по state-based обновлениям** — вызывает рестарт стрима каждые 2-3 секунды.
- **`can_be_remote_controller=true`** — LMS не является пультом.
- **`INTERCEPT_EAGER` при старте** — только `INTERCEPT_IF_NO_ONE_ACTIVE`, иначе LMS перехватывает воспроизведение с телефона при каждом переподключении.

---

## Известные проблемы текущей реализации (`Ynison.pm`)

| Проблема | Место в коде | Влияние |
| :--- | :--- | :--- |
| `is_currently_active=false` всегда | `_send_full_state_msg`, строка ~411 | Яндекс не считает LMS активным плеером, `put_commands` могут не приходить |
| `activity_interception_type = DO_NOT_INTERCEPT_BY_DEFAULT` при старте | `_send_full_state_msg` | LMS не перехватывает роль Master при подключении, даже если ничего не играет |
| `is_currently_active` отсутствует в `update_player_state` | `_send_one_off_command` | Сервер не знает об активности LMS при рутинных обновлениях |

### Исправления

```
# _send_full_state_msg:
is_currently_active => ($client->isPlaying() || $client->isPaused()) ? \1 : \0
activity_interception_type => "INTERCEPT_IF_NO_ONE_ACTIVE"   # при старте

# _send_one_off_command / update_state (верхний уровень сообщения):
is_currently_active => ($client->isPlaying() || $client->isPaused()) ? \1 : \0

# При Cast (после загрузки очереди):
activity_interception_type => "INTERCEPT_EAGER"
```

---

## Минимальный чеклист реализации

- [ ] `UpdateFullState` при подключении, `is_currently_active` по факту
- [ ] `activity_interception_type = INTERCEPT_IF_NO_ONE_ACTIVE` при старте
- [ ] `is_currently_active` динамически во всех исходящих сообщениях
- [ ] Выполнение `put_commands`: PLAY, PAUSE, NEXT, PREV, SEEK, STOP
- [ ] Sync play/pause из state-based изменений (только когда `active_device_id == наш`)
- [ ] **Без** seek-синхронизации из state
- [ ] Отправка `UpdatePlayerState` после каждого события плеера
- [ ] Cast: загрузка очереди из `playable_list` при смене `active_device_id` на наш
- [ ] `UpdateVolumeInfo` при изменении громкости LMS
- [ ] Применение `volume_info` из `devices[]` для нашего `device_id`
