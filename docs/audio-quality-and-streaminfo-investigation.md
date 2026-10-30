# Архитектурное исследование: честный статус качества (Graceful Fallback) и извлечение профиля аудиопотока (16/44.1 vs 24/96 Hi-Res) в плагине Yandex Music для LMS

**Дата исследования:** 30 октября 2026 г.  
**Статус:** Исследование завершено, алгоритмы верифицированы на реальных потоках и API, спецификация готова к передаче в разработку.  
**Целевые модули:** `API/Async.pm`, `Decode/MP4Demux.pm`, `ProtocolHandler.pm`.

---

## 1. Введение и цели задачи

В текущей версии плагина Yandex Music для Logitech Media Server (LMS) при включенной настройке максимального качества **«FLAC (Lossless)»** (`max_bitrate = 'flac'`) присутствуют два существенных архитектурных недостатка в отображении метаданных и параметров воспроизведения:

1. **Ложный статус Lossless при серверном даунгрейде (Fallback):**  
   Если у правообладателя в каталоге Яндекс Музыки отсутствует FLAC-мастер, API серверно отдает MP3 320 kbps (HQ) или 192 kbps (NQ). Однако интерфейсы LMS (Material Skin, Squeezebox Touch, Transporter, Default Web) могут до или во время воспроизведения рапортовать о типе `flc` и битрейте `~900kbps FLAC`. Это вызывает недоумение у пользователей («почему на дисплее горит FLAC, а ЦАП или уши фиксируют MP3?»).
2. **Отсутствие информации о точной разрядности и частоте дискретизации (16/44.1 vs 24/96 Hi-Res):**  
   JSON API Яндекса не возвращает аудиопрофиль (`sample_rate`, `bits_per_sample`). При этом Яндекс стримит FLAC в контейнере ISO BMFF (MP4). Внутри бокса `moov -> trak -> mdia -> minf -> stbl -> stsd -> fLaC -> dfLa` содержится блок метаданных `STREAMINFO` кодека FLAC, байты которого однозначно специфицируют частоту (до 20 бит) и битность (5 бит). Наличие внутреннего модуля `MP4Demux.pm` позволяет извлекать эти данные прямо из потока и регистрировать их в ядре LMS для вывода бейджей `96kHz / 24bit` или `44.1kHz / 16bit`.

Настоящий документ содержит исчерпывающее техническое исследование обеих подсистем, побитовую спецификацию парсинга, аудит внутреннего устройства ядра LMS и пошаговый план внедрения для Senior-разработчика.

---

## 2. Исследование модели `FileDownloadInfo` в Yandex Music API

### 2.1. Эндпоинт и протокол запроса

Для получения высококачественных потоков (включая Lossless) плагин обращается к защищенному эндпоинту `/get-file-info`:

```http
GET https://api.music.yandex.net/get-file-info?ts={ts}&trackId={track_id}&quality=lossless&codecs={codecs}&transports=encraw&sign={sign}
Headers:
  Authorization: OAuth {token}
  X-Yandex-Music-Client: YandexMusicAndroid/24023621
```

- **Алгоритм подписи `sign`:**  
  HMAC-SHA256 от строки `${ts}${track_id}lossless${codecs_without_commas}encraw` с секретным ключом `p93jhgh689SBReK6ghtw62`. Результат кодируется в Base64, берутся первые 43 символа.
- **Список запрашиваемых кодеков:**  
  `flac,flac-mp4,aac-mp4,aac,he-aac,mp3,he-aac-mp4`.

---

### 2.2. Полная схема и структура ответа `downloadInfo`

В ответе приходит JSON следующей структуры:

```json
{
  "result": {
    "downloadInfo": {
      "trackId": "47742192",
      "quality": "nq",
      "codec": "mp3",
      "bitrate": 192,
      "transport": "encraw",
      "key": "f81ef66f230b6925f571c05b7b6c0892",
      "gain": false,
      "realId": "47742192",
      "urls": [
        "https://strm-ams25.strm.yandex.net/music-v2/crypt/...",
        "https://strm-rad-25.strm.yandex.net/music-v2/crypt/..."
      ],
      "url": "https://strm-ams25.strm.yandex.net/music-v2/crypt/..."
    }
  },
  "invocationInfo": {
    "hostname": "music-resource-provider-...",
    "req-id": "1793354534330844-16194869428082692312",
    "app-name": "music-resource-provider",
    "exec-duration-millis": 11
  }
}
```

---

### 2.3. Спецификация полей модели `FileDownloadInfo`

| Поле | Тип | Возможные значения | Описание и инженерные особенности |
| :--- | :--- | :--- | :--- |
| `quality` | `string` | `'lossless'`, `'hq'`, `'nq'` | **Фактический профиль качества:**<br>• `'lossless'` — оригинальный FLAC поток (16/44.1 или 24/96).<br>• `'hq'` — High Quality (MP3 320 kbps или AAC 192/256 kbps).<br>• `'nq'` — Normal Quality (MP3 192 kbps). |
| `codec` | `string` | `'flac-mp4'`, `'flac'`, `'aac-mp4'`, `'he-aac-mp4'`, `'aac'`, `'he-aac'`, `'mp3'` | **Формат контейнера / кодека:**<br>• `'flac-mp4'` — FLAC, инкапсулированный в ISO BMFF (MP4).<br>• `'flac'` — голый FLAC (в современных ответах Яндекса практически не встречается, заменен на `flac-mp4`).<br>• `'aac-mp4'` — AAC LC в контейнере MP4.<br>• `'mp3'` — MPEG-1 Audio Layer III. |
| `bitrate` | `integer` | `0`, `320`, `192`, `128` | **Битрейт потока в kbps:**<br>• **Для `flac-mp4` и `flac` ВСЕГДА возвращается `0`**, так как FLAC является VBR-кодеком с переменным сжатием.<br>• Для MP3/AAC — номинальный битрейт в kbps (`320`, `192` и т.д.). |
| `realId` | `string`/`int` | Числовой ID, например `"47742192"` | **Канонический идентификатор трека:** базовый числовой ID мастер-записи без привязки к конкретному альбому или региону. Совпадает с идентификатором файла в хранилище MDS. |
| `gain` | `boolean` | `true`, `false` | Флаг применения серверного ReplayGain нормализации громкости непосредственно в поток на стороне Яндекса. |
| `transport` | `string` | `'encraw'`, `'raw'` | Тип доставки: `'encraw'` (потоковое шифрование AES-128-CTR) или `'raw'` (чистый поток). |
| `key` | `string` | 32 hex-символа | 128-битный ключ AES-CTR. Присутствует только при `transport=encraw`. |
| `url` / `urls` | `string`/`array` | HTTPS URL | Подписанные CDN URL на получение медиасегментов. Время жизни URL — около 1–2 часов. |

---

### 2.4. Механизм серверного Graceful Fallback в Яндекс Музыке

Когда плагин запрашивает трек с параметром `quality=lossless`:
1. **Случай A (Трек доступен в Lossless):**  
   Сервер возвращает:
   ```json
   { "codec": "flac-mp4", "quality": "lossless", "bitrate": 0, "key": "..." }
   ```
2. **Случай B (Правообладатель не предоставил FLAC):**  
   Сервер Яндекс Музыки **НЕ возвращает ошибку 404/400**. Он выполняет автоматический Graceful Fallback на лучший доступный формат и отдает:
   ```json
   { "codec": "mp3", "quality": "hq", "bitrate": 320, "key": "..." }
   ```
   (или `"quality": "nq"`, `"bitrate": 192` для старых оцифровок).
3. **Случай C (Трек недоступен в регионе / отозваны права):**  
   Сервер возвращает JSON с ошибкой бизнес-логики:
   ```json
   { "result": { "name": "track-download-info-error", "message": "not-allowed" } }
   ```
   В этом случае плагин падает в локальный фолбэк на старый эндпоинт `/tracks/{id}/download-info`.

---

## 3. Анализ текущего кода плагина (As-Is) и природа багов метаданных

### 3.1. Почему на экране отображается «FLAC», когда реально играет «MP3»

В кодовой базе выявлена цепочка потерь данных:

1. **Потеря атрибутов в `API/Async.pm` (`get_track_file_info`, строки 1039–1045):**
   ```perl
   my $di = $json->{result}{downloadInfo};
   # Передаются только 5 аргументов:
   $cb->($di->{url}, undef, $di->{codec} || 'mp3', $di->{bitrate} || 0, $di->{key});
   ```
   Поля `$di->{quality}`, `$di->{realId}`, `$di->{gain}` **полностью отбрасываются**.
2. **Отсутствие сохранения `quality` в кэш (`ProtocolHandler.pm`, строки 546–561):**
   В `_resolveStreamUrl` сохраняются только:
   ```perl
   $cached_meta->{bitrate} = $bitrate;
   $cached_meta->{codec}   = $codec;
   $cached_meta->{aes_key} = $aes_key;
   # $cached_meta->{quality} НЕ СОХРАНЯЕТСЯ!
   ```
3. **Преждевременное предположение о FLAC в `getMetadataFor` (`ProtocolHandler.pm`, строки 715–735):**
   Когда трек только добавлен в плейлист или запрашивается интерфейсом до старта воспроизведения (`!$codec`), срабатывает ветка:
   ```perl
   } elsif (!$codec && $max_bitrate eq 'flac') {
       $type = $display_type = 'flc';  # not yet resolved, but will be FLAC
   }
   ...
   if ($type =~ /flac|flc/) {
       $bitrate_str = !$bitrate ? 'FLAC' : sprintf("~%.0fkbps FLAC", ($bitrate || 900000) / 1000);
   }
   ```
   LMS кэширует этот ответ в `Slim::Schema::RemoteTrack` и внутренней хэш-таблице `Slim::Schema::contentTypeCache`. Даже когда после вызова `getNextTrack` выясняется, что сервер вернул MP3 320, интерфейс продолжает выводить `FLAC`, пока кэш не будет принудительно очищен и обновлен.

---

## 4. Контейнер MP4 и бокс `dfLa`: извлечение 16/44.1 vs 24/96 Hi-Res

### 4.1. Анатомия контейнера FLAC-in-MP4 (ISOBMFF)

Яндекс Музыка пакует FLAC в MP4 согласно черновику спецификации Xiph *«FLAC in ISO Base Media File Format»*. Иерархия боксов в заголовке файла:

```
[ftyp]  (File Type Box: isom/mp42)
[moov]  (Movie Box)
  ├── [mvhd]  (Movie Header Box)
  └── [trak]  (Track Box)
        ├── [tkhd]
        └── [mdia]  (Media Box)
              ├── [mdhd]
              ├── [hdlr]  (handler: 'soun')
              └── [minf]  (Media Information Box)
                    └── [stbl]  (Sample Table Box)
                          └── [stsd]  (Sample Description Box)
                                └── [fLaC] или [fla1]  (FLAC Sample Entry, 36 байт заголовок)
                                      └── [dfLa]  (FLACSpecificBox - FullBox)
                                            └── FLAC Metadata Blocks:
                                                  └── [STREAMINFO] (34 байта)
[mdat]  (Media Data Box: сырые FLAC-фреймы)
```

---

### 4.2. Побитовая структура бокса `dfLa` и блока `STREAMINFO`

Бокс `dfLa` является `FullBox` (размер 4 байта, тип `'dfLa'`, 1 байт версии, 3 байта флагов).  
Полезная нагрузка бокса начинается со смещения **+12 байт**.

Первым блоком в `dfLa` обязан идти блок типа `0` — **`STREAMINFO`**:
- **Заголовок блока FLAC (4 байта):**
  - Бит 7: `is_last` (1 бит — последний ли блок метаданных).
  - Биты 6..0: `block_type` (7 бит). Для `STREAMINFO` значение строго равно `0`.
  - Байты 1..3: `length` (24-битное целое). Для `STREAMINFO` длина строго равна `34` (`0x000022`).
- **Тело блока `STREAMINFO` (34 байта):**

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       min_block_size (16)     |       max_block_size (16)     |  Байты 0-3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               min_frame_size (24)             |               |  Байты 4-7
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+               |
|               max_frame_size (24)             |               |  Байты 7-9
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|              sample_rate (20)             |channels-1 | bps-1 |  Байты 10-13 ($hi)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|(bps-1)|                 total_samples (36)                    |  Байты 14-17 ($lo)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                   MD5 signature (128 bits)                    |  Байты 18-33
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 4.3. Математика распаковки на Perl

В модуле `Decode/MP4Demux.pm` метод `_extract_flac_metadata` возвращает байты `dfLa` payload.  
Смещение ключевых 8 байт (байты 10–17 тела `STREAMINFO`) относительно начала payload `dfLa`:
`4 байта (хидер блока) + 10 байт (block/frame sizes) = 14 байт`.

```perl
# Чтение 8 байт (64 бит) со смещения 14 в теле dfLa
my ($hi, $lo) = unpack('NN', substr($dfla_payload, 14, 8));

# Распаковка полей:
my $sample_rate     = ($hi >> 12) & 0xFFFFF;           # 20 бит: 44100, 48000, 96000, 192000
my $channels        = (($hi >> 9) & 0x07) + 1;         # 3 бита: 0..7 -> 1..8 каналов
my $bits_per_sample = (($hi >> 4) & 0x1F) + 1;         # 5 бит: 15->16 бит, 23->24 бит (Hi-Res!)
my $total_samples   = ($hi & 0x0F) * 4294967296 + $lo; # 36 бит: общее число сэмплов

my $duration_sec    = $sample_rate > 0 ? $total_samples / $sample_rate : 0;
```

#### Классификация профиля аудио:
- **CD Quality:** `sample_rate = 44100`, `bits_per_sample = 16`.
- **Hi-Res Audio:** `bits_per_sample = 24` и/или `sample_rate >= 48000` (обычно `96000` или `48000`).

---

## 5. Архитектура ядра LMS: критические ограничения и правильные вызовы API

> [!CAUTION]
> **Критический нюанс архитектуры LMS:**  
> В пакете `Slim::Music::Info` **НЕ СУЩЕСТВУЕТ** методов `setSampleRate` и `setBitsPerSample`.  
> Прямой вызов `Slim::Music::Info::setSampleRate(...)` немедленно завершится фатальной ошибкой Perl:  
> `Undefined subroutine &Slim::Music::Info::setSampleRate called`.

### 5.1. Как ядро LMS в действительности работает с Sample Rate и Bit Depth

В архитектуре LMS технические параметры звукового потока распределены по трем уровням:

1. **База данных SQLite (`tracks` / `Slim::Schema`):**
   В схеме таблицы `tracks` (определенной в `Slim::Schema::Track`) есть физические колонки:
   - `samplerate` (целое число, Гц, например `44100`, `96000`).
   - `samplesize` (разрядность, бит, например `16`, `24`).
   - `channels` (число каналов, `2`).
   - `bitrate` (битрейт в bps).
   - `lossless` (`1` или `0`).
   - `content_type` (`flc`, `mp3`, `aac`).

   Для удаленных треков запись обновляется через:
   ```perl
   Slim::Schema->updateOrCreate({
       url        => $track_url,
       readTags   => 0,
       commit     => 1,
       attributes => {
           SAMPLERATE => $sample_rate,
           SAMPLESIZE => $bits_per_sample,
           CHANNELS   => $channels,
           LOSSLESS   => ($codec =~ /^flac/ ? 1 : 0),
       },
   });
   ```

2. **Объект трека в памяти (`$track` — экземпляр `Slim::Schema::RemoteTrack`):**
   ```perl
   my $track = Slim::Schema->objectForUrl($track_url) || ($song && $song->currentTrack);
   if ($track) {
       $track->samplerate($sample_rate);
       $track->samplesize($bits_per_sample);
       $track->channels($channels);
   }
   ```

3. **Объект песни (`$song` — экземпляр `Slim::Player::Song`):**
   Используется плагинами для привязки контекста сессии воспроизведения:
   ```perl
   $song->pluginData(samplerate => $sample_rate);
   $song->pluginData(samplesize => $bits_per_sample);
   ```

4. **Метаданные трека в `ProtocolHandler::getMetadataFor`:**
   CLI и JSON-RPC ядро LMS (`Slim::Control::Queries`) мапит данные из хэша `getMetadataFor`:
   - Тег `T` -> `$remoteMeta->{samplerate}`.
   - Тег `I` -> `$remoteMeta->{samplesize}`.
   - Тег `c` -> `$remoteMeta->{channels}`.
   - Тег `r` -> `$remoteMeta->{bitrate}`.

---

### 5.2. Как интерфейсы (Material Skin, Squeezebox Touch) строят бейджи качества

В популярном скине **Material Skin** функция `formatTechInfo` (`utils.js:182–214`) собирает строку параметров:

```javascript
function formatTechInfo(item, source, isCurrent) {
    let technical = [];
    if (undefined!=item.bitrate && (""+item.bitrate).length>1) {
        technical.push(item.bitrate); // Например: "FLAC Lossless" или "320 kbps MP3 (Lossless недоступен)"
    }
    if (item.samplesize && parseInt(item.samplesize)>0) {
        technical.push(i18n("%1bit", item.samplesize)); // "24bit"
    }
    if (item.samplerate && parseInt(item.samplerate)>100) {
        technical.push((item.samplerate/1000)+"kHz");   // "96kHz"
    }
    if (item.type) {
        technical.push(item.type.toUpperCase());        // "FLAC"
    }
    return technical.join(', '); // Результат: "FLAC Lossless, 24bit, 96kHz, FLAC"
}
```

Аппаратные плееры (Squeezebox Touch, Radio, Transporter) выводят иконки `FLAC`, частоту `96 kHz` и разрядность `24 bit` на экран воспроизведения, опираясь на поля `samplerate` и `samplesize` из `RemoteTrack`.

---

## 6. Детальный план доработки модулей (To-Be)

### 6.1. Модуль `API/Async.pm`

#### Задача:
Пробросить поля `quality`, `realId`, `gain` из JSON-ответа `/get-file-info` в колбэк `get_track_file_info` и далее через `get_track_direct_url`.

#### Точки изменения:
1. **`get_track_file_info` (строка ~1045):**
   ```perl
   # Было:
   $cb->($di->{url}, undef, $di->{codec} || 'mp3', $di->{bitrate} || 0, $di->{key});

   # Стало:
   $cb->(
       $di->{url},
       undef,
       $di->{codec} || 'mp3',
       $di->{bitrate} || 0,
       $di->{key},
       $di->{quality} || 'hq',
       $di->{realId}  || $track_id,
       $di->{gain}    ? 1 : 0
   );
   ```

2. **`get_track_direct_url` (строки ~1088–1126):**
   Принимать расширенную сигнатуру в колбэке:
   ```perl
   $self->get_track_file_info($track_id, sub {
       my ($url, $error, $codec, $bitrate_kbps, $aes_key, $quality, $real_id, $gain) = @_;
       unless ($url) {
           $log->warn("YANDEX: get-file-info failed ($error), falling back to MP3");
           # При фолбэке качество помечаем как 'hq' или 'nq'
           $self->_get_track_mp3_url($track_id, 320, sub {
               my ($mp3_url, $mp3_err, $mp3_br, $mp3_codec) = @_;
               $cb->($mp3_url, $mp3_err, $mp3_br, $mp3_codec, undef, 'hq', $track_id, 0);
           });
           return;
       }

       my $bitrate = ($bitrate_kbps || 0) * 1000;
       $cb->($url, undef, $bitrate, $codec, $aes_key, $quality, $real_id, $gain);
   });
   ```

---

### 6.2. Модуль `Decode/MP4Demux.pm`

#### Задача:
При разборе бокса `dfLa` в `_parse_moov()` извлекать параметры потока и сохранять их в свойствах экземпляра `$self`. Добавить геттеры или прямой доступ к свойствам:
- `$self->{sample_rate}`
- `$self->{bits_per_sample}`
- `$self->{channels}`
- `$self->{total_samples}`

#### Точки изменения:
В методе `_parse_moov` (строки ~345–353):
```perl
    if ($self->{codec} eq 'flac') {
        my ($stbl_off, $stbl_size) = _find_stbl_for_codec($data_ref, 0, length($$data_ref), ['fLaC', 'flac', 'fla1'], \$err);
        if (defined $stbl_off) {
            my $meta_blocks = _extract_flac_metadata($data_ref, $stbl_off, $stbl_off + $stbl_size, \$err);
            if (defined $meta_blocks) {
                $self->{flac_header} = "fLaC" . $meta_blocks;

                # Парсинг STREAMINFO (первый блок в dfLa)
                # Блок 0: 1 байт тип + 3 байта длина (34) = 4 байта заголовок.
                # Смещение 14 от начала $meta_blocks: 8 байт (sample_rate, ch, bps, samples).
                if (length($meta_blocks) >= 38) {
                    my $block_type = unpack('C', substr($meta_blocks, 0, 1)) & 0x7F;
                    if ($block_type == 0) {
                        my ($hi, $lo) = unpack('NN', substr($meta_blocks, 14, 8));
                        $self->{sample_rate}     = ($hi >> 12) & 0xFFFFF;
                        $self->{channels}        = (($hi >> 9) & 0x07) + 1;
                        $self->{bits_per_sample} = (($hi >> 4) & 0x1F) + 1;
                        $self->{total_samples}   = ($hi & 0x0F) * 4294967296 + $lo;

                        $log->info(sprintf(
                            "YANDEX MP4Demux: FLAC STREAMINFO parsed: %d Hz, %d bit, %d ch, duration=%.2f s",
                            $self->{sample_rate},
                            $self->{bits_per_sample},
                            $self->{channels},
                            $self->{sample_rate} > 0 ? $self->{total_samples} / $self->{sample_rate} : 0
                        ));
                    }
                }
            }
        }
    } else {
        # Для AAC извлекаем частоту из AudioSpecificConfig (esds)
        # 2 байта ASC: 5 бит AOT, 4 бита samplingFreqIndex, 4 бита channelConfig
        ...
        if (defined $asc && length($asc) >= 2) {
            my ($asc_val) = unpack('n', substr($asc, 0, 2));
            my $freq_idx = ($asc_val >> 7) & 0x0F;
            my @rates = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350);
            $self->{sample_rate}     = $rates[$freq_idx] || 44100;
            $self->{bits_per_sample} = 16;
            $self->{channels}        = ($asc_val >> 3) & 0x0F;
        }
    }
```

---

### 6.3. Модуль `ProtocolHandler.pm`

#### Задача:
1. Сохранять `quality`, `real_id`, `gain` в кэш трека `yandex_meta_{id}` при вызове `_resolveStreamUrl`.
2. В `_sysread` при парсинге заголовков MP4 (как в `internal`, так и в `ffmpeg` бэкенде) считывать `sample_rate` и `bits_per_sample`, регистрировать их в `RemoteTrack`, `Song` и БД `Slim::Schema`.
3. В `getMetadataFor` реализовать честный показ статуса качества и Graceful Fallback.

#### 6.3.1. Обновление `_resolveStreamUrl`:
```perl
    $yandex_client->get_track_direct_url($track_id, sub {
        my ($final_url, $error, $bitrate, $codec, $aes_key, $quality, $real_id, $gain) = @_;

        if ($final_url) {
            $log->info("YANDEX: URL resolved codec=" . ($codec||'mp3')
                     . " quality=" . ($quality||'unk')
                     . " bitrate=" . ($bitrate||0)
                     . " realId=" . ($real_id||$track_id)
                     . " gain=" . ($gain ? 'yes' : 'no'));

            my $cache = Slim::Utils::Cache->new();
            my $cached_meta = $cache->get('yandex_meta_' . $track_id) || {};

            $cached_meta->{codec}    = $codec   if $codec;
            $cached_meta->{quality}  = $quality if $quality;
            $cached_meta->{real_id}  = $real_id if $real_id;
            $cached_meta->{gain}     = $gain    if defined $gain;
            $cached_meta->{aes_key}  = $aes_key if $aes_key;

            if ($codec && $codec =~ /^flac/) {
                $cached_meta->{bitrate} = $bitrate || 900000;
            } elsif ($bitrate) {
                $cached_meta->{bitrate} = $bitrate;
            }

            $cache->set('yandex_meta_' . $track_id, $cached_meta, 86400);

            # Очищаем кэш типа контента перед обновлением
            my $track_url = $song->track()->url();
            Slim::Schema->clearContentTypeCache($track_url);

            my ($ct, $est_bitrate, $is_vbr);
            if ($codec eq 'flac' || $codec eq 'flac-mp4') {
                $ct          = ($codec eq 'flac-mp4') ? 'flac-MP4' : 'flc';
                $est_bitrate = $bitrate || 900000;
                $is_vbr      = 1;
            } elsif ($codec =~ /-mp4$/) {
                $ct          = 'aac-MP4';
                $est_bitrate = $bitrate || 192000;
            } else {
                $ct          = 'mp3';
                $est_bitrate = $bitrate || 320000;
            }

            eval {
                Slim::Schema->updateOrCreate({
                    url        => $track_url,
                    readTags   => 0,
                    commit     => 1,
                    attributes => {
                        CONTENT_TYPE => $ct,
                        LOSSLESS     => ($codec =~ /^flac/ ? 1 : 0),
                    },
                });
                Slim::Music::Info::setBitrate($track_url, $est_bitrate, $is_vbr);
            };

            $song->streamUrl($final_url);
            $successCb->();
        } else {
            $errorCb->($error);
        }
    });
```

#### 6.3.2. Логика честного статуса в `getMetadataFor`:
```perl
sub getMetadataFor {
    my ($class, $client, $url) = @_;

    if ($url =~ /yandexmusic:\/\/(\d+)/) {
        my $track_id = $1;
        my $cache = Slim::Utils::Cache->new();
        my $cached_meta = $cache->get('yandex_meta_' . $track_id);

        if ($cached_meta) {
            my $codec       = $cached_meta->{codec} || '';
            my $quality     = $cached_meta->{quality} || '';
            my $bitrate     = $cached_meta->{bitrate} || 0;
            my $max_bitrate = $prefs->get('max_bitrate') || 320;

            my ($type, $display_type, $bitrate_str);

            if ($codec eq 'flac-mp4' || $codec eq 'flac') {
                $type = ($codec eq 'flac-mp4') ? 'flac-MP4' : 'flc';
                $display_type = 'FLAC';
                # Если уже известны частота и разрядность, отображаем точный профиль:
                if ($cached_meta->{samplerate} && $cached_meta->{samplesize}) {
                    $bitrate_str = sprintf("FLAC Lossless (%d/%s)",
                        $cached_meta->{samplesize},
                        ($cached_meta->{samplerate} >= 1000 ? ($cached_meta->{samplerate}/1000) . "k" : $cached_meta->{samplerate})
                    );
                } else {
                    $bitrate_str = "FLAC Lossless";
                }
            } elsif ($max_bitrate eq 'flac' && ($codec eq 'mp3' || $quality eq 'hq' || $quality eq 'nq')) {
                # ЧЕСТНЫЙ ФОЛБЭК: Пользователь просил FLAC, но сервер отдал MP3
                $type = $display_type = 'mp3';
                my $kbps = int(($bitrate > 1000 ? $bitrate / 1000 : $bitrate) || 320);
                $bitrate_str = sprintf("%d kbps MP3 (Lossless недоступен)", $kbps);
            } elsif ($max_bitrate eq 'flac' && $codec =~ /-mp4$/) {
                # ЧЕСТНЫЙ ФОЛБЭК: Сервер отдал AAC
                $type = $display_type = 'aac-MP4';
                my $kbps = int(($bitrate > 1000 ? $bitrate / 1000 : $bitrate) || 192);
                $bitrate_str = sprintf("%d kbps AAC (Lossless недоступен)", $kbps);
            } elsif (!$codec && $max_bitrate eq 'flac') {
                # Поток еще не резолвился API: нейтральный статус
                $type = $display_type = 'flc';
                $bitrate_str = "FLAC (запрос...)";
            } elsif ($codec =~ /-mp4$/) {
                $type = $display_type = 'aac-MP4';
                $bitrate_str = sprintf("%.0f kbps AAC", ($bitrate > 1000 ? $bitrate/1000 : $bitrate));
            } else {
                $type = $display_type = 'mp3';
                $bitrate_str = sprintf("%.0f kbps", ($bitrate > 1000 ? $bitrate/1000 : $bitrate));
            }

            # Сохранение в метаданные для Material Skin и Squeezebox
            my $meta_result = {
                title      => $cached_meta->{title},
                artist     => $cached_meta->{artist},
                album      => $cached_meta->{album},
                duration   => $cached_meta->{duration},
                cover      => $cached_meta->{cover},
                icon       => $cached_meta->{cover},
                bitrate    => $bitrate_str,
                type       => $display_type,
            };

            # Проброс сэмплрейта и разрядности при их наличии
            if ($cached_meta->{samplerate}) {
                $meta_result->{samplerate} = $cached_meta->{samplerate};
            }
            if ($cached_meta->{samplesize}) {
                $meta_result->{samplesize} = $cached_meta->{samplesize};
            }
            if ($cached_meta->{channels}) {
                $meta_result->{channels} = $cached_meta->{channels};
            }

            return $meta_result;
        }
        ...
```

---

#### 6.3.3. Передача параметров частоты и разрядности в ядро LMS из потока

Когда `MP4Demux.pm` парсит `moov` (при `demux_backend = 'internal'` или при первичном анализе заголовка в `_sysread`):

```perl
sub _apply_stream_audio_info {
    my ($sock, $song, $sample_rate, $bits_per_sample, $channels) = @_;

    return unless $sample_rate && $bits_per_sample;

    my $url = $song->currentTrack ? $song->currentTrack->url : undef;
    return unless $url;

    my ($track_id) = $url =~ /yandexmusic:\/\/(?:track\/)?(\d+)/;
    if ($track_id) {
        my $cache = Slim::Utils::Cache->new();
        my $cached_meta = $cache->get('yandex_meta_' . $track_id) || {};
        $cached_meta->{samplerate} = $sample_rate;
        $cached_meta->{samplesize} = $bits_per_sample;
        $cached_meta->{channels}   = $channels || 2;
        $cache->set('yandex_meta_' . $track_id, $cached_meta, 86400);
    }

    # 1. Обновление RemoteTrack
    my $track = $song->track();
    if ($track) {
        $track->samplerate($sample_rate);
        $track->samplesize($bits_per_sample);
        $track->channels($channels || 2);
    }

    # 2. Обновление объекта Song
    $song->pluginData(samplerate => $sample_rate);
    $song->pluginData(samplesize => $bits_per_sample);

    # 3. Фиксация в БД Slim::Schema
    eval {
        Slim::Schema->updateOrCreate({
            url        => $url,
            readTags   => 0,
            commit     => 1,
            attributes => {
                SAMPLERATE => $sample_rate,
                SAMPLESIZE => $bits_per_sample,
                CHANNELS   => ($channels || 2),
            },
        });
    };

    # 4. Уведомление контроллеров интерфейса (Material Skin, Touch)
    if (my $client = $song->master()) {
        $client->currentPlaylistUpdateTime(Time::HiRes::time());
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    }

    $log->info("YANDEX: Stream audio profile registered: $sample_rate Hz, $bits_per_sample bit, $channels ch for $url");
}
```

---

## 7. Поддержка обоих бэкендов (`internal` и `ffmpeg`)

В плагине существует настройка `demux_backend` (`'internal'` или `'ffmpeg'`).

1. **Режим `internal` (`MP4Demux.pm`):**  
   Экземпляр `${*$sock}{yandex_demux}` активен. Как только `process()` завершает разбор бокса `moov` (`$demux->{header_parsed} == 1`), обработчик `_sysread` проверяет:
   ```perl
   if ($demux->{header_parsed} && !${*$self}{yandex_profile_applied}) {
       if ($demux->{sample_rate} && $demux->{bits_per_sample}) {
           _apply_stream_audio_info($self, $song, $demux->{sample_rate}, $demux->{bits_per_sample}, $demux->{channels});
           ${*$self}{yandex_profile_applied} = 1;
       }
   }
   ```
2. **Режим `ffmpeg` (транскодирование через `custom-convert.conf`):**  
   В этом режиме `${*$sock}{yandex_demux}` не создан, а расшифрованные данные уходят в `ffmpeg` через stdout/pipe.  
   **Решение:** На первом чанке потока (когда `stream_pos == 0` в `_sysread`), в памяти сокета аккумулируются первые 16–32 КБ (бокс `moov` в файлах Яндекса идет сразу за `ftyp` и занимает ~12–15 КБ). Можно создать временный легковесный парсер `MP4Demux` в режиме `header_only` (просто вызвать `process()` до момента `header_parsed`) исключительно для извлечения свойств `sample_rate` и `bits_per_sample` без вмешательства в поток данных FFmpeg.

---

## 8. Тестовая матрица и верификация (QA Checklist)

| № | Сценарий | Ожидаемый результат в Material Skin / Squeezebox Touch |
| :--- | :--- | :--- |
| **1** | Трек с честным Lossless FLAC (16 bit / 44.1 kHz) | Тип: `FLAC`, Бейджи: `16bit`, `44.1kHz`, Текст: `FLAC Lossless (16/44.1k)`. |
| **2** | Трек с честным Hi-Res FLAC (24 bit / 96 kHz или 48 kHz) | Тип: `FLAC`, Бейджи: `24bit`, `96kHz`, Текст: `FLAC Lossless (24/96k)`. Режим ЦАП переключается в 96k. |
| **3** | Трек без Lossless у правообладателя (настройка `flac`, ответ `quality=hq, codec=mp3, bitrate=320`) | Тип: `MP3`, Текст: `320 kbps MP3 (Lossless недоступен)`. Никаких ложных иконок FLAC. |
| **4** | Трек без Lossless (ответ `quality=nq, codec=mp3, bitrate=192`) | Тип: `MP3`, Текст: `192 kbps MP3 (Lossless недоступен)`. |
| **5** | Настройка пользователя `max_bitrate = 320` | Обычное штатное отображение `320 kbps MP3` без суффикса о недоступности Lossless. |
| **6** | Позиционирование (Seek) и возобновление (Resume) | Сохранение и корректное восстановление частоты и разрядности после отжатия паузы или скачка по треку. |

---

## 9. Резюме для разработчика

- Все изменения локализованы в трех файлах: `API/Async.pm`, `Decode/MP4Demux.pm`, `ProtocolHandler.pm`.
- Не требуется внешних CPAN-зависимостей: побитовый unpack выполняется встроенными средствами Perl (`pack`/`unpack`).
- Избегать несуществующих методов `Slim::Music::Info::setSampleRate`. Использовать `RemoteTrack->samplerate()`, `RemoteTrack->samplesize()` и `Slim::Schema->updateOrCreate`.
- Решение полностью устраняет жалобы пользователей на расхождение между отображаемым и реальным качеством звука.
