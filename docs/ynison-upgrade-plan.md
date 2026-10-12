# Сравнительный анализ реализаций Yandex Music и план доработки Ynison в LMS-плагине

Дата: 2026-07-06
Рассмотренные кодовые базы:

| Проект | Язык/платформа | Роль |
|---|---|---|
| `ma-provider-yandex-music` | Python / Music Assistant | Музыкальный провайдер (каталог, стриминг, радио, аудиокниги) |
| `ma-provider-yandex-ynison` | Python / Music Assistant | Отдельный plugin-провайдер: протокол Ynison («Yandex Connect») |
| `Projects/yandex` (этот репозиторий) | Perl / Lyrion Music Server | Монолитный плагин: каталог + стриминг + Ynison в одном пакете |

В экосистеме MA функциональность разделена на два репозитория: `yandex_music`
(музыкальный провайдер) и `yandex_ynison` (плагин, реализующий Ynison поверх
первого через задокументированный публичный интерфейс). В LMS-плагине всё
живёт в одном пакете: `Ynison.pm` (транспорт + построители сообщений) и
интеграционный слой в `Plugin.pm`.

---

## 0. Срочно — до всего остального

При повторной проверке (после первого прохода отчёта) обнаружены два момента,
не связанных напрямую с качеством кода Ynison, но требующих действий раньше,
чем что-либо из планов ниже.

### 0.1. В публичном репозитории закоммичены персональные данные пользователя — **действовать немедленно**

Репозиторий `github.com/chernyshalexander/YandexMusicLMS` (origin, публичный)
содержит закоммиченные файлы:

- `test/debug-user.json` (коммит `eec0d416`, 2026-04-22) — сырой ответ API
  `/account/status` с полями `account.login`, `account.fullName`,
  `account.firstName`, `account.secondName`, `account.displayName`,
  `account.uid`, `defaultEmail`, `account.birthday`.
- `test/ynison_events.jsonl` — перехваченный трафик Ynison с реальными
  `device_id`/`session.id` для всех устройств аккаунта (телефон, несколько
  LMS-плееров с их пользовательскими именами: «Kitchen», «Touch Home» и т. д.).

Это не гипотетический риск: файлы существуют в истории git публичного
репозитория прямо сейчас. `device_id`/`session_id` сами по себе не являются
паролем, но в сочетании с `uid`/`login`/`email` из `debug-user.json` дают
достаточно данных для социальной инженерии или для обращения в поддержку
Яндекса от имени владельца аккаунта.

**Действие:**
1. Немедленно ротировать OAuth-токен аккаунта, использованного при захвате
   (см. также `test/token.txt` — не закоммичен, но лежит рядом; проверить,
   не «протёк» ли он в других коммитах: `git log --all -p -- test/token.txt`).
2. Удалить оба файла из истории репозитория (`git filter-repo` или
   BFG Repo-Cleaner — простой `git rm` недостаточен, файлы остаются в старых
   коммитах публичного репо и в форках/клонах).
3. Добавить `test/debug-*.json`, `test/*.jsonl`, `test/token.txt` в
   `.gitignore` — это уже частично сделано (`token.txt` не в git), но правило
   явно не описано, отсюда и утечка.
4. Просмотреть остальные `test/*.json` (`debug-dw-info.json`,
   `debug-tracks-data.json`, `debug-tracks.json`) на предмет аналогичных
   персональных полей.

### 0.2. Тестовый набор Ynison — не тесты, а grep по исходнику (ложное чувство защищённости)

`test/ynison_integration_tests.pl` (упомянутый как «24/24 PASS» в
`test/IMPROVEMENTS_SUMMARY.md`, который заявляет статус «✅ READY FOR MERGE»)
**не выполняет ни одной строки кода из `Ynison.pm`**. Каждый из 24 тестов —
это регулярное выражение поверх текста файла:

```perl
# test/ynison_integration_tests.pl:62-64
test("Ynison.pm defines _detect_command_type function", sub {
    assert_true($ynison_source =~ /sub _detect_command_type/, 'Function exists');
});
```

Тест проверяет, что в файле **есть строка** `sub _detect_command_type`, — не
то, что функция работает правильно. Аналогично для всех 24 пунктов:
проверяется наличие констант (`RID_TIMEOUT`, `MAX_FRAME_SIZE`), наличие полей
(`sent_commands`, `log_buffer`) и наличие ветвлений
(`if ($reason eq 'auth_error')`) — но ни разу не вызывается ни одна функция
и не проверяется ни один результат.

Это ровно то, что раздел «Test-Driven Development» в `CLAUDE.md` соседнего
MA-провайдера (`ma-provider-yandex-music`, не в этом репозитории — у
`Projects/yandex` своего `CLAUDE.md` нет) описывает как «tautological test»:
тест, который не может упасть, если реализация сломана (переименуйте
`_detect_command_type` во что угодно — упадёт только тест на само имя, а не
на поведение). Приведено здесь как общепринятый принцип, а не потому что
на этот репозиторий формально распространяется чужой CLAUDE.md.
`IMPROVEMENTS_SUMMARY.md` на основании этого набора делает вывод «Ready for
peer review and merge to master branch» — это вывод, не подтверждённый ни
одним реальным тестом. В частности, echo-детект (Задача 1.3 ниже), который
`IMPROVEMENTS_SUMMARY.md` описывает как «Complete ✅, prevents feedback
loops», **в реальности содержит открытую проблему** (RID+латентность вместо
authorship-чека) — расхождение между «протестировано» и «работает корректно»
как раз из-за тавтологичности теста.

**Действие:** при выполнении задач фазы 1–2 ниже писать реальные тесты
(вызывающие `_encode_ws_text_frame`/`_extract_ws_frame`,
`build_pause_request`, echo-классификацию как функции, с проверкой
возвращаемого значения), а не расширять `ynison_integration_tests.pl` новыми
grep-проверками. Существующий файл имеет смысл переименовать
(например, в `ynison_source_lint.pl`) или явно пометить в шапке, что это не
регрессионный тест поведения.

---

## 1. Общее сравнение проектов (вне Ynison)

### Сильные стороны LMS-плагина (`Projects/yandex`)

1. **Продвинутый стриминговый конвейер** (`ProtocolHandler.pm`, 1089 строк):
   расшифровка AES-CTR «на лету» через перехват `_sysread`, чистый Perl
   MP4-демультиплексор для FLAC-in-MP4 / AAC-MP4 / HE-AAC, разбор FLAC-заголовков,
   `formatOverride`/`getFormatForURL` с выбором backend-а демультиплексирования.
   Это функционально сопоставимо (а по числу поддерживаемых контейнеров местами
   шире), чем у MA-провайдера, где часть работы делает ffmpeg.
2. **Богатый browse-слой**, разнесённый по модулям (`Browse/Collection.pm`,
   `Favorites.pm`, `Radio.pm`, `Search.pm`, `InfoMenu.pm`): «Моя волна»,
   Build My Vibe, My Vibe Wheel, My Vibe by Artist, жанровые радио, подкасты,
   аудиокниги, мульти-аккаунты, локализация (`strings.txt`, RU/EN).
3. **Интеграция с библиотекой LMS** (`Importer.pm`) — онлайн-библиотека
   Яндекса видна в локальной библиотеке; у MA это делает сама платформа.
4. **Rotor-фидбек** (`_handleRotorFeedback` в `Plugin.pm`): trackStarted /
   trackFinished / skip с учётом реально проигранного времени — улучшает
   персонализацию. Реализация полная и аккуратная.
5. Асинхронный API-слой с разделением Async/Sync (`API/Async.pm`,
   `API/Sync.pm`) — соответствует канону LMS-плагинов.

### Слабые стороны LMS-плагина

1. **Нет автоматических тестов.** Каталог `test/` — это ~70 разовых
   исследовательских скриптов (`test_*.pl`), отчёты и debug-дампы, а не
   регрессионный набор. Ни один не запускается в CI (CI отсутствует).
2. **Мёртвый код в корне:** `Ynison_old.pm` (945 строк) нигде не подключается
   (`grep Ynison_old` по `*.pm`/`install.xml` — пусто) — подлежит удалению.
3. `Plugin.pm` перегружен: жизненный цикл Ynison, синхронизация состояний,
   rotor-фидбек и browse-роутинг в одном файле.
4. `test/token.txt` с живым токеном лежит в рабочей копии (в git не
   закоммичен, но в `.gitignore` его тоже нет — одна ошибка `git add .`
   до утечки).

### Сильные стороны MA-экосистемы

1. **Инженерная дисциплина:** ~8 тыс. строк тестов на 8 тыс. строк кода
   (fixtures + syrupy-снапшоты), CI (ruff, mypy, codespell, pre-commit),
   спецификации фич (`specs/`), changelog-дисциплина, документация как сайт.
2. **Слоистая архитектура:** auth / api_client / parsers / streaming /
   provider — c типизацией (mypy strict) и явными публичными контрактами
   между провайдерами (`protocols.py` — структурный Protocol).
3. **Зрелый auth:** QR-логин, `x_token` c реактивным обновлением по 401,
   кэш токенов с TTL и коалесингом конкурентных обновлений.
4. **Rate-limit-митигация** для API Яндекса (throttler, backoff, retry).

### Слабые стороны MA-экосистемы (для полноты картины)

1. Двухпроцессная модель ynison-плагина в stream-режиме — двойной проход
   ffmpeg (per-track + per-session), больше CPU, чем прямой стриминг LMS.
2. Ynison-плагин не синхронизирует громкость (в LMS-плагине входящая
   синхронизация громкости есть — это то, что MA мог бы позаимствовать).
3. Один инстанс плагина = одно виртуальное устройство; в LMS каждый плеер
   автоматически становится Ynison-устройством.

---

## 2. Ynison: что и как реализовано в каждом проекте

### 2.1. Архитектура

**LMS (`Ynison.pm` + `Plugin.pm`):**

- WebSocket реализован вручную поверх `Slim::Networking::Async`:
  кодирование/декодирование фреймов, маскирование, ping/pong, close-фреймы,
  частичные записи, очередь исходящих фреймов с таймаутами.
- Двухшаговое соединение (редиректор → state-сервис), FSM из пяти состояний.
- Регистрация устройства (`update_full_state` c `can_be_player`,
  `volume_info`), keepalive-ping каждые 20 с.
- Echo-фильтрация: RID-трекинг (rid + эвристика по латентности < 3 с)
  плюс в `Plugin.pm` проверка автора `player_queue.version.device_id`
  и сравнение `sent_paused`.
- Реконнект: три стратегии задержек по классу ошибки (normal / timeout /
  network), статистика попыток; при auth-ошибке — максимум 3 попытки
  и **окончательная остановка**.
- Применение состояния: пересборка очереди LMS из `playable_list`
  («Cast»), синхронизация play/pause, переход по индексу, входящая
  синхронизация громкости, «Local override» (пустое состояние при переходе
  на локальный контент — телефон корректно отпускает сессию).

**MA (`ynison_client.py` + `provider.py`):**

- WebSocket через aiohttp (`heartbeat=`), тот же двухшаговый коннект.
- Echo-классификация **по авторству обоих version-блоков**
  (`player_queue.version.device_id` **И** `status.version.device_id`) —
  выработана после боевых инцидентов (RC-1 в v1.9.1): сервер
  перештамповывает `version.version` (`random(int64)`), поэтому сравнение
  значений/rid ненадёжно, надёжно только авторство.
- Нормализация типов: все timestamp/version-поля приводятся к строкам —
  целые числа в `progress_ms`/`duration_ms`/`version.*` вызывают HTTP 500
  и разрыв WS на стороне Яндекса.
- Клампинг прогресса: `progress > duration` ⇒ ошибка 400030001 и разрыв WS,
  поэтому всегда `min(progress, duration)`.
- Реконнект: экспоненциальный backoff (5→60 c) с джиттером ±20 %,
  **бесконечные** повторы, колбэк обновления токена при 401,
  «settle window» 2 с после реконнекта (первый входящий стейт может быть
  ретрансляцией нашего же устаревшего состояния — игнорируется),
  немедленный реконнект по кодам ребаланса (`YNISON_RECONNECT_ERROR_CODES`).
- `update_session_params(mute_events_if_passive=True)` — сервер не шлёт
  события чужих устройств, пока мы пассивны (меньше трафика и ложных эхо).
- Прогресс-heartbeat каждые 5 с (`update_playing_status`) — прогресс-бар в
  приложении ЯМ живой, сервер не ребалансирует активное устройство.
- **Пополнение радио-очередей**: для entity_type RADIO активное устройство
  само дозапрашивает треки через rotor-API, включая префетч на
  предпоследнем треке и push расширенного списка (`update_player_state`),
  чтобы в приложении работала кнопка «след. трек».
- Двусторонний seek: входящий — детект дрейфа (порог + grace-период +
  echo-фильтр), исходящий — `update_playing_status` с новой позицией.
- Перехват управления: `update_active_device` (кнопка «играть здесь»),
  а при уходе активности на другое устройство — остановка своего плеера.
- Idempotency-кэш команд (TTL 1 с) против «эхо-штормов».

### 2.2. Сводная таблица возможностей

| Возможность | LMS `Ynison.pm` | MA `yandex_ynison` |
|---|---|---|
| Двухшаговый коннект (редиректор → state) | ✅ | ✅ |
| Регистрация устройства | ✅ (+`volume_info`) | ✅ |
| Cast очереди с телефона | ✅ (нативная очередь LMS) | ✅ (stream- и handoff-режимы) |
| Play/pause/next/prev (входящие) | ✅ | ✅ |
| Отражение локальных событий (исходящие) | ✅ (по событиям) | ✅ (события + heartbeat 5 с) |
| Строковые типы timestamp/version | ❌ (int → риск 500) | ✅ |
| Клампинг progress ≤ duration | ❌ | ✅ |
| Echo-детект по авторству обоих блоков | ❌ (rid + только queue-автор) | ✅ |
| Периодический прогресс-heartbeat | ❌ | ✅ |
| Пополнение радио-очереди (RADIO) | ❌ | ✅ (+префетч) |
| Входящий seek | ❌ | ✅ |
| Исходящий seek | ❌ | ✅ |
| Остановка при перехвате другим устройством | ❌ | ✅ |
| `update_active_device` («играть здесь») | ❌ | ✅ |
| `mute_events_if_passive` | ❌ | ✅ |
| Реконнект: бесконечный + jitter + settle window | ❌ (auth: стоп после 3) | ✅ |
| Реакция на коды ребаланса сервера | ❌ | ✅ |
| Обновление токена при 401 в реконнекте | ❌ | ✅ |
| Синхронизация громкости (входящая) | ✅ | ❌ |
| Синхронизация громкости (исходящая) | ❌ (только при регистрации) | ❌ |
| Автотесты протокола | ❌ | ✅ (1871 строк на клиент) |

**Вывод:** реализация Ynison в MA заметно более зрелая: она закрывает целый
класс протокольных ловушек (типы полей, клампинг, эхо, ребаланс), которые в
LMS-версии либо не обработаны, либо обработаны эвристиками, и добавляет
функции, которых в LMS нет вовсе (радио-пополнение, seek, heartbeat,
takeover). При этом транспортный слой LMS (ручной WebSocket) добротный и
менять его на другой не нужно — нужно доработать логику поверх него.

---

## 3. План доработки LMS-плагина

Формат каждой задачи: **Что / Зачем / Где / Как / Критерии приёмки**.
Оценки даны для разработчика уровня middle, знакомого с Perl, но не с LMS.
Перед началом рекомендуется прочитать `Ynison.pm` целиком (~1300 строк) и
раздел «Ynison protocol notes» ниже.

### Фаза 1. Корректность протокола (без новых функций)

#### Задача 1.1. Строковые типы для timestamp/version-полей — **критично**

- **Что:** все поля `version.version`, `version.timestamp_ms`,
  `progress_ms`, `duration_ms`, `player_action_timestamp_ms` в исходящих
  сообщениях должны сериализоваться как JSON-строки, не числа.
- **Зачем:** сервер Ynison отвечает HTTP 500 и рвёт WebSocket, получив
  целые числа в этих полях (задокументировано в MA:
  `make_version_block` / `normalize_player_state_timestamps`
  в `ynison_client.py:51-93`). Сейчас это источник «случайных» разрывов.
- **Где:** `Ynison.pm`:
  - `_new_version` (~строка 921): `version => int(rand(10**18))` и
    `timestamp_ms => _get_timestamp()` — оба int;
  - `build_pause_request` (~979): `progress_ms => ... // 0` — дефолт int;
  - `build_change_track_request` (~1015): `progress_ms => 0`,
    `duration_ms => 0` — int;
  - `update_state`/`_build_player_state` — уже строки (`"$dur_ms"`), не трогать.
- **Как:** принудительная строковая интерполяция. В Perl + JSON::XS скаляр,
  использованный последним как строка, кодируется строкой:

  ```perl
  sub _new_version {
      my ($self) = @_;
      my $v  = int(rand(10**18));
      my $ts = _get_timestamp();
      return {
          device_id    => $self->{device_id},
          version      => "$v",      # строка!
          timestamp_ms => "$ts",     # строка!
      };
  }
  ```

  Аналогично `progress_ms => "0"`, `duration_ms => "0"`, дефолт
  `$current_status->{progress_ms} // "0"`. Единообразно: любое числовое
  значение перед вставкой в исходящий hash оборачивать в `"" . $x`.
- **Приёмка:** в debug-логе (`ynison_debug`) исходящий JSON содержит
  `"version":"123..."` и `"progress_ms":"0"` в кавычках; за 24 ч работы нет
  разрывов WS сразу после отправки команды.
- **Оценка:** 1–2 ч.

#### Задача 1.2. Клампинг прогресса

- **Что:** перед любой отправкой прогресса гарантировать
  `progress_ms <= duration_ms`; при `duration_ms == 0` прогресс не слать.
- **Зачем:** `progress > duration` ⇒ ошибка Ynison 400030001 и разрыв WS
  (MA: `_send_progress_to_ynison`, `provider.py:1106-1143`). В LMS
  `Slim::Player::Source::songTime` в конце трека может слегка «перелезать»
  за длительность.
- **Где:** `Ynison.pm::_build_player_state` (расчёт `$prog_ms`) и
  `build_pause_request`.
- **Как:**

  ```perl
  $prog_ms = $dur_ms if $dur_ms > 0 && $prog_ms > $dur_ms;
  ```

- **Приёмка:** доигрывание трека до конца при активной Ynison-сессии не
  приводит к разрыву WS.
- **Оценка:** 0.5 ч.

#### Задача 1.3. Echo-детект по авторству обоих version-блоков

- **Что:** заменить связку «RID + латентность» и «автор только
  player_queue» на правило: *входящее состояние — наше эхо тогда и только
  тогда, когда **и** `player_queue.version.device_id`, **и**
  `status.version.device_id` равны нашему `device_id`*.
- **Зачем:** (а) сервер перештамповывает `version.version` и не обязан
  возвращать `rid`, эвристика по латентности даёт и ложные срабатывания,
  и пропуски; (б) проверка только queue-автора «проглатывает» реальную
  команду пользователя: чужое изменение статуса поверх нашей очереди
  придёт с нашим queue-автором и чужим status-автором — сейчас такой кейс
  спасает лишь костыль `sent_paused`. Это ровно инцидент RC-1 из MA
  (см. `_classify_state_as_echo`, `ynison_client.py:437-459`).
- **Где:** `Plugin.pm::_handle_yandex_state_update` (~строки 337–350);
  RID-механику в `Ynison.pm` (`sent_commands`, `_detect_command_type`,
  `_cleanup_old_commands`) после перехода можно удалить.
- **Как:**

  ```perl
  my $our_id   = $ynison->device_id;
  my $q_author = (($player_state->{player_queue} // {})->{version} // {})->{device_id} // '';
  my $s_author = (($player_state->{status}       // {})->{version} // {})->{device_id} // '';
  if ($q_author eq $our_id && $s_author eq $our_id) {
      $log->debug('YANDEX: Skipping own echo (both version blocks ours)');
      return;
  }
  ```

  Проверку `sent_paused` можно оставить как дополнительную страховку на
  переходный период, но основным должен стать двойной authorship-чек.
- **Приёмка:** сценарий «LMS играет → пауза с телефона → пауза срабатывает,
  затем play с телефона → срабатывает» устойчив; в логах нет циклов
  pause/play (эхо-шторма).
- **Оценка:** 2–3 ч (включая ручное тестирование с телефоном).

#### Задача 1.4. Обработка ошибок сервера и кодов ребаланса

- **Что:** распознавать во входящем сообщении объект `error`; при коде
  ребаланса (`error.details.'ynison-error-code'`) — немедленный реконнект,
  прочие ошибки — логировать и продолжать.
- **Зачем:** сервер Ynison периодически «переселяет» клиентов на другой
  хост; без обработки LMS-плагин узнаёт об этом только по разрыву сокета
  и ждёт полный backoff. MA: `_message_loop`, `ynison_client.py:648-661`.
- **Где:** `Ynison.pm::_on_message_received` — до передачи слушателям.
- **Как:**

  ```perl
  if (my $err = $msg->{error}) {
      my $code = eval { $err->{details}{'ynison-error-code'} } // '';
      $log->warn("Ynison error response: code=$code");
      if ($code) {  # при желании сузить до списка кодов ребаланса
          $self->_schedule_reconnect('rebalance');
      }
      return;
  }
  ```

  В `_get_reconnect_strategy` добавить ветку `rebalance` с минимальной
  задержкой (например 1–5 с).
- **Приёмка:** при получении error-сообщения плагин переподключается, не
  скармливая его `_apply_yandex_state`.
- **Оценка:** 1–2 ч.

#### Задача 1.5. Потеря вложенного `player_queue.queue.wave_queue` при next/prev с LMS — **баг, найден в перехваченном трафике**

- **Что:** реальный трафик протокола (`test/ynison_events.jsonl`, захвачен
  локально) показывает, что `player_queue` — это не плоский объект из
  документации, а содержит дополнительный вложенный ключ `queue`:

  ```json
  "player_queue": {
    "current_playable_index": 0,
    "entity_id": "", "entity_type": "VARIOUS",
    "playable_list": [ { "playable_id": "...", "album_id_optional": "...",
                          "playable_type": "TRACK", "from": "...",
                          "title": "...", "cover_url_optional": "...",
                          "navigation_id_optional": "...",
                          "playback_action_id_optional": "...",
                          "track_info": { "track_source_key": 0 } } ],
    "queue": { "wave_queue": {
        "live_playable_index": 11,
        "recommended_playable_list": [],
        "entity_options": { "track_sources": [ { "key": 0,
            "phonoteka_source": { "album_id": {"id": "3308124"},
                                   "entity_context": "..." } } ] }
    } },
    "options": {"repeat_mode": "NONE"}, "version": {...}, "from_optional": ""
  }
  ```

  `queue.wave_queue` несёт состояние волны/рекомендаций (индекс живого
  плейбэка, предзагруженный список рекомендаций, источники треков) —
  отдельно от видимого пользователю `playable_list`.
- **Зачем:** `Ynison.pm::build_change_track_request` (строки 1015–1056,
  вызывается из `build_next_cmd`/`build_prev_cmd`, которые дергаются из
  `Plugin.pm:618-621` на LMS-событие `jump`) собирает новый `player_queue`
  **вручную**, перечисляя только шесть полей: `current_playable_index`,
  `playable_list`, `options`, `entity_id`, `entity_type`, `entity_context`,
  `from_optional`, `version`. Ключ `queue` в список не входит — значит, при
  переходе следующий/предыдущий трек **с локального пульта LMS** (не по
  cast с телефона) вложенный объект `wave_queue` в исходящем сообщении
  отсутствует. Поскольку клиент авторизует `player_queue` целиком (это не
  вложенное JSON-слияние, а один message field), сервер получает
  `player_queue` без `queue.wave_queue` и, скорее всего, теряет состояние
  «живой» волны — рекомендации могут перестать подгружаться в приложении
  ЯМ после ручного skip на LMS.

  Для сравнения: `_build_player_state` (используется в `update_state`, т.е.
  при обычном воспроизведении/паузе) копирует кэш целиком
  (`{%{$self->{yandex_queue}}}`, строка 247) и поэтому **сохраняет**
  `queue.wave_queue` — баг специфичен именно для ветки next/prev.
- **Где:** `Ynison.pm::build_change_track_request` (~1015–1056).
- **Как:** не собирать `player_queue` вручную, а клонировать
  `$current_state->{player_queue}` целиком и точечно поменять только
  изменяемые поля:

  ```perl
  sub build_change_track_request {
      my ($self, $current_state, $delta) = @_;

      my $queue  = $current_state->{player_queue} // {};
      my $status = $current_state->{status} // {};
      my $total  = scalar(@{$queue->{playable_list} // []});
      my $new_idx = $total > 0 ? ($queue->{current_playable_index} // 0) + $delta : -1;
      $new_idx = 0 if $new_idx < 0 && $total > 0;
      $new_idx = $total - 1 if $new_idx >= $total && $total > 0;

      my %new_queue = %$queue;              # клон вместо ручного списка полей —
      $new_queue{current_playable_index} = $new_idx;  # сохраняет queue.wave_queue
      $new_queue{version} = $self->_new_version();

      return {
          rid                         => _generate_request_id(),
          player_action_timestamp_ms  => "" . _get_timestamp(),
          activity_interception_type  => 'DO_NOT_INTERCEPT_BY_DEFAULT',
          update_player_state => {
              player_state => {
                  player_queue => \%new_queue,
                  status => {
                      progress_ms    => "0",
                      duration_ms    => "0",
                      paused         => $status->{paused} // \1,
                      playback_speed => $status->{playback_speed} // 1.0,
                      version        => $self->_new_version(),
                  },
              },
          },
      };
  }
  ```

- **Приёмка:** запустить волну/альбом с телефона, сделать «next» с
  локального пульта LMS несколько раз подряд — в debug-логе исходящий JSON
  `update_player_state.player_state.player_queue` содержит ключ `queue`;
  приложение ЯМ продолжает показывать корректные рекомендации/продолжение
  волны после ручных skip.
- **Оценка:** 1–2 ч (простой рефакторинг + сверка с захваченным трафиком).
- **Примечание для задачи 2.2:** при реализации пополнения радио-очереди
  использовать ту же тактику (клонировать существующий `player_queue`,
  подменять только `playable_list`/`current_playable_index`), а не собирать
  объект с нуля — иначе получите тот же класс бага.

#### Задача 1.6. Исходящие фреймы > 64 КБ

- **Что:** поддержать 64-битную длину в `_encode_ws_text_frame`
  (сейчас при `len > 65535` функция возвращает `undef`, и `send_command`
  **молча** ничего не отправляет).
- **Зачем:** `update_player_state` с очередью в сотни треков (большой
  плейлист, пополненное радио) легко превышает 64 КБ JSON — команда
  просто теряется без единой строки в логе.
- **Где:** `Ynison.pm::_encode_ws_text_frame` (~строка 868).
- **Как:**

  ```perl
  else {
      # 64-bit length: 4 старших байта нулевые (наши фреймы < 4 ГБ)
      $header = pack('CCNN', 0x81, 0x80 | 127, 0, $len);
  }
  ```

  Плюс во входящем `_extract_ws_frame` для len==127 уже читаются только
  младшие 4 байта — это допустимо, но добавьте комментарий. И добавить
  склейку фрагментированных фреймов: сейчас кадр с FIN=0 и
  continuation-кадры (opcode 0) выбрасываются — при больших состояниях от
  сервера это потеря данных. Минимально: накапливать payload при opcode
  1/0 с FIN=0 в буфере `$self->{fragment_buffer}` и отдавать по FIN=1.
- **Приёмка:** cast плейлиста на 300+ треков и последующий `update_state`
  доходят до сервера (видно по эху); юнит-тест на encode/extract
  round-trip для фреймов 100 КБ.
- **Оценка:** 3–4 ч с тестами.

### Фаза 2. Функциональный паритет с MA

#### Задача 2.1. Периодический прогресс-heartbeat

- **Что:** пока LMS — активное устройство и играет Yandex-контент, каждые
  5 с отправлять лёгкое сообщение `update_playing_status` (не полный
  `update_player_state`).
- **Зачем:** (а) прогресс-бар в приложении ЯМ сейчас замирает между
  событиями pause/play/newsong; (б) сервер, долго не видя активности,
  может ребалансировать активное устройство на другое. MA шлёт прогресс
  каждые 5 с (`_PROGRESS_SYNC_INTERVAL`).
- **Где:** `Ynison.pm` — новый таймер по образцу `_schedule_keepalive`;
  запуск из `_handle_state_service_upgrade`, остановка в `disconnect`.
- **Как:**

  ```perl
  use constant PROGRESS_INTERVAL => 5;

  sub _schedule_progress {
      my ($self) = @_;
      Slim::Utils::Timers::setTimer($self, \&_send_progress_tick,
          PROGRESS_INTERVAL(), 'progress');
  }

  sub _send_progress_tick {
      my ($self) = @_;
      return unless $self->{state} == STATE_ACTIVE();
      my $client = $self->{client};
      if (!$self->{syncing_from_yandex} && $client->isPlaying()
          && ($client->playingSong() && $client->playingSong()->track()
              && $client->playingSong()->track()->url() =~ /^yandexmusic:/)) {
          my $song   = $client->playingSong();
          my $dur_ms = int(($song->duration() || 0) * 1000);
          my $pos_ms = int((Slim::Player::Source::songTime($client) || 0) * 1000);
          $pos_ms = $dur_ms if $dur_ms > 0 && $pos_ms > $dur_ms;
          $self->send_command({
              rid                        => _generate_request_id(),
              player_action_timestamp_ms => "" . _get_timestamp(),
              activity_interception_type => 'DO_NOT_INTERCEPT_BY_DEFAULT',
              update_playing_status => {
                  playing_status => {
                      progress_ms    => "$pos_ms",
                      duration_ms    => "$dur_ms",
                      paused         => $client->isPaused() ? \1 : \0,
                      playback_speed => 1.0,
                      version        => $self->_new_version(),
                  },
              },
          }) if $dur_ms > 0;
      }
      $self->_schedule_progress();
  }
  ```

  Не забыть `killTimers($self, 'progress')` в `disconnect`.
  Важно: heartbeat порождает эхо от сервера — задача 1.3 (двойной
  authorship-чек) должна быть сделана **до** этой, иначе получите шторм.
- **Приёмка:** во время воспроизведения на LMS прогресс-бар в мобильном
  приложении ЯМ двигается плавно; при простое > 30 мин устройство не
  «отваливается» из списка.
- **Оценка:** 3–4 ч.

#### Задача 2.2. Пополнение радио-очереди (entity_type = RADIO)

- **Что:** когда с телефона на LMS скастована волна/радио
  (`player_queue.entity_type` = `RADIO`/волновые типы) и LMS доигрывает
  предпоследний/последний трек `playable_list`, активное устройство (мы)
  обязано само дозапросить треки через rotor-API, дополнить
  `playable_list` и отправить `update_player_state` с новой версией очереди.
- **Зачем:** Ynison — протокол синхронизации состояния, сервер сам треки
  не генерирует. Сейчас скастованная волна на LMS обрывается после
  последнего трека из начальной пачки (~5 треков). Эталон: MA
  `_signal_track_completion` / `_replenish_radio_queue` / `_maybe_prefetch`
  (`provider.py:1799-2036`).
- **Где:** `Plugin.pm` — обработчик `newsong` (место, где уже вызывается
  `$ynison->update_state()`), rotor-API уже есть:
  `API/Async.pm::rotor_session_tracks` (строка 629), `rotor_session_new`
  (560).
- **Как (алгоритм, по шагам):**
  1. При `newsong`, если играет Ynison-очередь с `entity_type` RADIO и
     `current_index >= scalar(@playable_list) - 2` — запустить префетч.
  2. Префетч: `rotor_session_tracks($entity_id, $last_track_id, ...)`;
     `$last_track_id` = `playable_id` последнего элемента списка.
  3. Из ответа собрать элементы формата Ynison. Реальный трафик
     (`test/ynison_events.jsonl`) показывает, что элемент `playable_list`
     несёт больше полей, чем в MVP-реализации MA — `navigation_id_optional`
     и `playback_action_id_optional` (уникальные для конкретного
     воспроизведения, приходят от Яндекса при первичном cast) и
     `track_info: {track_source_key: 0}` (индекс в
     `queue.wave_queue.entity_options.track_sources`, где для волн лежит
     реальный источник трека — например, `phonoteka_source.album_id`).
     Для треков, которые добавляем **мы** (дозапрошенные через rotor-API,
     а не полученные от Яндекса), эти три поля отсутствовали в исходном
     ответе сервиса — не изобретать их значения, а не включать в объект:

     ```perl
     push @new_items, {
         playable_id        => "" . $t->{id},
         album_id_optional  => $t->{albums}[0]{id} ? "" . $t->{albums}[0]{id} : "",
         playable_type      => 'TRACK',
         from               => $from_field,   # взять из первого имеющегося элемента
         title              => $t->{title} // '',
         cover_url_optional => $t->{coverUri} // '',
         # navigation_id_optional / playback_action_id_optional / track_info
         # намеренно не устанавливаются: это поля, которые генерирует и
         # интерпретирует сам Яндекс для треков, изначально пришедших с
         # телефона — подделывать их не нужно, что подтверждено дефолтным
         # клиентским поведением: они помечены `_optional`.
     };
     ```

  4. **Не собирать `player_queue` с нуля** — та же ошибка, что и в
     Задаче 1.5 (`build_change_track_request`), здесь тем более критична:
     `queue.wave_queue` (индекс живого воспроизведения, предзагруженный
     `recommended_playable_list`, `entity_options.track_sources`) должен
     дойти до сервера нетронутым, иначе Яндекс не сможет продолжать
     персонализацию волны после пополнения с LMS-стороны. Клонировать
     существующий `$ynison->{yandex_queue}` целиком
     (`my %new_queue = %{$ynison->{yandex_queue}}`), заменить только
     `playable_list` на расширенный список, обновить `version`.
  5. Дополнить кэш `$ynison->{yandex_queue}{playable_list}`, добавить те же
     треки в очередь LMS (`playlist add yandexmusic://<id>` с флагом
     `syncing_from_yandex`, чтобы не отразить это обратно как cast) и
     отправить `update_player_state` с расширенным `player_queue` (шаг 4).
  6. Дедупликация: не запускать второй префетч, пока первый в полёте
     (флаг `$ynison->{prefetch_inflight}`).
- **Приёмка:** волна, запущенная с телефона на LMS-плеер, играет дольше
  начальной пачки; в приложении ЯМ список «далее» пополняется, кнопка
  «следующий» активна.
- **Оценка:** 1–2 дня (самая объёмная задача; требует живого тестирования).

#### Задача 2.3. Входящий seek (перемотка с телефона)

- **Что:** в `_apply_yandex_state`, в ветке «тот же трек, та же очередь»,
  сравнивать `status.progress_ms` с локальной позицией и при дрейфе
  больше порога перематывать LMS-плеер.
- **Зачем:** сейчас перемотка в приложении ЯМ игнорируется LMS-плеером.
- **Где:** `Plugin.pm::_apply_yandex_state`, ветка
  `if ($same_queue && $remote_track eq $lms_track)`.
- **Как:**

  ```perl
  use constant SEEK_DRIFT_THRESHOLD => 5;   # секунд
  use constant SEEK_GRACE_PERIOD    => 3;   # секунд после наших действий

  my $remote_pos = int(($status->{progress_ms} // 0) / 1000);
  my $local_pos  = int(Slim::Player::Source::songTime($client) || 0);
  my $now        = Time::HiRes::time();
  if ($now >= ($ynison->{seek_grace_until} // 0)
      && abs($remote_pos - $local_pos) > SEEK_DRIFT_THRESHOLD()) {
      $log->info("YANDEX: Seek from app: $local_pos -> $remote_pos s");
      $ynison->{seek_grace_until} = $now + SEEK_GRACE_PERIOD();
      $client->execute(['time', $remote_pos]);
  }
  ```

  Grace-период обязателен: после смены трека и собственных отправок эхо
  сервера может нести устаревший `progress_ms`, который выглядит как
  «перемотка» (MA: `_ECHO_GRACE_PERIOD`, `_classify_drift`).
  Устанавливать `seek_grace_until` также при cast/next/prev.
- **Приёмка:** перемотка ползунком в приложении ЯМ перематывает LMS в
  пределах ~1–2 с; обычное воспроизведение не дёргается (нет ложных
  перемоток на границах треков).
- **Оценка:** 0.5–1 день (большая часть — подбор порога и тесты).

#### Задача 2.4. Исходящий seek (перемотка на LMS)

- **Что:** ловить событие `time` LMS-плеера и отправлять
  `update_playing_status` с новой позицией (+ ставить `seek_grace_until`).
- **Где:** `Plugin.pm::playerEventCallback` — добавить `'time'` в фильтр
  подписки (строка ~121) и ветку обработки рядом с `pause`/`play`.
- **Как:** переиспользовать построитель из задачи 2.1 (выделить
  `_send_playing_status($progress_ms, $duration_ms, $paused)` в `Ynison.pm`).
- **Приёмка:** перемотка в веб-интерфейсе LMS сразу видна в приложении ЯМ.
- **Оценка:** 2–3 ч.

#### Задача 2.5. Остановка при перехвате другим устройством

- **Что:** если ранее активным устройством были мы, а в новом состоянии
  `active_device_id_optional` указывает на другое устройство — поставить
  LMS-плеер на паузу (если он играет Ynison-контент).
- **Зачем:** сейчас `return unless $active_device_id eq $ynison->device_id;`
  (Plugin.pm:332) молча игнорирует смену активного устройства: пользователь
  нажимает «играть на телефоне», а LMS продолжает играть параллельно.
  MA: ветка `elif self._in_use_by_queue: _clear_active_player()`.
- **Где:** `Plugin.pm::_handle_yandex_state_update` перед строкой 332.
- **Как:**

  ```perl
  my $was_active = $ynison->{we_are_active} // 0;
  my $is_active  = ($active_device_id eq $ynison->device_id) ? 1 : 0;
  $ynison->{we_are_active} = $is_active;

  if ($was_active && !$is_active) {
      my $song = $client->playingSong();
      if ($song && $song->track() && $song->track()->url() =~ /^yandexmusic:/
          && $client->isPlaying()) {
          $log->info('YANDEX: Playback taken over by another device — pausing LMS');
          $ynison->{syncing_from_yandex} = 1;
          $client->execute(['pause', 1]);
          $ynison->{syncing_from_yandex} = 0;
      }
  }
  return unless $is_active;
  ```

- **Приёмка:** «продолжить на телефоне» из приложения ЯМ ставит LMS на
  паузу в течение пары секунд.
- **Оценка:** 2–3 ч.

#### Задача 2.6. `update_session_params` после регистрации

- **Что:** сразу после `_send_register_device` отправлять:

  ```perl
  $self->send_command({
      rid => _generate_request_id(),
      update_session_params => { mute_events_if_passive => \1 },
  });
  ```

- **Зачем:** сервер перестаёт транслировать нам события чужих устройств,
  пока мы пассивны: меньше трафика, меньше ложных срабатываний
  echo-фильтра. Ошибку игнорировать (best-effort), как в MA
  (`_connect_state`, `ynison_client.py:600-605`).

  ⚠️ Учесть взаимодействие с задачей 2.5: в muted-режиме уведомление о
  смене активного устройства всё равно приходит (это изменение
  session-состояния, а не событие плеера) — проверить на практике; если
  нет, не включать `mute_events_if_passive` либо включать только когда нет
  локального воспроизведения.
- **Оценка:** 1 ч + проверка.

#### Задача 2.7. Надёжность реконнекта: jitter, бесконечные повторы, settle window

- **Что:** три изменения в `Ynison.pm`:
  1. К задержке реконнекта добавлять джиттер ±20 %:
     `$delay = $delay * (0.8 + rand(0.4));`
  2. Для auth-ошибок не останавливаться навсегда после 3 попыток —
     вместо этого перечитывать токен из настроек
     (`$prefs->get('accounts')`) перед каждой новой попыткой и повторять с
     увеличенным интервалом (например, каждые 5 мин). Пользователь, обновивший
     токен в настройках, не должен перезапускать сервер.
  3. После успешного реконнекта первые 2 с игнорировать входящие
     состояния (`$self->{settle_until} = time() + 2` в
     `_handle_state_service_upgrade`; проверка в `_on_message_received`) —
     первый стейт после реконнекта может быть ретрансляцией нашего же
     устаревшего состояния и вызвать ложный pause/cast.
- **Зачем:** это три боевых урока MA (`RECONNECT_DELAYS` + jitter,
  `on_auth_failure`, `_post_reconnect_settle_until`).
- **Оценка:** 0.5–1 день.

### Фаза 3. Гигиена и сопровождение

1. **Удалить `Ynison_old.pm`** — не подключается нигде, 945 строк шума.
2. **Добавить `test/token.txt` в `.gitignore`** (файл уже не в git, но
   защиты от случайного добавления нет); рассмотреть перенос всех
   исследовательских скриптов из `test/` в `tools/exploratory/`, а отчёты
   (`*_REPORT*`, `*.jsonl`, `debug-*.json`) — удалить или в `docs/research/`.
3. **Юнит-тесты для чистых функций Ynison** (Test::More + prove):
   `_encode_ws_text_frame`/`_extract_ws_frame` (round-trip, 3 размера,
   фрагментация), `build_pause_request`/`build_change_track_request`
   (типы полей — строки; клампинг), echo-классификация. Это чистые функции
   без сокетов — тестируются тривиально и защитят задачи фазы 1 от
   регрессий.
4. **Исправить `jump` → всегда next** (`Plugin.pm:618-621`): событие `jump`
   в LMS возникает и при переходе назад; сравнивать новый индекс плейлиста
   со старым и выбирать `build_next_cmd`/`build_prev_cmd`. Впрочем, после
   задачи 2.1 (heartbeat шлёт полный статус) и `update_state` по `newsong`
   этот код можно упростить: локальные переходы уже отражаются через
   `update_player_state` с корректным индексом.
5. **Исходящая синхронизация громкости** (опционально): подписка на
   `mixer volume` уже есть в фильтре событий — добавить отправку
   `update_volume`-сообщения (протокол поддерживает `volume_info`;
   формат подсмотреть в go-yaynison / ynison-стенде `test/ynison_observer.pl`).
   Ни один из двух проектов этого пока не делает — LMS может стать первым.

### Рекомендуемый порядок работ

```
1.1 → 1.2 → 1.3 → 1.4 → 1.5 → 1.6   (фундамент: корректность протокола, ~2.5-3.5 дня)
2.1 → 2.5 → 2.6 → 2.7          (стабильность сессии, ~2 дня)
2.3 → 2.4                      (seek, ~1-1.5 дня)
2.2                            (радио-пополнение, ~1-2 дня)
3.x                            (параллельно/фоном)
```

Зависимости: 2.1 требует 1.1–1.3 (иначе эхо-шторм); 2.2 требует 1.5
(сохранение `wave_queue`, иначе пополненная очередь всё равно потеряет
состояние волны при следующем ручном skip), 1.6 (большие фреймы) и 2.1
(общий построитель статуса); 2.3 требует 1.3
(echo-фильтр) и вводит grace-механику, которую переиспользует 2.4.

---

## 4. Справочник по протоколу Ynison (выжимка для разработчика)

- Транспорт: JSON поверх WebSocket (gRPC-подобный фрейминг, не protobuf).
- Подключение: `wss://ynison.music.yandex.ru/redirector.YnisonRedirectService/GetRedirectToYnison`
  → ответ `{host, redirect_ticket, session_id}` →
  `wss://{host}/ynison_state.YnisonStateService/PutYnisonState`.
- Авторизация: заголовок `Authorization: OAuth {token}`; идентификация
  устройства — JSON в `Sec-WebSocket-Protocol` (`Bearer, v2, {...}`).
- Сервер шлёт `player_queue` и `status` как **целые** объекты: при
  слиянии состояния верхнеуровневые ключи заменяются целиком, отсутствующие —
  сохраняются.
- Все timestamp/version-поля — **строки**; int ⇒ HTTP 500 + разрыв WS.
- `progress_ms > duration_ms` ⇒ ошибка 400030001 + разрыв WS.
- `version.version` — `random(int64)`, сервер перештамповывает; надёжный
  признак авторства — только `version.device_id`.
- Радио-очереди пополняет **активное устройство** через rotor REST-API;
  сервер Ynison только синхронизирует состояние.
- Эталонные реализации: `ma-provider-yandex-ynison` (Python),
  `bulatorr/go-yaynison` (Go), локальный стенд `test/ynison_observer.pl`.
