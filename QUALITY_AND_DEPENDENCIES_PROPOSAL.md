# Предложения по улучшению качества аудио и проверке зависимостей

## 1. Реструктуризация настроек качества звука

### Текущая ситуация
Сейчас выбор ограничен фиксированными битрейтами и «FLAC». При выборе FLAC, если его нет, происходит откат сразу на MP3 320.

### Рекомендуемые опции (Dropdown)
Предлагаю выделить 3 основных режима для качественного звука:

1.  **FLAC (Lossless preferred)**
    *   **Логика:** `flac, flac-mp4` -> (fallback) -> `mp3 (320)`
    *   **Для кого:** Ценители чистого lossless, кому не важен трафик.
2.  **AAC (Efficient High Quality)**
    *   **Логика:** `aac-mp4, aac` -> (fallback) -> `mp3 (320)`
    *   **Для кого:** Оптимальный баланс. AAC 256/320 в Яндексе часто звучит чище, чем MP3 320, и занимает меньше места.
3.  **FLAC + AAC (Ultimate Quality)** — *Рекомендуемый режим*
    *   **Логика:** `flac, flac-mp4` -> (fallback) -> `aac-mp4, aac` -> (fallback) -> `mp3 (320)`
    *   **Для кого:** «Выжать максимум». Если есть FLAC — берем его. Если нет — берем качественный AAC. MP3 только в самом крайнем случае.

### Реализация в `API.pm`
Передавать разный список `codecs` в запрос `get-file-info`:
*   `flac`: `flac,flac-mp4,mp3`
*   `aac`: `aac-mp4,aac,mp3`
*   `flac+aac`: `flac,flac-mp4,aac-mp4,aac,mp3`

---

## 2. Проверка зависимостей (ffmpeg и Crypt::Rijndael)

Для работы `flac-mp4` и `aac-mp4` критически важны `ffmpeg` и библиотека для расшифровки.

### Предлагаемые способы уведомления

#### А. Предупреждение в настройках (UI)
Добавить в `Settings.pm` проверку и выводить блок в `basic.html`:
```html
[% IF rijndael_missing OR ffmpeg_missing %]
    <div style="background:#fee; border:1px solid #f00; padding:10px; border-radius:5px;">
        <b>Внимание: Обнаружены проблемы с зависимостями!</b>
        <ul>
            [% IF rijndael_missing %]<li>Отсутствует <b>Crypt::Rijndael</b> (нужен для FLAC)</li>[% END %]
            [% IF ffmpeg_missing %]<li>Отсутствует <b>ffmpeg</b> (нужен для AAC/MP4)</li>[% END %]
        </ul>
    </div>
[% END %]
```

#### Б. Критическая ошибка в лог (Backend)
В `initPlugin` проверять зависимости один раз при старте:
```perl
if (!Plugins::yandex::API::has_dependencies()) {
    $log->error("Yandex Music: Missing critical dependencies (ffmpeg or Crypt::Rijndael). Playback may fail.");
}
```

---

## 3. Технические детали реализации

### Публичный метод в `API.pm`
```perl
sub check_dependencies {
    return {
        rijndael => _has_rijndael(),
        ffmpeg   => defined(_find_ffmpeg()),
    };
}
```

### Преимущества такого подхода
1.  **Прозрачность:** Пользователь сразу поймет, почему «не играет FLAC», не копаясь в логах.
2.  **Гибкость:** Пользователи на слабых каналах или мобильном интернете оценят режим «AAC Only».
3.  **Качество:** Переход на AAC-fallback вместо MP3 поднимет общий уровень звучания плагина.
