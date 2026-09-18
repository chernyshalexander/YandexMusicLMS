# Расследование: сбой resume после power off/on плеера (>1 часа) на треках Yandex Music

Дата: 2026-09-18. Статус: расследование завершено, корневая причина установлена, фикс не реализован.
Следующая сессия: начать с разделов «Неизвестные места ядра (дозакрыть)» и «План исправления».

## Симптом

Воспроизведение трека Yandex Music → пользователь выключает плеер кнопкой power →
включает спустя достаточно долгое время (>1 часа ориентировочно) →
LMS пытается возобновить воспроизведение **с сохранённой позиции**:

- **Squeezebox Boom**: странный свистящий прерывистый звук (похоже на неправильную
  расшифровку/демуксацию потока).
- **Squeezebox Touch**: показывает ошибку трека.
- Воспроизведение восстанавливается по нажатию play / next (это свежий запрос трека —
  getNextTrack → свежий URL).

Прошлые попытки фикса в коде плагина проблему НЕ устранили (см. ниже).

## Корневая причина (установлена)

Две находки складываются в объяснение:

### 1. Resume-путь проходит МИМО getNextTrack плагина

- `getNextTrack` плагина (ProtocolHandler.pm:275–378) всегда перезапрашивает URL через
  `get_track_direct_url` и обновляет `$song->streamUrl()` — это единственная точка
  обновления URL/ключей, и она срабатывает **только при старте нового трека**.
- Возобновление с позиции (power-on reconnect / underrun) в ядре идёт через
  `_Continue` → `_Stream` (StreamingController.pm:946–965, `reconnect => 1`) или
  `JumpToTime` → `_Stream` — в обоих случаях **существующий объект Song переиспользуется,
  getNextTrack НЕ вызывается**, открывается **старый streamUrl** (CDN-URL протухает).
- `Protocols/HTTP.pm:964–966`: при любом (пере)открытии LMS всегда шлёт
  `Range: bytes=N-` (restartOffset || sourceStreamOffset).

### 2. TTL кэша ключей = ровно 3600с — совпадает с порогом «больше часа»

- ProtocolHandler.pm:319: codec/aes_key/bitrate кэшируются в `yandex_meta_{track_id}`
  с TTL **3600 секунд**.
- `new()` (ProtocolHandler.pm:77–145) читает этот кэш при создании HTTP-сокета потока.
  После >1 ч — cache miss → **шифр AES-CTR не устанавливается**, content_type падает
  в 'audio/mpeg', фолбэка с перезапросом нет → зашифрованные байты едут в декодер как есть.
- Сам CDN-URL нигде не кэшируется — живёт только в памяти объекта Song (`streamUrl`),
  срок жизни подписанного URL у Яндекса ограничен.

### Почему разные симптомы у Boom и Touch

- **Boom (свист):** либо расшифровка с неверным CTR-счётчиком при Range-resume
  (см. фикс b35b6c6 — сомнительно, что contentRange() вообще существует у класса сокета),
  либо расшифровка вообще не настроена (cache miss) → шум.
- **Touch (ошибка трека):** старый URL → CDN отдаёт 403/XML-error → magic-bytes проверка
  (ProtocolHandler.pm:914–921, 960–968) возвращает EOF → ядро трактует как конец/ошибку трека.
  Если тело ошибки gzip/бинарное — не ловится и идёт в декодер как шум.

## Путь resume в ядре LMS (проверено, файл:строка)

- Power off: `Slim/Player/Player.pm` `power()` (~202+):
  - для remote-потоков всегда **stop** (bug 8776; `$controller->isPlaying(1)` — pause только
    для локальных файлов при pref powerOnResume='PauseOff-PlayOn');
  - ставит pref `playingAtPowerOff`; `Slimproto::slimproto_close` сохраняет `positionAtDisconnect`.
- Power on: `resumeOnPower()` (Player.pm:300–325):
  - физическое включение → просто `$client->execute(["play"])`;
  - reconnect плеера (`$connect`) → `playlist jump $index 1 0 {timeOffset => positionAtDisconnect}`
    — **вот откуда берётся resume с позиции**.
- `execute(["play"])` → `Source::playmode('play', $seekdata)` (Source.pm:68–80) →
  `controller->play` → событие `Play` {index, seekdata} → `_StopGetNext` → `_getNextTrack`
  (StreamingController.pm:629) → `Song->new($index, $seekdata)` → `getNextSong` →
  **`$handler->getNextTrack` вызывается** (Song.pm:319–320). Этот путь даёт свежий URL.
- Но `_Continue` (underrun/дисконнект, StreamingController.pm:946–965) и `jumpToTime`
  (StreamingController.pm:2214) → `_Stream` с существующим Song → getNextTrack не зовётся.
- `_Stream` (StreamingController.pm:1144) → `$song->open($seekdata)` → SongStreamController →
  `Slim::Player::Protocols::HTTP(S)->new` с seekdata → Range-запрос.
- AES-CTR расшифровка в плагине: `_sysread` (ProtocolHandler.pm:875–981),
  `${*$sock}{yandex_offset}`, счётчик = 12 нулевых байт + номер блока BE, block = stream_pos/16.
- `canDirectStreamSong` → 0 (всё через прокси сервера), `canEnhanceHTTP` → 2.

## КЛЮЧЕВАЯ НАХОДКА: хук updateOnStream (штатный механизм ядра, никем не используется)

`_Stream` (StreamingController.pm:1168–1190) перед **каждым** (пере)открытием потока
(включая reconnect=1 и JumpToTime-пути) вызывает опциональный метод хендлера:

```perl
# Allow protocol hander to update $song before streaming - used when song url
# contains params which may become stale
# updateOnStream will call either the success or fail callbacks
if ( $song->currentTrackHandler()->can('updateOnStream') && !$params->{'updateOnStreamCallback'}) {
    ...
    $song->currentTrackHandler()->updateOnStream($song, $successCb, $failCb);
```

- Проверено grep по всему slimserver: **ни один хендлер его не реализует**
  (включая Spotty в /home/chernysh/Projects/Spotty-Plugin).
- Это идеальная точка фикса: асинхронно (есть колбэки!) обновить URL + кэш ключей
  перед открытием соединения.

## Предыдущие попытки фикса в коде плагина (git, ветка experiment)

1. `59273c7` (2026-04-27): magic-bytes детект error-страницы в `_sysread` при offset==0.
2. `723b196` (2026-04-28): то же на **любом** offset (ProtocolHandler.pm:914–921, 960–968,
   паттерны `<?xm|<err|<!do|<htm` → EOF + лог "Stream URL expired or denied").
3. `b35b6c6` (2026-06-23, cherry-pick 041dd11 в master): синхронизация AES-CTR offset с
   HTTP Range: в `new()` (ProtocolHandler.pm:91–139) читается `$sock->contentRange`,
   `yandex_offset` инициализируется байтом из Content-Range; при initial_offset>0
   внутренний MP4-демукс отключается (фолбэк на ffmpeg).
4. Сопутствующие: `f8b1d73`/`88973c9` (canEnhanceHTTP=2 — полная буферизация),
   `6da7e64`/`93fe660` (aac-mp4 полный буфер перед транскодом), `6daccd3`/`caab351`
   (TTL-деградация кэша метаданных).

Почему не сработали: все три лечат симптомы в `_sysread`/`new()`, а корень —
resume-путь **не обновляет** URL и ключи (мимо getNextTrack) + TTL кэша 3600с.

## Прочие факты

- Кэш `yandex_meta_{track_id}` пишется из двух мест: ProtocolHandler.pm:319 (stream-данные,
  TTL 3600) и Browse/Common.pm:168 (метаданные, TTL 90 дней) — записи мержатся.
- URL encraw получается через `/get-file-info?...&transports=encraw` (API/Async.pm:953–1004,
  HMAC-SHA256 подпись); mp3-путь — `/tracks/{id}/download-info` + MD5-подпись
  (API/Async.pm:1089–1182).
- HTTP-статус медиа-ответа нигде не проверяется (только 4-байтовый magic-детект тела).
- `requestString`, `getStreamHeaders`, `$args->{seek}` в плагине не используются.
- FLAC seek: `initiateFrameAlign` под INITIAL_BLOCK_ONSEEK (ProtocolHandler.pm:1037–1044).
- База хендлера: `Slim::Player::Protocols::HTTPS`.

## Неизвестные места ядра (дозакрыть в следующей сессии, read-only)

1. `playlistJumpCommand` (Commands.pm; dispatch: Request.pm:568, параметры
   `_index/_fadein/_noplay/_seekdata`) — как timeOffset превращается в seekdata и какой
   event идёт (Play vs JumpToTime).
2. Кто вызывает `resumeOnPower($connect=1)` (Slimproto, реконнект клиента) — какие
   события при включении Boom/Touch реально происходят (отключается ли плеер при power off).
3. `slimproto_close` → сохранение `positionAtDisconnect`.
4. Полный `new()` плагина (ProtocolHandler.pm:77–145) — поведение при cache miss.
5. `isPlaying(1)` в StreamingController — точная семантика (пауза vs stop при power off).
6. `Song::open` → SongStreamController: конвертация seekdata {timeOffset} →
   sourceStreamOffset (байты) для remote-треков.
7. Playlist.pm:432 — контекст `execute(['playlist','jump', $playingSongIndex, ...])`.
8. Семантика `canEnhanceHTTP=2` в ядре.
9. Существует ли `contentRange()` у реального класса сокета (иначе фикс b35b6c6 мёртвый код).
10. Что реально отдаёт CDN по протухшему URL (статус, Content-Encoding, тело) — снять лог.

## План исправления (по приоритету)

1. **Основной фикс — реализовать `updateOnStream` в ProtocolHandler.pm.**
   В хуке: асинхронно re-resolve `get_track_direct_url($track_id)`, обновить
   `$song->streamUrl()` и кэш `yandex_meta_` (codec/aes_key/bitrate, TTL свежий),
   затем `successCb->()`; при ошибке — `failCb->()`.
   Ядро вызывает хук перед каждым (пере)открытием, включая reconnect и JumpToTime →
   свежий URL и ключ при любом resume. Чинит «>1 часа» в корне.
   Внимание: хук вызывается и при обычном старте трека (после getNextTrack) — учесть,
   чтобы не делать двойной запрос (можно пропускать, если URL свежий, напр. моложе N минут,
   или проверять `$params->{updateOnStreamCallback}` — см. код _Stream).
2. **Устойчивость к мусору (defence in depth):**
   - проверка HTTP-статуса медиа-ответа (403/410) при открытии, если доступен из сокета;
   - расширить magic-детект: валидные сигнатуры (fLaC, OggS, ID3, ADTS sync 0xFFF) —
     если первое чтение не похоже на аудио → ошибка потока (StreamingFailed), не шум;
   - EOF при magic-детекте прокидывать как ошибку, а не тихий конец.
3. **Last resort (просьба пользователя, если 1–2 не помогут):** запретить resume с позиции
   для yandexmusic: `canSeek` → 0 (ядро при !canSeek + restartIfNoSeek просто остановит
   вместо кривого resume) и/или перехват в `canDoAction`; воспроизведение всегда свежим
   getNextTrack с нуля.

## Тестирование

- server.log с debug: `player.streaming`, `player.playing`, `plugin.yandex`.
- Репро: play → power off → подождать/сократить TTL/подменить URL на протухший → power on.
- В логе смотреть: «Restarting stream at offset» / «Restarting playback at time offset»
  (StreamingController) и вызов updateOnStream.
- Критерии: Boom — нет свиста; Touch — нет ошибки трека; обычная навигация, seek,
  пауза/плей, переходы между треками не регрессировали (в т.ч. короткие паузы < 1 ч).

## Как продолжить в новой сессии

(устарело — см. раздел ниже)

## ОБНОВЛЕНИЕ 2026-09-18 (вечер): сравнение с Deezer/Qobuz/Tidal + утверждённый план

Проверены три боевых плагина: /home/chernysh/Projects/lms-deezer, /home/chernysh/Projects/plugin-Qobuz,
/home/chernysh/Projects/lms-plugin-tidal (детальные отчёты агентов с file:line).

### Факты

1. **Ни один из трёх НЕ реализует `updateOnStream`** и вообще не перезапрашивает URL при
   resume/seek/reconnect. Все три переоткрывают существующий Song со старым streamUrl —
   та же уязвимость. Выживают потому, что их CDN-URL живут дольше; у Qobuz URL-кэш 10 мин
   (API.pm:21 `URL_EXPIRY => 600`), так что свежий старт трека всегда даёт свежий URL.
2. **Deezer решает проблему «свиста» иначе** (lms-deezer/ProtocolHandler.pm:119–158):
   декрипт-состояние при Range-resume восстанавливается **из seekdata до открытия
   соединения**: `deezer_count = int($seekdata->{sourceStreamOffset} / 2048) + 1`,
   `deezer_align = 2048 - offset % 2048` (Blowfish-CBC, фиксированный IV → CBC-состояние
   зависит только от индекса чанка). Заголовки ответа не используются вообще.
3. Наш `new()` инициализирует `yandex_offset` через `$sock->contentRange` — в момент
   конструктора ответ сервера ещё не существует (HTTP-запрос ещё не отправлен), метод
   возвращает undef → offset всегда 0 → неверный CTR-счётчик при Range-resume → свист.
   Это объясняет, почему фикс b35b6c6 не сработал.
4. Подтверждено в ядре: `seekdata` — аксессор Song (Song.pm:65), заполняется в
   `Song::open` (Song.pm:365) ДО вызова `new()` хендлера; если есть только timeOffset,
   ядро само досчитывает `sourceStreamOffset` через getSeekData (Song.pm:368–371).
   `pluginData` — штатный аксессор Song (Song.pm:699).

### Утверждённый минимальный план (пользователем одобрен)

- Шаг 0: обновить этот документ (этот раздел).
- Шаг 1 (коммит 1): `updateOnStream` в ProtocolHandler.pm — перед каждым (пере)открытием
  потока, если URL не разрешался последние 300 с (метка в `$song->pluginData('yandex_url_resolved_at')`),
  асинхронно re-resolve `get_track_direct_url` → обновить streamUrl + кэш yandex_meta.
  getNextTrack помечает время разрешения → нет двойного запроса при обычном старте.
- Шаг 2 (коммит 2): `yandex_offset` из seekdata (`restartOffset || sourceStreamOffset`)
  вместо `$sock->contentRange` — паттерн Deezer.
- Шаг 3 (коммит 3): TTL кэша yandex_meta (стрим-часть) 3600 → 86400 (ключ/кодек — константы трека).
- Шаг 4 (hardening с аудио-сигнатурами) — отложен: не нужен для лечения, риск ложных срабатываний.
- Шаг 5 (last resort `canSeek` → 0) — в резерве, только если шаги 1–2 не подтвердятся на плеерах.

### Что тестировать вручную (Boom/Touch)

1. Основной репро: play трека YM → power off → подождать >1 ч (или временно уменьшить TTL/
   подменить streamUrl на протухший) → power on → должно играть с места остановки без свиста/ошибки.
2. В server.log (debug `player.streaming`, `plugin.yandex`): на resume-пути должно быть
   «YANDEX: updateOnStream: stream URL is Ns old, re-resolving» + свежий resolve + в new()
   «Range resume/seek at byte N, initializing AES-CTR offset from seekdata».
3. Регрессии: обычный старт трека (один resolve, updateOnStream сразу «свежо»), seek внутри
   трека, пауза/плей < 5 мин и > 5 мин, next/prev, синхронная группа.
4. Если не вылечится — вернуться к шагу 5 (last resort) и обсудить.
