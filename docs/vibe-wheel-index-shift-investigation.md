# Расследование: «сдвиг» выбора волны в Колесе вибраций

Статус: **фикс v0.80 — полный (delivered обновляется на КАЖДОЙ отдаче меню клиенту); 34/34 юнит-теста зелёные; ожидает деплоя и ручной проверки**.
Дата: 2026-10-23/24. Ветка: `experiment`.

## Симптом

При выборе волны из «Моего колеса вибраций» в лог уходит seed **другой** волны
(и играет она же). Первые 2–3 выбора после открытия меню работают верно, дальше —
«смещается». Периодически само «выправляется» (после переоткрытия меню).

## Улики из server.log (26-10-23, 13:57–13:58)

```
13:57:42.17xx  VIBE WHEEL: Adding wave - ... (построено колесо, 15 волн + 2 контрола = 17 items)
13:58:12.0613  VIBE WHEEL: Cache hit for seeds='activity:road-trip' (17 items)   ← уровень колеса ПЕРЕЗАГРУЖАЕТСЯ при клике
13:58:12.0618  VIBE WHEEL: Wave selected with seed='micro-genre:piano'           ← …через 0.5 мс резолвится волна
13:58:12.0845  VIBE WHEEL: Loading with initial_seeds='micro-genre:piano'        ← rebuild-on-play запущен
13:58:17.6885  VIBE WHEEL: Wheel rebuild already initiated from UI ... skipping  ← rotor_session_new занял ~5.6 c
13:58:17.9190  VIBE WHEEL: Received wheel with 14 items (rebuild завершён через 5.8 c)
13:58:17.9215  VIBE WHEEL: Wave selected with seed='micro-genre:psychedelic-pop' ← следующий клик, 25 мс после доставки
```

Ключевое: **перед каждым кликом уровень колеса перезагружается заново**
(«Cache hit ...» из нашего снапшота) — LMS разрешает индекс кликнутого пункта
не по тому списку, который показывает клиент.

## Первопричина

LMS `Slim::Control::XMLBrowser` при клике на пункт спускается по дереву меню от
корня и **заново вызывает coderef каждого промежуточного уровня** (сессии для
деревьев с coderef не кэшируются):

- `XMLBrowser.pm:438` — промежуточный уровень не `fetched` → вызов coderef;
- `XMLBrowser.pm:517-520` — промежуточный вызов получает `index=<индекс клика>,
  quantity=1`; финальное открытие меню — `quantity=запрошенное+10` (`:506-516`);
- `XMLBrowser.pm:375-386` — резолв клика: `items->[индекс - offset]` **по
  свежеполученному списку**.

Наш `handleVibeWheel` на этом промежуточном вызове возвращает **текущее**
состояние: снапшот по saved seeds, а при несовпадении seeds (после
rebuild-on-play они уже другие!) — **свежий `wheel/new`**. А Yandex на каждый
`wheel/new` возвращает волны **в новом порядке**.

Клиент (Material) при этом показывает **старый** список — тот, что ему last
delivered. Индекс из показанного списка применяется к новому порядку → клик по
«Фортепиано» резолвится в соседнюю волну.

Почему «первые 2–3 клика ок»: пока снапшот совпадает с показанным списком,
промежуточный вызов отдаёт идентичный список — индексы сходятся. После первого
же rebuild (seeds сменились) либо по истечении TTL снапшота (600 с,
`Plugin.pm get_wheel_snapshot`) начинается дрейф.

## Дизайн фикса

Промежуточную резолюцию (`args->{quantity} == 1`) отличать от настоящего
открытия меню и отдавать ей **ровно тот список, который клиент видел последним**:

1. **Plugin.pm**: отдельное хранилище `%wheel_delivered_snapshots` (per player) —
   «последний ДОСТАВЛЕННЫЙ клиенту список уровня колеса», TTL 3600 с (равен TTL
   browse-сессии XMLBrowser `CACHE_TIME`). Функции
   `get_/set_delivered_wheel_snapshot`; очистка в `shutdownPlugin`.
2. **Browse/Radio.pm `handleVibeWheel`**:
   - в начале: если `$args->{quantity} == 1` (intermediate) — отдать delivered
     снапшот и выйти; иначе обычная логика;
   - после построения `$menu_result`: помечать delivered **только** при
     настоящем открытии меню (`!defined $initial_seeds && !$trigger_now_playing`).
3. **Browse/Radio.pm `handleVibeWaveSelect`**: при intermediate (`quantity==1`)
   — НЕ запускать воспроизведение/feedback/pending (это просто материалзация
   child-уровня для резолва), отдать текущий снапшот колеса.

Rebuild'ы (UI и фоновый в `ProtocolHandler::explodePlaylist`) пишут только
`current`-снапшот → delivered не трогают → резолв по родительскому списку
остаётся верным; новое колесо клиент увидит при следующем **открытии** меню
(финальный вызов) — поведение «колесо следует за волной» сохраняется.

## Статус реализации

- [x] `Plugin.pm`: `%wheel_delivered_snapshots`, get/set/**clear**, очистка при shutdown.
- [x] `Radio.pm`: intermediate-ветка в `handleVibeWheel`, guard в `handleVibeWaveSelect`.
- [x] **v0.80 — закрыта дыра v0.79**: delivered обновлялся только при «чистом»
      открытии меню (API-путь), из-за чего после rebuild-on-play клиент видел
      перестроенный список, а эталон оставался старым → сдвиг возвращался на
      сценарии «выбрал волну → назад → выбрал другую» (те же «первые 2–3 клика
      ок»). Теперь delivered обновляется на КАЖДОЙ отдаче меню клиенту:
      cache-hit открытие, reshuffle, rebuild-on-play select. Промежуточные
      резолюции (qty=1) по-прежнему только читают delivered и не пишут его.
- [x] Диагностическое логирование на INFO (видно без debug):
      `Intermediate index resolution (qty=1) - serving last delivered menu (N items)`
      / `- no delivered snapshot, falling through`;
      `Intermediate descent through wave '...' - serving current wheel without playback`.
- [x] **Урок деплоя (инцидент 23.10 вечера)**: файлы 0.79 были установлены,
      но LMS не перезагружен — Perl-модули грузятся один раз при старте, в
      логе при этом видны СТАРЫЕ номера строк (158/316 вместо 178/354) — по
      ним однозначно определяется, какой код исполняется. После рестарта LMS
      фикс v0.79 работал. Проверка перед тестом: (а) версия в настройках
      плагина; (б) номера строк в логе соответствуют актуальному файлу.
- [x] Версия: 0.789 → 0.79 → **0.80**.
- [x] `test/test_wheel_snapshot.pl`: 34/34 зелёные (11 тестов v0.79 + тест 30
      флипнут: rebuild-on-play ДОЛЖЕН обновлять delivered; +cache-hit маркирует
      delivered; +reshuffle маркирует delivered; +clear_delivered). Запуск:

```sh
A=/usr/share/squeezeboxserver/CPAN/arch
PERL5LIB="$A/5.38/x86_64-linux-thread-multi:$A/5.38/x86_64-linux-thread-multi/auto:$A/x86_64-linux-thread-multi:$A/5.38:/usr/share/squeezeboxserver/lib:/usr/share/squeezeboxserver/CPAN" \
  perl test/test_wheel_snapshot.pl
```

- [ ] Ручная проверка v0.80 (обязательно ПЕРЕЗАГРУЗИТЬ LMS после деплоя):
      сценарий «выбрать волну → назад → выбрать другую → назад → …» 4–5 раз —
      seed в `Wave selected with seed='...'` совпадает с кликнутой волной
      каждый раз; в логе на каждый клик видна строка
      `Intermediate index resolution (qty=1) - serving last delivered menu`.

## Остаточные ограничения (осознанные, не чиним)

- Клиент, простоявший на открытом меню > 1 ч (истекают и delivered-снапшот, и
  сессия XMLBrowser) — до переоткрытия уровня возможен разовый сдвиг.
- Два клиента (например, Material и web) на одном плеере с разными открытыми
  списками — delivered один на плеер.
- Cross-session спуск через child-уровень конкретной волны отдаёт current-снапшот
  (список последнего rebuild) — best effort, в сессии не встречается.

## Ссылки на код

- `Browse/Radio.pm`: `handleVibeWheel` (снапшот, построение списка, controls),
  `handleVibeWaveSelect` (клик: playback + rebuild-on-play).
- `Plugin.pm:1044+`: `get_/set_/clear_wheel_snapshot`, `get_/set_wheel_state`,
  `add_/take_wheel_feedbacks`.
- `ProtocolHandler.pm:754+` `explodePlaylist`: pending-seed guard (10 c),
  фоновый rebuild (`set_wheel_state` + `clear_wheel_snapshot`).
- LMS: `/usr/share/perl5/Slim/Control/XMLBrowser.pm:375-386, 438-543, 1506-1583`.
