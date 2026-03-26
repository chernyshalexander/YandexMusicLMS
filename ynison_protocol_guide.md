# Руководство по протоколу Yandex Ynison

Данный документ описывает протокол Ynison, используемый в Яндекс Музыке для синхронизации состояния воспроизведения между устройствами.

## Общая схема подключения

Протокол работает поверх WebSocket, используя gRPC-совместимый формат сообщений (обычно Protobuf, но может передаваться и как JSON).

1.  **Redirector**: Клиент подключается к `wss://ynison.music.yandex.ru/redirector.YnisonRedirectService/GetRedirectToYnison` для получения адреса рабочего сервера сессии.
2.  **Session Host**: Клиент подключается к полученному хосту по адресу `wss://{host}/ynison_state.YnisonStateService/PutYnisonState`.

## Типы сообщений (PutYnisonStateRequest)

Клиент отправляет одно из следующих сообщений в параметре `parameters` (oneof).

| Сообщение | Когда отправляется | Ожидаемая реакция / Действие |
| :--- | :--- | :--- |
| **UpdateFullState** | Холодный старт, выход из оффлайна, восстановление сети. | Инициализирует полное состояние плеера и список устройств. |
| **UpdateActiveDevice** | Пользователь выбрал текущее устройство как основное (Master). | Сервер переключает `active_device_id` на указанный ID. |
| **UpdatePlayingStatus** | Play, Pause, Seek (перемотка), изменение скорости. | Синхронизирует позицию (`progress_ms`) и статус паузы. |
| **UpdatePlayerState** | Смена плейлиста, добавление/удаление треков, смена режима Repeat/Shuffle. | Обновляет очередь воспроизведения (`player_queue`). |
| **UpdateVolumeInfo** | Изменение громкости на устройстве. | Синхронизирует уровень громкости на всех устройствах. |
| **UpdateSessionParams** | Перевод устройства в пассивный режим (`mute_events_if_passive`). | Сервер перестает слать обновления этому устройству, пока оно не станет активным. |
| **SyncStateFromEOV** | Запрос синхронизации с Единой Очередью Воспроизведения (EOV). | Подгружает актуальную очередь с серверов Яндекса. |

## Роли устройств

| Роль | Состояние | Поведение |
| :--- | :--- | :--- |
| **Master (Active)** | `is_currently_active=true` | Устройство, которое непосредственно выводит звук. Является источником истины для `progress_ms`. |
| **Slave (Remote)** | `can_be_remote_controller=true` | Устройство-пульт. Отображает состояние Master и может отправлять команды управления. |
| **Passive** | `mute_events_if_passive=true` | Устройство в сети, но не участвующее в управлении активно (экономит трафик). |

## СтруктураPlayerState

*   **`player_queue`**: Содержит `playable_list` (список треков), `current_playable_index`, `entity_id` (ID плейлиста/альбома) и настройки (shuffle/repeat).
*   **`status`**: Содержит `progress_ms`, `duration_ms`, `paused`, `playback_speed`.

## Важные нюансы реализации

*   **Версионность**: Почти каждое сообщение содержит объект `version` с `device_id`, `version` (int64) и `timestamp_ms`. Это предотвращает "гонки" (race conditions) при обновлении состояния.
*   **Activity Interception**: В `PutYnisonStateRequest` поле `activity_interception_type` определяет, как устройство должно забирать активность:
    *   `DO_NOT_INTERCEPT`: Просто обновление данных.
    *   `INTERCEPT_IF_NO_ONE_ACTIVE`: Стать Master, если никто не играет.
    *   `INTERCEPT_EAGER`: Принудительно стать Master (перехват).
