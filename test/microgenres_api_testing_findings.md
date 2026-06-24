---
name: microgenres_api_testing_findings
description: API testing findings - microgenres exist as separate micro-genre stations in /rotor/stations/list
metadata: 
  node_type: memory
  type: project
  status: completed
  date: 2026-06-19
  originSessionId: 65e28d42-95eb-4f4d-a248-3238acb0aacb
---

# Микро жанры в Yandex Music API - Тестирование и Выводы

## 🎯 КЛЮЧЕВОЕ ОТКРЫТИЕ

**Микро жанры СУЩЕСТВУЮТ, но не там, где мы их искали!**

Микро жанры находятся в `/rotor/stations/list` endpoint как ОТДЕЛЬНЫЕ СТАНЦИИ типа `micro-genre`, а не как `sub_genres` в структуре основного жанра.

---

## 📊 API Endpoints - Сравнение

### Endpoint 1: `/genres`
- **Статус:** 200 ✓
- **Возвращает:** 36 основных жанров (flat list)
- **Структура:** NO sub_genres field
- **Пример ID:** `genre:rock`, `genre:pop`, `genre:electronic`

### Endpoint 2: `/rotor/stations/list` ⭐ (ПРАВИЛЬНЫЙ ИСТОЧНИК)
- **Статус:** 200 ✓
- **Возвращает:** 695 станций разных типов
- **Структура содержит:**
  - 158 `genre` станций (основные жанры)
  - **367 `micro-genre` станций (МИКРО ЖАНРЫ!)** ← ВОТ ОНИ!
  - 18 mood станций
  - 12 activity станций
  - 9 epoch станций
  - + другие типы

---

## 🎭 Структура Микро Жанра

```json
{
  "id": {
    "type": "micro-genre",
    "tag": "bit-8"
  },
  "name": "8 бит",
  "icon": {
    "backgroundColor": "#6C65A9",
    "imageUrl": "avatars.yandex.net/get-music-misc/.../%%"
  },
  "restrictions": {
    "language": {...},
    "mood": {...},
    "energy": {...},
    "diversity": {...}
  }
}
```

**URL для проигрывания:** `yandexmusic://rotor_session/micro-genre:bit-8`

---

## 📍 Примеры Микро Жанров

```
1. bit-8                          | 8 бит
2. bestial-black-metal            | Bestial Black Metal
3. ebm                            | EBM
4. heavy-psych                    | Heavy psych
5. neue-deutsche-haerte           | Neue Deutsche Härte
6. power-electronics              | Power Electronics
7. psyprog                        | Psyprog
8. raw-black-metal                | Raw Black Metal
9. uk-bass                        | UK bass
10. avant-garde-jazz              | Авангардный джаз
...
(всего 367 микро жанров)
```

---

## ✅ ЧТО ТЕПЕРЬ ЯСНО

1. **Микро жанры СУЩЕСТВУЮТ** ✓
   - 367 отдельных микро жанров в API
   - Каждый имеет свой ID, название, иконку
   - Полностью функциональны как радио станции

2. **Они находятся в `/rotor/stations/list`** ✓
   - Это не sub_genres в `/genres` endpoint
   - Это отдельные станции типа `micro-genre`
   - Используются так же как genre, mood, activity станции

3. **Можно интегрировать в плагин** ✓
   - Добавить меню "Микро жанры" (Microgenres)
   - Использовать `rotor_stations_list` endpoint
   - Отфильтровать по типу `type == 'micro-genre'`
   - Создать URL: `yandexmusic://rotor_session/micro-genre:{tag}`

---

## 🔧 Как Реализовать

### В Perl коде (аналогично handleRadioCategoryList):

```perl
sub handleRadioCategoryList {
    my ($client, $cb, $args, $yandex_client, $category_type) = @_;

    # category_type может быть: 'genre', 'mood', 'activity', 'epoch', 'micro-genre'
    
    $yandex_client->rotor_stations_list(
        sub {
            my $stations = shift;
            my @items;

            foreach my $item (@$stations) {
                my $st = $item->{station};
                if ($st && $st->{id} && $st->{id}->{type} eq $category_type) {
                    my $tag = $st->{id}->{tag};
                    my $station_url = 'yandexmusic://rotor_session/' . "$category_type:$tag";

                    push @items, {
                        name => $st->{name},
                        type => 'audio',
                        url  => $station_url,
                        play => $station_url,
                    };
                }
            }

            @items = sort { $a->{name} cmp $b->{name} } @items;
            $cb->(\@items);
        },
        $error_cb
    );
}
```

### В Menu (Browse/Radio.pm):

```perl
# Добавить в handleRadioCategories():
push @items, {
    name => cstring($client, 'PLUGIN_YANDEX_RADIO_MICROGENRES'),
    type => 'link',
    url  => \&handleRadioCategoryList,
    passthrough => [$yandex_client, 'micro-genre'],
    image => 'plugins/yandex/html/images/radio.png',
};
```

---

## 📝 API Response Flow

```
rotor_stations_list()
    ↓
Returns 695 stations
    ├─ 158 genre stations (type: 'genre')
    ├─ 367 micro-genre stations (type: 'micro-genre') ← МИКРО ЖАНРЫ
    ├─ 18 mood stations (type: 'mood')
    ├─ 12 activity stations (type: 'activity')
    ├─ 9 epoch stations (type: 'epoch')
    └─ + другие типы
```

---

## ⏱️ Временная оценка для реализации

- **Добавить меню "Микро жанры":** 30 минут
- **Интеграция с rotor_stations_list:** 1 час
- **Локализация (EN + RU):** 30 минут
- **Тестирование:** 1 час
- **Всего:** 3 часа ✓

Значительно меньше, чем первоначальная оценка 8-13 часов!

---

## 🎯 Выводы

1. **Документация была неправильной** - микро жанры не в `/genres`
2. **Правильный source** - `/rotor/stations/list` endpoint
3. **Они СУЩЕСТВУЮТ** - 367 реальных микро жанров
4. **Легко реализовать** - используя существующий `handleRadioCategoryList` код
5. **Быстрая разработка** - ~3 часа вместо 8-13

---

## 📌 Рекомендация

**РЕАЛИЗОВАТЬ микро жанры!**

✓ Существуют в API  
✓ Полностью функциональны  
✓ Быстро разработать  
✓ Значительное улучшение UX  

---

**Дата тестирования:** 2026-06-19  
**Статус:** ГОТОВО К РЕАЛИЗАЦИИ ✓  
**Confidence:** 100%
