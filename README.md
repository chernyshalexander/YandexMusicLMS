#### Яндекс Музыка для Lyrion Music Server
Плагин для прослушивания Яндекс Музыки на Lyrion Music Server (LMS).

**Для работы плагина необходима действующая подписка Яндекс Плюс.**

##### Возможности
- Доступ к вашей коллекции: треки, альбомы, исполнители и плейлисты.
- Раздел «Для вас»: персональные рекомендации, «Моя волна» и персональные плейлисты.
- Радиостанции по жанрам, настроениям, действиям и эпохам.
- **Build My Vibe** (Создай свою волну) — гибкая настройка радиопотока с фильтрами по настроению/активности, жанру, эпохе и языку.
- **My Vibe by Artist** — персональное радио в стиле выбранного исполнителя.
- Умные плейлисты и миксы. Поиск по трекам, альбомам, исполнителям, подкастам и аудиокнигам.
- Отображение «Горячих треков» и «Новых релизов» в главном меню (при желании).
- Поддержка высококачественного аудио: **FLAC** (включая FLAC-in-MP4) и **AAC** (включая AAC-MP4 и HE-AAC).
- Поддержка потоков MP3 (до 320 кбит/с).
- Передача обратной связи (feedback) для улучшения персональных рекомендаций.
- Работа с несколькими учётными записями.
- Интеграция онлайн билиотеки Яндекс Музыки с локальной билиотекой.

##### Настройка и получение токена
Требуется OAuth-токен. Способы получения:
1. **Встроенный 1:** в настройках плагина перетащите кнопку "Capture token" на панель закладок браузера, нажмите «Login to yandex», в открывшемся окне авторизуйтесь в Яндексе, затем нажмите "Capture token" на панели закладок.
2. **Встроенный 2, Drag-and-Drop:** нажмите «Login to yandex», в открывшемся окне авторизуйтесь в Яндексе и перетащите URL с токеном из адресной строки браузера в поле настройки.
3. **Вручную:** используйте [yandex-music-token](https://github.com/MarshalX/yandex-music-token) и вставьте токен в поле настроек.

##### В планах (TODO)
 - Интеграция с протоколом Ynison

##### Благодарности
За идеи и вдохновение: [MarshalX](https://github.com/MarshalX), [philippe44](https://github.com/philippe44), [Michael Herger](https://github.com/michaelherger).

##### Установка
Плагин доступен в стандартном списке плагинов Lyrion Music Server. Перейдите в настройки сервера → **Управление плагинами** (Manage Plugins), найдите **Yandex Music** и установите его. После установки перезапустите Lyrion Music Server.

Чтобы добавить репозиторий вручную:  
В настройках LMS (Plugins → Additional Repositories) добавьте ссылку:  
Стабильная версия: `https://chernyshalexander.github.io/YandexMusicLMS/public.xml`  
Версия в разработке: `https://chernyshalexander.github.io/YandexMusicLMS/dev.xml`

##### Лицензия
Лицензия MIT. Подробности в LICENSE. Яндекс Музыка и логотип являются товарными знаками ООО «Яндекс». Данный плагин не связан с компанией Яндекс.

---


#### Yandex Music for Lyrion Music Server
A plugin to play Yandex Music on Lyrion Music Server (LMS).

**An active Yandex Plus subscription is required for the plugin to work.**

##### Features
- Access to your personal collection: tracks, albums, artists, and playlists.
- "For You" section: personal recommendations, **My Vibe**, and personal playlists.
- Radio stations by genre, mood, activity, and era.
- **Build My Vibe** — fine-grained control over the radio stream with filters for mood/activity, genre, era, and language.
- **My Vibe by Artist** — start a personalized radio station based on any chosen artist’s style.
- Smart playlists and mixes. Search for tracks, albums, artists, podcasts, and audiobooks.
- Optional "Hot Tracks" and "New Releases" in the main menu.
- High-quality audio support: **FLAC** (including FLAC-in-MP4) and **AAC** (including AAC-MP4 & HE-AAC).
- MP3 streaming up to 320 kbps.
- Interactive feedback to improve personal recommendations.
- Multiple account support.
- Deeper integration with local library.

##### Configuration & Token
An OAuth token is required. Ways to obtain it:
1. **Built-in 1:** Drag the "Capture token" button to your browser’s bookmark bar, click "Login to yandex", authenticate in the opened window, then click "Capture token" on the bookmark bar.
2. **Built-in 2, Drag-and-Drop:** Click "Login to yandex", authenticate in the opened window, and drag the URL with the token from the browser’s address bar into the settings field.
3. **Manual:** Use [yandex-music-token](https://github.com/MarshalX/yandex-music-token) and paste the token manually.

##### Roadmap (TODO)
 - Ynison protocol integration

##### Credits
For ideas and inspiration: [MarshalX](https://github.com/MarshalX), [philippe44](https://github.com/philippe44), [Michael Herger](https://github.com/michaelherger).

##### Installation
The plugin is available in the official plugin directory of Lyrion Music Server. Go to the server settings, click **Manage Plugins**, search for **Yandex Music** and install it. Restart Lyrion Music Server after installation.

To add the plugin repository manually:  
In LMS settings (Plugins → Additional Repositories) add:  
Stable: `https://chernyshalexander.github.io/YandexMusicLMS/public.xml`  
Dev: `https://chernyshalexander.github.io/YandexMusicLMS/dev.xml`

##### License
MIT License. See LICENSE for details. Yandex Music is a trademark of Yandex LLC. This plugin is not affiliated with Yandex.
