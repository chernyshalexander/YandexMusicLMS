# Ynison Improvements Implementation Design

**Date:** 2026-06-18  
**Branch:** experiment  
**Status:** Design Approved

---

## Overview

Восстановление и улучшение Ynison интеграции в ветке `experiment` путём внедрения 5 ключевых улучшений из документации, с фокусом на надёжность синхронизации и отладку.

---

## Architecture & Components

### Core Changes (Ynison.pm)

#### 1. Echo Detection v2 — RID Tracking
Tracking отправленных RID с timestamp для надёжного определения echo.

**Реализация:**
- Новое поле: `sent_commands: {rid => {time, command_type, data}}`
- Метод `_detect_command_type()` — определить тип команды (ping, pong, update_full_state, etc.)
- Метод `_cleanup_old_commands()` — удалять RID старше 10 сек
- При получении сообщения: проверить RID в `sent_commands`, если есть и latency < 3s — это echo, пропустить

**Константа:** `RID_TIMEOUT => 10`

#### 2. Adaptive Reconnection — умная стратегия переподключения
Разные стратегии переподключения в зависимости от типа ошибки.

**Реализация:**
- Новые поля: `last_error, error_count, first_error_time, reconnection_stats`
- Константы для стратегий:
  ```
  NORMAL_RECONNECT_MIN => 5, NORMAL_RECONNECT_MAX => 60
  TIMEOUT_RECONNECT_MIN => 30, TIMEOUT_RECONNECT_MAX => 120
  NETWORK_RECONNECT_MIN => 10, NETWORK_RECONNECT_MAX => 180
  AUTH_ERROR_MAX_RETRIES => 3
  ```
- Метод `_get_reconnect_strategy($reason, $error_count)` — возвращает (min_delay, max_delay, should_retry)
- Метод `get_reconnection_stats()` — возвращает статистику
- Обновить `_schedule_reconnect($reason)` чтобы использовать стратегию

#### 3. Message Queue Buffering — контроль очереди
Правильное управление буфером сообщений с контролем размера и timeout.

**Реализация:**
- Константы:
  ```
  MAX_WRITE_QUEUE_SIZE => 100
  MAX_FRAME_SIZE => 1024 * 1024
  FRAME_TIMEOUT => 30
  ```
- Обновить `_queue_frame()`:
  - Проверить размер фрейма
  - Проверить размер очереди (если >= 100, удалить самый старый)
  - Добавить timestamp и counter в очередь: `{data, sent_at, attempts}`
- Обновить `_on_writable()`:
  - Проверить timeout (> 30s → drop)
  - На ошибку write → reconnect
  - На partial write → обновить буфер, increment attempts

#### 4. Extended Logging — расширенная отладка
Система логирования с буфером для отладки.

**Реализация:**
- Константы: `LOG_LEVEL_TRACE=0, DEBUG=1, INFO=2, WARN=3, ERROR=4`
- Новые поля:
  ```
  debug_mode => $prefs->get('ynison_debug') || 0
  log_buffer => []  # последние 1000 логов
  stats => {frames_sent, frames_received, bytes_sent, bytes_received, ...}
  ```
- Метод `_log($level, $msg)`:
  - Логировать в LMS лог (если debug_mode)
  - Сохранить в буфер (max 1000)
  - Опционально писать в лог файл
- Метод `_log_frame($direction, $frame_data)` — логирование JSON фреймов
- Метод `_log_state()` — логирование переходов состояния
- Метод `get_debug_info()` — возвращает полный статус для отладки

#### 5. Complex Cast Scenarios — лучшая обработка Cast
Асинхронная загрузка треков при Cast команде.

**Реализация:**
- В Plugin.pm: метод `_rebuild_lms_queue_from_yandex($client, $ynison, $queue)`
  - Очистить плейлист
  - Загрузить треки асинхронно
  - Отслеживать прогресс (X/Y треков)
  - Установить правильный индекс трека
  - Применить статус (paused/playing)

### Integration Points (Plugin.pm)

- Инициализация Ynison при login
- Обработка playerEventCallback для отправки state updates
- Callback для получения state updates с Yandex
- Включение/отключение через settings

---

## Data Flow

```
User action (play/pause/next)
    ↓
Plugin.pm::playerEventCallback()
    ↓
Ynison->update_state()
    ↓
send_command() → _queue_frame()
    ↓
sent_commands[rid] = {time, type, data}  ← RID Tracking
    ↓
WebSocket send with retry logic
    ↓
[Yandex Server processes]
    ↓
_on_message_received()
    ↓
Check RID in sent_commands[rid] for echo
    ↓
If latency < 3s && same type → ECHO DETECTED, skip
    ↓
_log() → debug buffer + optional file
    ↓
Call listeners (Plugin.pm callbacks)
    ↓
Plugin.pm applies state changes to LMS
```

---

## Error Handling

| Scenario | Current | New |
|----------|---------|-----|
| Echo loop | simple device_id check | RID + latency verification |
| Connection fail | fixed 5-60s backoff | adaptive: 1s-180s by error type |
| Queue overflow | drops messages silently | controlled drop + warning log |
| Message timeout | hangs | 30s timeout → reconnect('write_timeout') |
| Auth failure | retries forever | max 3 retries then give up |
| Network error | normal reconnect | longer delays (10-180s) |

---

## Testing Strategy

### Integration Tests (test/ynison_integration_tests.pl)

**Test 1: Echo Detection**
- Send play command with rid='test-1'
- Verify it appears in sent_commands
- Simulate server echoing it back
- Verify Plugin.pm doesn't apply it twice
- Check logs show "Echo detected"

**Test 2: Adaptive Reconnection**
- Force different error types (auth_error, timeout, network_error)
- Verify correct reconnect delays are used
- Check reconnection_stats increments correctly
- Verify auth_error stops retrying after 3 attempts

**Test 3: Queue Buffering**
- Queue 150 frames rapidly
- Verify only 100 buffered (drop oldest)
- Verify dropped frames logged as warning
- Simulate slow send (partial writes)
- Verify frames eventually sent

**Test 4: Cast Command**
- Send Cast from mobile app (or simulate)
- Verify LMS clears current playlist
- Monitor logs for "Loading X/Y tracks" progress
- Verify tracks load and playback starts at correct index
- Verify pause state is applied

### Logging Validation

- Enable debug mode: `ynison_debug=1`
- Monitor logs for:
  - Echo detection events
  - Reconnection reasons and delays
  - Queue full warnings
  - Frame send/receive
  - State transitions
- Use `get_debug_info()` endpoint to check:
  - Current state
  - Write queue size
  - Log buffer content
  - Stats (frames sent/received, bytes, uptime)

---

## Files to Modify

1. **Ynison.pm** — add 5 improvements (600-700 new lines)
   - sent_commands tracking
   - _detect_command_type(), _cleanup_old_commands()
   - _get_reconnect_strategy()
   - _log(), _log_frame(), _log_state(), get_debug_info()
   - _rebuild_lms_queue_from_yandex() support

2. **Plugin.pm** — restore/enhance integration points (~100 lines)
   - Initialize Ynison on login
   - Connect playerEventCallback
   - Sync state updates from Yandex

3. **Settings.pm** — add preferences (2-3 lines)
   - ynison_debug (boolean)

4. **HTML/EN/plugins/yandex/settings/basic.html** — add UI (5-10 lines)
   - Debug mode checkbox

5. **test/ynison_integration_tests.pl** — create test suite (~300 lines)
   - Integration tests as described above

---

## Success Criteria

✅ Echo detection works: no duplicate state application  
✅ Reconnection adapts to error type  
✅ Queue never exceeds 100 messages  
✅ All frames eventually sent (no permanent hangs)  
✅ Integration tests pass with real Yandex app  
✅ Debug logging provides clear visibility into issues  
✅ Cast scenarios work smoothly (no empty playlist)  

---

## Timeline Estimate

- Phase 1: Echo Detection + Adaptive Reconnection (2-3 hours)
- Phase 2: Queue Buffering + Logging (2-3 hours)
- Phase 3: Complex Cast + Integration (2-3 hours)
- Phase 4: Testing + Fixes (2-3 hours)

**Total:** ~8-12 hours of implementation

---

**Status:** Ready for implementation plan
