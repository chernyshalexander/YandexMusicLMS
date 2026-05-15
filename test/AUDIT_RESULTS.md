# Аудит стиля и качества кода — Yandex плагин LMS

**Дата анализа:** 2026-05-15  
**Объект:** `/home/chernysh/Projects/yandex`  
**Критерии:** стилистические несоответствия, избыточная сложность, ненужное защитное программирование, дублирование кода

---

## Резюме

Проведён полный аудит кодовой базы плагина Yandex Music для LMS. Выявлены:
- **2 критических бага** (один может вызвать ошибку UI, один латентный)
- **12 проблем стиля/качества** (от дублирования кода до конфликтов конвенций)
- **1 очень высокий приоритет исправления** (Б2 — неверный формат ответа в `_validateTagsAndBuild`)

---

## Обнаруженные баги

### Б1 — `rotor_station_info` двойной unwrap (API/Async.pm, строки 479-486)

**Статус:** ✅ УДАЛЕН — мёртвый код с латентным багом  
**Уровень серьезности:** Средний (был потенциально критичным при использовании)

**Описание:**
Метод `rotor_station_info` был **удален** как мёртвый код:
- Не используется в LMS Yandex плагине
- Не используется в Music Assistant Server (только `rotor_stations_list` используется)
- Не вызывается ниоткуда

Кроме того, метод содержал латентный баг — использовал `_cached_get()`, который уже разворачивает поле `result`:

```perl
$self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
    my $result = shift;
    if (exists $result->{result}) {  # ❌ ОШИБКА: проверяет на уже развёрнутом результате
        $callback->($result->{result});
    } else {
        $error_callback->("Failed to get station info");
    }
}, $error_callback);
```

**Реальная структура данных:**
1. Сырой ответ API: `{ "result": [ { "station": {...}, ... } ] }`
2. `_cached_get()` извлекает `result` и кэширует: `[ { "station": {...}, ... } ]`
3. Callback получает уже МАССИВ: `[ { "station": {...}, ... } ]`
4. Проверка `exists $result->{result}` на МАССИВЕ → всегда false
5. **Результат:** всегда вызывается `$error_callback` вместо успешного callback

**Проявление для пользователя:**
При попытке открыть информацию о радиостанции (если бы метод вызывался) пользователь видел бы ошибку вместо списка треков.

**Исправление:**
```perl
sub rotor_station_info {
    my ($self, $station, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/rotor/station/' . $station . '/info';
    my $cacheKey = 'yandex_station_info_' . $station;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        if ($result) {  # ✅ Просто проверяем, что есть данные (без лишнего unwrap)
            $callback->($result);
        } else {
            $error_callback->("Failed to get station info");
        }
    }, $error_callback);
}
```

---

### Б2 — `_validateTagsAndBuild` возвращает неверный формат ответа (Collection.pm, строки 342, 372)

**Статус:** Критический (может вызвать ошибку при рендеринге UI)  
**Уровень серьезности:** Высокий

**Описание:**
Вспомогательная функция `_validateTagsAndBuild` в ошибочных случаях возвращает МАССИВ ref вместо HASH ref с полями `items` и `title`:

```perl
sub _validateTagsAndBuild {
    my ($yandex_client, $client, $cb, $category, $tags) = @_;

    if (!@$tags) {
        return $cb->([{ name => "No tags found in category $category", type => 'text' }]);  # ❌ ОШИБКА
    }
    # ... валидация ...
    if (@validated_items) {
        # ...
        $cb->({ items => \@validated_items, title => translate($client, $category) });  # ✅ ВЕРНО
    } else {
        $cb->([{ name => "No playlists available in $category", type => 'text' }]);  # ❌ ОШИБКА
    }
}
```

**Реальное проявление:**
1. Пользователь заходит в "Picks" → выбирает категорию (mood/activity/era/genres)
2. Если категория пуста или ошибка в валидации: функция возвращает `[{...}]`
3. Обработчик меню LMS ожидает `{items => [...], title => '...'}`
4. **Результат:** ошибка при рендеринге меню или неправильное отображение

**Исправление:**
```perl
sub _validateTagsAndBuild {
    my ($yandex_client, $client, $cb, $category, $tags) = @_;

    if (!@$tags) {
        return $cb->({ 
            items => [{ name => "No tags found in category $category", type => 'text' }],
            title => translate($client, $category)  # ✅ Добавить title
        });
    }
    # ... валидация ...
    if (@validated_items) {
        @validated_items = sort { $a->{name} cmp $b->{name} } @validated_items;
        $cb->({ items => \@validated_items, title => translate($client, $category) });
    } else {
        $cb->({
            items => [{ name => "No playlists available in $category", type => 'text' }],
            title => translate($client, $category)  # ✅ Добавить title
        });
    }
}
```

---

## Стилистические несоответствия

### С1 — Бессмысленный цикл `users_likes_artists` (API/Async.pm, строки 323-329)

Метод копирует массив в массив через цикл без трансформации:

```perl
sub users_likes_artists {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $self->get_me->{uid} . '/likes/artists';
    my $cacheKey = 'yandex_likes_artists_' . $self->get_me->{uid};

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        my @artists;
        foreach my $item (@$result) {
            push @artists, $item;  # ❌ Просто копирует элемент в элемент
        }
        $callback->(\@artists);
    }, $error_callback);
}
```

**Исправление:**
```perl
sub users_likes_artists {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $self->get_me->{uid} . '/likes/artists';
    my $cacheKey = 'yandex_likes_artists_' . $self->get_me->{uid};

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        $callback->($result);  # ✅ Передать результат напрямую
    }, $error_callback);
}
```

---

### С2 — Дублированный regex для определения подкастов (Favorites.pm, строки 65, 178, 240)

Одно и то же выражение повторяется 3 раза в разных методах:

```perl
# Строка 65 (handleFavorites)
if (($album->{type} // '') =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i))

# Строка 178 (handleLikedAlbums)
if (($album->{type} // '') =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i))

# Строка 240 (handleLikedPodcasts)
unless (($album->{type} // '') =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i))
```

**Исправление — добавить вспомогательную функцию:**
```perl
sub _is_podcast {
    my ($album) = @_;
    return ($album->{type} // '') =~ /podcast|audiobook/i 
           || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i);
}

# Использование:
if (_is_podcast($album)) { ... }
unless (_is_podcast($album)) { ... }
```

---

### С3 — Дублирование ~100 строк в `handleWaveModes` (Radio.pm, строки 258-462)

Полный список из 12 пунктов меню скопирован verbatim в success и error callback. Единственное отличие — значение `$reshuffle_url`.

**Проблема:** при изменении меню нужно менять код в двух местах.

**Исправление — вынести построение меню:**
```perl
sub handleWaveModes {
    my ($client, $cb, $args, $yandex_client) = @_;
    
    my $base_url = 'yandexmusic://rotor_session/';
    
    $yandex_client->wheel_new(
        sub {
            my $wheel = shift;
            my $reshuffle_url = _getReshuffle($wheel, $base_url);
            my @items = _buildWaveModeItems($client, $base_url, $reshuffle_url);
            $cb->({ items => \@items, title => cstring($client, 'PLUGIN_YANDEX_MY_WAVE') });
        },
        sub {
            my $error = shift;
            $log->error("Failed to fetch Vibe Wheel for reshuffle: $error");
            my @items = _buildWaveModeItems($client, $base_url, $base_url . 'user:onyourwave?diversity=reshuffle');
            $cb->({ items => \@items, title => cstring($client, 'PLUGIN_YANDEX_MY_WAVE') });
        }
    );
}

sub _buildWaveModeItems {
    my ($client, $base_url, $reshuffle_url) = @_;
    return (
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_DEFAULT'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave',
            play => $base_url . 'user:onyourwave',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        # ... остальные пункты меню (единожды определены) ...
    );
}
```

---

### С4 — Дублирование fallback в `handlePicks` (Collection.pm, строки 281-293, 318-331)

Блок "показать 4 категории" скопирован в ветку success и ветку error:

```perl
sub handlePicks {
    my ($client, $cb, $args, $yandex_client, $category) = @_;

    $yandex_client->get_landing_tags(
        sub {
            # ... валидация ...
            if (!$category) {
                # ❌ Дублированный код #1
                my @items = map {
                    {
                        name => translate($client, $_),
                        type => 'link',
                        url  => \&handlePicks,
                        passthrough => [$yandex_client, $_],
                        image => 'plugins/yandex/html/images/personal_svg.png',
                    }
                } qw(mood activity era genres);
                return $cb->({ items => \@items, title => translate($client, 'picks') });
            }
            # ... категория выбрана ...
        },
        sub {
            my $error = shift;
            # ❌ Дублированный код #2 (идентичный блок)
            my @items = map {
                {
                    name => translate($client, $_),
                    type => 'link',
                    url  => \&handlePicks,
                    passthrough => [$yandex_client, $_],
                    image => 'plugins/yandex/html/images/personal_svg.png',
                }
            } qw(mood activity era genres);
            $cb->({ items => \@items, title => translate($client, 'picks') });
        }
    );
}
```

**Исправление:**
```perl
sub handlePicks {
    my ($client, $cb, $args, $yandex_client, $category) = @_;

    my @default_items = map {
        {
            name => translate($client, $_),
            type => 'link',
            url  => \&handlePicks,
            passthrough => [$yandex_client, $_],
            image => 'plugins/yandex/html/images/personal_svg.png',
        }
    } qw(mood activity era genres);

    if (!$category) {
        return $cb->({ items => \@default_items, title => translate($client, 'picks') });
    }

    $yandex_client->get_landing_tags(
        sub {
            # ... валидация ...
        },
        sub {
            my $error = shift;
            $cb->({ items => \@default_items, title => translate($client, 'picks') });
        }
    );
}
```

---

### С5 — Боilerplate в поисковых обработчиках (Search.pm)

Блок из 5 строк повторяется 7 раз во всех search-функциях:

```perl
if (ref $yandex_client eq 'HASH') {
    $extra_args = $yandex_client if !defined $extra_args;
    $yandex_client = undef;
}
$yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);
```

Встречается в: `handleSearch`, `handleSearchTracks`, `handleSearchAlbums`, `handleSearchArtists`, `handleSearchPlaylists`, `handleSearchPodcasts`, `handleRecentSearches`

**Исправление — добавить вспомогательную функцию:**
```perl
sub _getClientAndArgs {
    my ($yandex_client, $extra_args) = @_;
    
    if (ref $yandex_client eq 'HASH') {
        $extra_args = $yandex_client if !defined $extra_args;
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient(Slim::Player::Client::currentPlayer());
    
    return ($yandex_client, $extra_args);
}

# Использование:
sub handleSearch {
    my ($client, $cb, $args, $yandex_client, $extra_args) = @_;
    ($yandex_client, $extra_args) = _getClientAndArgs($yandex_client, $extra_args);
    # ...
}
```

---

### С6 — Конфликт passthrough-конвенций для `_handleAlbum` (Search.pm vs Favorites.pm)

**Search.pm (handleSearchAlbums):**
```perl
passthrough => [{ id => $album->{id} }]
```

**Favorites.pm (handleLikedAlbums):**
```perl
passthrough => [$yandex_client, $album->{id}]
```

Browse.pm вынужден поддерживать обе конвенции. Это не только код-смелл, но и источник потенциальных ошибок.

**Исправление:** привести Search.pm к конвенции Favorites.pm (передавать $yandex_client):
```perl
passthrough => [$yandex_client, $album->{id}]  # ✅ Единая конвенция
```

---

### С7 — Дублирование логики cover URI (Browse/Common.pm)

Методы `renderTrackList` (строки 61-75) и `cache_track_metadata` (строки 129-143) содержат идентичный блок разрешения cover URI:

```perl
my $cover_uri;
if ($track_object->{coverUri}) {
    $cover_uri = $track_object->{coverUri};
} elsif ($track_object->{raw} && $track_object->{raw}->{coverUri}) {
    $cover_uri = $track_object->{raw}->{coverUri};
} elsif ($track_object->{ogImage}) {
    $cover_uri = $track_object->{ogImage};
} elsif ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && $track_object->{albums}[0]->{coverUri}) {
    $cover_uri = $track_object->{albums}[0]->{coverUri};
}

if ($cover_uri) {
    $icon = $cover_uri;
    $icon =~ s/%%/200x200/;
    $icon = "https://$icon";
}
```

**Исправление — добавить вспомогательную функцию:**
```perl
sub _resolve_cover_uri {
    my ($track_object) = @_;
    
    my $uri;
    if ($track_object->{coverUri}) {
        $uri = $track_object->{coverUri};
    } elsif ($track_object->{raw} && $track_object->{raw}->{coverUri}) {
        $uri = $track_object->{raw}->{coverUri};
    } elsif ($track_object->{ogImage}) {
        $uri = $track_object->{ogImage};
    } elsif ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}} && $track_object->{albums}[0]->{coverUri}) {
        $uri = $track_object->{albums}[0]->{coverUri};
    }
    
    return $uri ? do { (my $url = $uri) =~ s/%%/200x200/; "https://$url" } : 'plugins/yandex/html/images/foundbroadcast1_svg.png';
}

# Использование:
my $icon = _resolve_cover_uri($track_object);
```

---

## Избыточная сложность

### И1 — Двойная проверка условия в `make_aes_cipher` (API/Async.pm, строки 49-58)

```perl
sub make_aes_cipher {
    my ($key_bytes) = @_;
    my $backend = Slim::Utils::Prefs::preferences('plugin.yandex')->get('aes_backend') || 'rijndael';
    if ($backend ne 'internal' && _has_rijndael()) {
        require Crypt::Rijndael;
        return Crypt::Rijndael->new($key_bytes, Crypt::Rijndael::MODE_ECB());
    }
    if ($backend ne 'internal' && !_has_rijndael()) {  # ❌ Лишняя проверка того же условия
        $log->warn("YANDEX: aes_backend=$backend but Crypt::Rijndael not installed - using internal AES128");
    }
    require Plugins::yandex::Decode::AES128;
    return Plugins::yandex::Decode::AES128->new($key_bytes);
}
```

**Исправление:**
```perl
sub make_aes_cipher {
    my ($key_bytes) = @_;
    my $backend = Slim::Utils::Prefs::preferences('plugin.yandex')->get('aes_backend') || 'rijndael';
    
    if ($backend ne 'internal') {
        if (_has_rijndael()) {
            require Crypt::Rijndael;
            return Crypt::Rijndael->new($key_bytes, Crypt::Rijndael::MODE_ECB());
        } else {
            $log->warn("YANDEX: aes_backend=$backend but Crypt::Rijndael not installed - using internal AES128");
        }
    }
    
    require Plugins::yandex::Decode::AES128;
    return Plugins::yandex::Decode::AES128->new($key_bytes);
}
```

---

### И2 — Мёртвая ветка в redirect resolver (API/Async.pm, строки 1040-1044)

```perl
if ($http->can('headers')) {
    $location = $http->headers->header('Location');
}
elsif ($http->can('params') && $http->params && $http->params->{headers}) {  # ❌ Метода params() нет
    $location = $http->params->{headers}->{'Location'};
}
```

**Диагностика:** Класс `Slim::Networking::SimpleAsyncHTTP` не имеет метода `params()`. Это мёртвый код.

**Исправление — удалить:**
```perl
if ($http->can('headers')) {
    $location = $http->headers->header('Location');
}
```

---

## Ненужное защитное программирование

### З1 — Проверка callback в `get_track_download_info` (API/Async.pm, строки 894-897)

```perl
sub get_track_download_info {
    my ($self, $track_id, $cb) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . "/tracks/" . $track_id . "/download-info";

    unless (defined $cb && ref($cb) eq 'CODE') {  # ❌ Лишняя проверка
        $log->error("Yandex API: get_track_download_info called without a valid callback!");
        return;
    }
    # ...
}
```

**Почему это ненужно:**
1. Нигде больше в коде нет подобной проверки перед вызовом callback
2. Perl и так выдаст ошибку `Can't use an undefined value as a CODEREF` при попытке вызвать undef как функцию
3. Проверка усложняет код без явной пользы

**Исправление — удалить:**
```perl
sub get_track_download_info {
    my ($self, $track_id, $cb) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . "/tracks/" . $track_id . "/download-info";

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            $cb->($result);  # Просто вызываем без проверки
        },
        sub {
            my $error_msg = shift;
            $cb->(undef, "HTTP request failed: $error_msg");
        }
    );
}
```

---

## Матрица приоритетов исправлений

| Приоритет | Файл | Проблема | Тип | Риск |
|-----------|------|----------|-----|------|
| **КРИТИЧЕСКИЙ** | Collection.pm:342,372 | Б2 — неверный формат ответа _validateTagsAndBuild | Bug | Может сломать UI |
| **✅ ГОТОВО** | API/Async.pm | ~~Б1 — rotor_station_info~~ УДАЛЕН | Cleanup | Был латентный баг в мёртвом коде |
| **ВЫСОКИЙ** | Browse/Common.pm:61-143 | С7 — дублирование cover URI (2×) | Style | Maintainability + 15 строк кода |
| **ВЫСОКИЙ** | Favorites.pm:65,178,240 | С2 — дублированный regex (3×) | Style | Maintainability + future bugs |
| **СРЕДНИЙ** | API/Async.pm:323-329 | С1 — бессмысленный foreach | Style | Minimal, 3 строки |
| **СРЕДНИЙ** | API/Async.pm:49-58 | И1 — двойная проверка backend | Refactor | Clarity |
| **СРЕДНИЙ** | API/Async.pm:1040-1044 | И2 — мёртвая ветка params() | Cleanup | Dead code |
| **СРЕДНИЙ** | API/Async.pm:894-897 | З1 — лишняя проверка callback | Style | Simplicity |
| **НИЗКИЙ** | Radio.pm:258-462 | С3 — дублирование ~100 строк меню | Refactor | Readability, maintainability |
| **НИЗКИЙ** | Collection.pm:281-331 | С4 — дублирование fallback (2×) | Refactor | Readability, maintainability |
| **НИЗКИЙ** | Search.pm (7 функций) | С5 — боilerplate 5 строк (7×) | Refactor | Readability, maintainability |
| **НИЗКИЙ** | Search.pm + Browse.pm | С6 — конфликт passthrough альбомов | Design | Unify conventions |

---

## Выводы

1. **Критические баги** (Б1, Б2) требуют немедленного исправления
2. **Стилистические проблемы** (С2, С7) влияют на maintainability и должны быть исправлены в течение спринта
3. **Остальные исправления** можно планировать поэтапно (убывает приоритет по риску)
4. **Общий паттерн:** много дублирования кода (copy-paste), можно унифицировать через вспомогательные функции

---

## Рекомендуемый порядок исправлений

1. ✅ **Б1** — ГОТОВО: удален rotor_station_info (мёртвый код)
2. **Б2** — Collection.pm:342,372 (может сломать UI)  
3. **С7** — Browse/Common.pm (15 строк дублирования)
4. **С2** — Favorites.pm (3 дублирования regex)
5. **С1** — API/Async.pm:323-329 (3 строки)
6. **И1** — API/Async.pm:49-58 (улучшить clarity)
7. **И2** — API/Async.pm:1040-1044 (удалить мёртвый код)
8. **З1** — API/Async.pm:894-897 (удалить лишнюю проверку)
9. **С3, С4, С5, С6** — плановые рефакторинги (в следующих спринтах)
