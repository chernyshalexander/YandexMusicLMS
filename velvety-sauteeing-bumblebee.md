# Wave Wizard: Configurable Categories + Epochs + Genres

## Context

Пользователь хочет:
1. Настройку `show_wave_wizard` (да/нет) в настройках плагина
2. При включённом wizard — подраздел с 6 чекбоксами категорий: занятия, характер, настроения, язык, эпохи, жанры (min 3 должно быть выбрано)
3. Добавить в wizard новые шаги: Эпохи и Жанры (оба асинхронные, грузятся из `rotor_stations_list`)
4. Wizard показывает только включённые шаги (порядок фиксированный: activity → epoch → genre → diversity → mood → language)
5. Пресеты всегда видны в меню Радио, даже если wizard скрыт

## Текущее состояние

- `Browse/Radio.pm` уже содержит: `handleWaveWizard` (только activity), `handleWizardDiversity/MoodEnergy/Language`, `handleWizardLaunch/SavePreset`, `handlePresets/PresetItem/DeletePreset/ClearPresets`, `_buildWizardName`, `_buildWizardUrl`
- В `handleWaveWizard` шаги жёстко зашиты: activity → diversity → mood → language
- `Plugin.pm` уже имеет `yandex_wave_presets => []` в init
- Строк для epoch/genre wizard и настроек видимости нет

## Архитектура динамической цепочки шагов

Вместо жёстко зашитых переходов между шагами — утилиты `_getFirstWizardHandler` и `_getNextWizardHandler`:

```perl
# Фиксированный порядок всех возможных шагов:
my @WIZARD_STEP_ORDER = ('activity', 'epoch', 'genre', 'diversity', 'mood', 'language');

my %WIZARD_STEP_HANDLERS = (
    activity  => \&handleWizardActivity,
    epoch     => \&handleWizardEpoch,
    genre     => \&handleWizardGenre,
    diversity => \&handleWizardDiversity,
    mood      => \&handleWizardMoodEnergy,
    language  => \&handleWizardLanguage,
);

sub _getFirstWizardHandler {
    for my $step (@WIZARD_STEP_ORDER) {
        return $WIZARD_STEP_HANDLERS{$step} if $prefs->get("wizard_cat_$step");
    }
    return \&handleWizardLaunch;  # ни один не включён — сразу к запуску
}

sub _getNextWizardHandler {
    my ($current_step) = @_;
    my $found = 0;
    for my $step (@WIZARD_STEP_ORDER) {
        if ($found && $prefs->get("wizard_cat_$step")) {
            return $WIZARD_STEP_HANDLERS{$step};
        }
        $found = 1 if $step eq $current_step;
    }
    return \&handleWizardLaunch;
}
```

## Шаги activity / epoch / genre — общий хелпер

Activity, epoch, genre — все грузятся из `rotor_stations_list`, поэтому выносим в один helper:

```perl
sub _handleWizardStationStep {
    my ($client, $cb, $args, $yandex_client, $state, $type, $label_key, $any_str) = @_;
    
    my $next = _getNextWizardHandler($type);
    
    $yandex_client->rotor_stations_list(
        sub {
            my $stations = shift;
            my @items;
            # "Любое" — станция не меняется
            push @items, {
                name => cstring($client, $any_str),
                type => 'link',
                url  => $next,
                passthrough => [$yandex_client, { %$state, $label_key => '' }],
                image => 'plugins/yandex/html/images/radio.png',
            };
            foreach my $item (@$stations) {
                my $st = $item->{station};
                next unless $st && $st->{id} && $st->{id}->{type} eq $type;
                my $tag  = $st->{id}->{tag};
                my $name = $st->{name};
                push @items, {
                    name => $name,
                    type => 'link',
                    url  => $next,
                    passthrough => [$yandex_client, { %$state, station => "$type:$tag", $label_key => $name }],
                    image => 'plugins/yandex/html/images/radio.png',
                };
            }
            $cb->({ items => \@items, title => cstring($client, 'PLUGIN_YANDEX_WAVE_WIZARD') });
        },
        sub { $cb->([{ name => "Error: $_[0]", type => 'text' }]); }
    );
}

sub handleWizardActivity {
    my ($client, $cb, $args, $yandex_client, $state) = @_;
    _handleWizardStationStep($client, $cb, $args, $yandex_client, $state,
        'activity', 'label_activity', 'PLUGIN_YANDEX_WIZARD_ANY_ACTIVITY');
}

sub handleWizardEpoch {
    my ($client, $cb, $args, $yandex_client, $state) = @_;
    _handleWizardStationStep($client, $cb, $args, $yandex_client, $state,
        'epoch', 'label_epoch', 'PLUGIN_YANDEX_WIZARD_ANY_EPOCH');
}

sub handleWizardGenre {
    my ($client, $cb, $args, $yandex_client, $state) = @_;
    _handleWizardStationStep($client, $cb, $args, $yandex_client, $state,
        'genre', 'label_genre', 'PLUGIN_YANDEX_WIZARD_ANY_GENRE');
}
```

## Обновлённые шаги diversity / mood / language

Заменить хардкодные `url => \&handleWizardMoodEnergy` / `url => \&handleWizardLanguage` / `url => \&handleWizardLaunch` на динамические:

```perl
sub handleWizardDiversity {
    my ($client, $cb, $args, $yandex_client, $state) = @_;
    my $next = _getNextWizardHandler('diversity');
    # ... rest unchanged, but url => $next
}
# То же для handleWizardMoodEnergy и handleWizardLanguage
```

## Обновлённый handleWaveWizard

```perl
sub handleWaveWizard {
    my ($client, $cb, $args, $yandex_client) = @_;
    my $initial_state = {
        station => 'user:onyourwave',
        label_activity => '', label_epoch => '', label_genre => '',
        label_diversity => '', label_mood => '', label_language => '',
    };
    my $first = _getFirstWizardHandler();
    $first->($client, $cb, $args, $yandex_client, $initial_state);
}
```

## handleRadioCategories — условный показ wizard + всегда пресеты

```perl
my $show_wizard = $prefs->get('show_wave_wizard') // 1;

if ($show_wizard) {
    push @items, { name => ..., url => \&handleWaveWizard, image => 'settings.png', ... };
}

my $presets = $prefs->get('yandex_wave_presets') || [];
if (@$presets) {
    push @items, { name => ..., url => \&handlePresets, ... };  # всегда, независимо от $show_wizard
}
```

## Обновления _buildWizardName и handleWizardSavePreset

```perl
sub _buildWizardName {
    my ($client, $state) = @_;
    my @parts;
    push @parts, $state->{label_activity}  if $state->{label_activity};
    push @parts, $state->{label_epoch}     if $state->{label_epoch};
    push @parts, $state->{label_genre}     if $state->{label_genre};
    push @parts, $state->{label_diversity} if $state->{label_diversity};
    push @parts, $state->{label_mood}      if $state->{label_mood};
    push @parts, $state->{label_language}  if $state->{label_language};
    return @parts ? join(' + ', @parts) : cstring($client, 'PLUGIN_YANDEX_MY_WAVE');
}
```

`_buildWizardUrl` не меняется — использует `$state->{station}` + params, уже поддерживает epoch/genre.

## Новые настройки

**5 новых prefs:**
- `show_wave_wizard` (boolean, default 1)
- `wizard_station_type` (string: `'activity'|'epoch'|'genre'|''`, default `'activity'`) — выбор типа станции (взаимоисключающий)
- `wizard_cat_diversity` (boolean, default 1)
- `wizard_cat_mood` (boolean, default 1)
- `wizard_cat_language` (boolean, default 1)

Дефолты: station=activity + diversity + mood + language = 4 шага (> min 3).

## Файлы для изменения

### 1. `Plugin.pm`

В `$prefs->init({...})` добавить:
```perl
show_wave_wizard     => 1,
wizard_station_type  => 'activity',
wizard_cat_diversity => 1,
wizard_cat_mood      => 1,
wizard_cat_language  => 1,
```

### 2. `Settings.pm`

В `sub prefs { return ($prefs, qw(...)) }` добавить 5 новых ключей.

В `handler()` добавить `||= 0` для чекбоксов (3 категории) и `||= ''` для `wizard_station_type` при `saveSettings`.

### 3. `HTML/EN/plugins/yandex/settings/basic.html`

Добавить ПОСЛЕ блока `PLUGIN_YANDEX_ENABLE_YNISON`:

```html
<hr>

[% WRAPPER setting title="PLUGIN_YANDEX_SHOW_WAVE_WIZARD" desc="PLUGIN_YANDEX_SHOW_WAVE_WIZARD_DESC" %]
<div class="prefDesc">
    <input type="checkbox" name="pref_show_wave_wizard" id="pref_show_wave_wizard"
        [% IF prefs.show_wave_wizard %]checked[% END %]>
</div>
[% END %]

<div id="wave_wizard_settings" style="[% IF !prefs.show_wave_wizard %]display:none;[% END %] margin-left:20px; border-left: 3px solid #ccc; padding-left:15px; margin-bottom:10px;">

    <!-- Station type — radio group, visually grouped -->
    [% WRAPPER setting title="PLUGIN_YANDEX_WIZARD_STATION_TYPE" desc="PLUGIN_YANDEX_WIZARD_STATION_TYPE_DESC" %]
    <div class="prefDesc" style="border: 1px solid #ddd; border-radius:6px; padding:10px; background:#f9f9f9;">
        <label style="display:block; margin-bottom:6px;">
            <input type="radio" name="pref_wizard_station_type" value="activity"
                [% IF prefs.wizard_station_type == 'activity' || !prefs.wizard_station_type %]checked[% END %]>
            [% "PLUGIN_YANDEX_WIZARD_CAT_ACTIVITY" | string %]
        </label>
        <label style="display:block; margin-bottom:6px;">
            <input type="radio" name="pref_wizard_station_type" value="epoch"
                [% IF prefs.wizard_station_type == 'epoch' %]checked[% END %]>
            [% "PLUGIN_YANDEX_WIZARD_CAT_EPOCH" | string %]
        </label>
        <label style="display:block; margin-bottom:6px;">
            <input type="radio" name="pref_wizard_station_type" value="genre"
                [% IF prefs.wizard_station_type == 'genre' %]checked[% END %]>
            [% "PLUGIN_YANDEX_WIZARD_CAT_GENRE" | string %]
        </label>
        <label style="display:block;">
            <input type="radio" name="pref_wizard_station_type" value=""
                [% IF prefs.wizard_station_type == '' %]checked[% END %]>
            [% "PLUGIN_YANDEX_WIZARD_NO_STATION_STEP" | string %]
        </label>
    </div>
    [% END %]

    <!-- Independent filter categories — checkboxes, min 3 total (station + filters) -->
    <p style="color:#666; font-size:0.9em; margin-top:10px;">[% "PLUGIN_YANDEX_WIZARD_CATS_HINT" | string %]</p>

    [% WRAPPER setting title="PLUGIN_YANDEX_WIZARD_CAT_DIVERSITY" %]
    <input type="checkbox" class="wizard-cat-cb" name="pref_wizard_cat_diversity"
        [% IF prefs.wizard_cat_diversity %]checked[% END %]>
    [% END %]

    [% WRAPPER setting title="PLUGIN_YANDEX_WIZARD_CAT_MOOD" %]
    <input type="checkbox" class="wizard-cat-cb" name="pref_wizard_cat_mood"
        [% IF prefs.wizard_cat_mood %]checked[% END %]>
    [% END %]

    [% WRAPPER setting title="PLUGIN_YANDEX_WIZARD_CAT_LANGUAGE" %]
    <input type="checkbox" class="wizard-cat-cb" name="pref_wizard_cat_language"
        [% IF prefs.wizard_cat_language %]checked[% END %]>
    [% END %]
</div>

<script type="text/javascript">
(function () {
    var toggle  = document.getElementById('pref_show_wave_wizard');
    var section = document.getElementById('wave_wizard_settings');

    toggle.addEventListener('change', function () {
        section.style.display = this.checked ? 'block' : 'none';
    });

    // Min-3 validation: count station radio (always 1 if not "none") + checked filter boxes
    function countActiveSteps() {
        var radioVal = document.querySelector('input[name="pref_wizard_station_type"]:checked');
        var stationCount = (radioVal && radioVal.value !== '') ? 1 : 0;
        var filterCount  = document.querySelectorAll('.wizard-cat-cb:checked').length;
        return stationCount + filterCount;
    }

    document.querySelectorAll('.wizard-cat-cb').forEach(function (cb) {
        cb.addEventListener('change', function () {
            if (!this.checked && countActiveSteps() < 3) {
                this.checked = true;
                alert('[% "PLUGIN_YANDEX_WIZARD_CATS_MIN3" | string %]');
            }
        });
    });

    document.querySelectorAll('input[name="pref_wizard_station_type"]').forEach(function (rb) {
        rb.addEventListener('change', function () {
            if (this.value === '' && countActiveSteps() < 3) {
                // Switching to "no station step" — check that filters cover min 3
                // Since station step = 0, need 3 filters; alert if not enough
                if (document.querySelectorAll('.wizard-cat-cb:checked').length < 3) {
                    alert('[% "PLUGIN_YANDEX_WIZARD_CATS_MIN3" | string %]');
                    // Revert to 'activity'
                    document.querySelector('input[name="pref_wizard_station_type"][value="activity"]').checked = true;
                }
            }
        });
    });
})();
</script>
```

### 4. `Browse/Radio.pm`

Изменения:
- Добавить утилиты `_getFirstWizardHandler()` и `_getNextWizardHandler($step)`:
  - Порядок шагов: `station` (один из activity/epoch/genre, если `wizard_station_type` != '') → diversity → mood → language
  - `_getFirstWizardHandler`: если `wizard_station_type` != '' → соответствующий station handler, иначе первый включённый filter handler
  - `_getNextWizardHandler('diversity'|'mood'|'language')`: следующий включённый filter handler или `handleWizardLaunch`
- Добавить `_handleWizardStationStep(...)` — общий helper для activity/epoch/genre (async, фильтрует `rotor_stations_list` по `$type`)
- Переименовать текущий `handleWaveWizard` → `handleWizardActivity` (принимает `$state`, вызывает `_handleWizardStationStep(..., 'activity', ...)`)
- Добавить `handleWizardEpoch`, `handleWizardGenre` — аналогично
- Новый `handleWaveWizard` — строит `$initial_state`, вызывает `_getFirstWizardHandler()->(..., $initial_state)`
- Обновить `handleWizardDiversity/MoodEnergy/Language` — `url => _getNextWizardHandler('diversity'|'mood'|'language')` вместо хардкодных ссылок
- Обновить `handleRadioCategories` — wizard только если `show_wave_wizard=1`; пресеты всегда
- Обновить `_buildWizardName` — добавить `label_epoch`, `label_genre`

### 5. `strings.txt`

Добавить новые ключи:
```
PLUGIN_YANDEX_SHOW_WAVE_WIZARD
  EN: Show Wave Constructor
  RU: Показывать конструктор волны

PLUGIN_YANDEX_SHOW_WAVE_WIZARD_DESC
  EN: Show Wave Constructor in the Radio menu
  RU: Показывать конструктор волны в разделе Радио

PLUGIN_YANDEX_WIZARD_CATS_HINT
  EN: Select at least 3 categories for the wizard steps
  RU: Выберите не менее 3 категорий для шагов конструктора

PLUGIN_YANDEX_WIZARD_CATS_MIN3
  EN: At least 3 categories must be selected
  RU: Необходимо выбрать не менее 3 категорий

PLUGIN_YANDEX_WIZARD_CAT_ACTIVITY
  EN: Activities
  RU: Занятия

PLUGIN_YANDEX_WIZARD_CAT_DIVERSITY
  EN: Character
  RU: Характер

PLUGIN_YANDEX_WIZARD_CAT_MOOD
  EN: Moods
  RU: Настроения

PLUGIN_YANDEX_WIZARD_CAT_LANGUAGE
  EN: Language
  RU: Язык

PLUGIN_YANDEX_WIZARD_CAT_EPOCH
  EN: Epochs
  RU: Эпохи

PLUGIN_YANDEX_WIZARD_CAT_GENRE
  EN: Genres
  RU: Жанры

PLUGIN_YANDEX_WIZARD_ANY_EPOCH
  EN: Any epoch
  RU: Любая эпоха

PLUGIN_YANDEX_WIZARD_ANY_GENRE
  EN: Any genre
  RU: Любой жанр

PLUGIN_YANDEX_WIZARD_STATION_TYPE
  EN: Station type (choose one)
  RU: Тип станции (выберите один)

PLUGIN_YANDEX_WIZARD_STATION_TYPE_DESC
  EN: Selects which type of radio station the wizard will offer as the first step
  RU: Определяет, какой тип радиостанции конструктор предложит на первом шаге

PLUGIN_YANDEX_WIZARD_NO_STATION_STEP
  EN: My Wave only (skip station step)
  RU: Только Моя волна (без шага выбора станции)
```

## Нюансы реализации

1. **`%WIZARD_STEP_HANDLERS` с `\&handleWizardXxx`** — все функции уже должны быть объявлены выше или использоваться через `forward declarations`. В Perl это нормально если функции в том же файле — Perl разрешает до конца компиляции.

2. **Epoch/genre vs activity — взаимоисключение (Вариант B)** — activity, epoch, genre задают одно и то же поле `station`. Они взаимоисключающи: в настройках одновременно может быть включена только одна из трёх. Реализуется через radio-кнопки (или JS-взаимоисключение): при выборе одной из {activity, epoch, genre} остальные две снимаются. В prefs хранится отдельная строка `wizard_station_type` со значением `'activity'|'epoch'|'genre'|''` (вместо трёх отдельных bool-флагов). Визуально в настройках эти три вынесены в отдельный блок с заголовком "Тип станции" (radio-group), чётко отделённый от независимых категорий diversity/mood/language. Если `wizard_station_type = ''` — шаг выбора станции пропускается (используется `user:onyourwave`).

3. **Валидация min 3** — только клиентская (JS). Серверной валидации нет, т.к. при прямом POST с 1 категорией wizard просто будет иметь только 1 шаг (что нестандартно, но не сломает ничего). Можно добавить серверную валидацию в Settings.pm, но это опционально.

4. **`handleWizardActivity` с параметром `$state`** — текущий `handleWaveWizard` принимает `($client, $cb, $args, $yandex_client)` (без state). Новый `handleWizardActivity` принимает `($client, $cb, $args, $yandex_client, $state)`. Это важно для сигнатуры `passthrough`.

5. **Обратная совместимость пресетов** — существующие пресеты в prefs не имеют `label_epoch`/`label_genre`. При вызове `_buildWizardName` на старом пресете эти ключи будут `undef` → `if $state->{label_epoch}` выдаст false → ок.

## Верификация

1. В настройках плагина: появился чекбокс "Показывать конструктор волны"
2. При включении — появляется блок из 6 категорий; при выключении — блок скрывается (JS)
3. Снять 4-й чекбокс при 3 включённых — попытка отказана, alert
4. Выключить wizard → сохранить → в меню Радио нет "Конструктор волны", но "Мои пресеты" видны (если есть пресеты)
5. Выбрать тип станции "Эпохи" + включить только Язык → не даёт сохранить (< 3 шагов, итого 2)
6. Выбрать тип станции "Жанры" + Характер + Язык → wizard: Жанр → Характер → Язык → Запуск
7. Выбрать "Без шага станции" при 2 включённых фильтрах → alert, возврат к "Занятиям"
7. Сохранить пресет с epoch — имя включает название эпохи; URL = `yandexmusic://rotor_session/epoch:60s`
