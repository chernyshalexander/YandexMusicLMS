### Яндекс Музыка для Lyrion Music Server
Плагин для прослушивания Яндекс Музыки на Lyrion Music Server (LMS).
**Для работы плагина необходима действующая подписка Яндекс Плюс.**
#### Возможности
- Доступ к вашей коллекции: треки, альбомы, исполнители и плейлисты.
- Раздел «Для вас»: персональные рекомендации, «Моя волна» и персональные плейлисты.
- Радиостанции по жанрам, настроениям, действиям и эпохам.
- Умные плейлисты и миксы. Поиск по трекам, альбомам, исполнителям, подкастам и аудиокнигам.
- Отображение «Горячих треков» и «Новых релизов» в главном меню (при желании).
- Поддержка потоков MP3 (до 320 кбит/с). Использование серверной буферизации.
- Передача обратной связи (feedback) для улучшения персональных рекомендаций.
#### Настройка и получение токена
Требуется OAuth-токен. Способы получения:
1. **Встроенный 1:** в настройках плагина перетащите кнопку "Capture token" на панель закладок браузера, нажмите «Login to yandex», в открывшемся окне авторизуйтесь в Яндексе, затем нажмите "Capture token" на панели закладок.
2. **Встроенный 2, Drag-and-Drop:** нажмите «Login to yandex», в открывшемся окне авторизуйтесь в Яндексе и перетащите URL с токеном из адресной строки в окне с браузера в поле настройки.
3. **Вручную:** используйте [yandex-music-token](https://github.com/MarshalX/yandex-music-token) и вставьте токен в поле настроек.
#### В планах (TODO)
- Поддержка FLAC и протокола Ynison; запуск «Моей волны» по треку, артисту, альбому или коллекции; работа с несколькими учетными записями; более глубокая интеграция с LMS.
#### Благодарности
За идеи и вдохновение: [MarshalX](https://github.com/MarshalX), [philippe44](https://github.com/philippe44), [Michael Herger](https://github.com/michaelherger).
#### Установка
В настройках LMS (Plugins -> Additional Repositories) добавьте ссылку: Стабильная версия:`https://chernyshalexander.github.io/YandexMusicLMS/public.xml`, версия в разработке: `https://chernyshalexander.github.io/YandexMusicLMS/dev.xml`
#### Лицензия
Лицензия MIT. Подробности в LICENSE. Яндекс Музыка и логотип являются товарными знаками ООО «Яндекс». Данный плагин не связан с компанией Яндекс.
***
### Yandex Music for Lyrion Music Server
A plugin to play Yandex Music on Lyrion Music Server (LMS).
**An active Yandex Plus subscription is required for the plugin to work.**
#### Features
- Personal Collection: Access to liked tracks, albums, artists, and playlists.
- "For You": Personal recommendations, "My Vibe", and personal playlists.
- Radio Stations: Browse and play by genre, mood, activity, and era.
- Smart Playlists and Mixes. Search for tracks, albums, artists, podcasts, and audiobooks.
- Discovery: Optional "Hot Tracks" and "New Releases" in the main menu.
- Quality up to 320kbps MP3. Server-side buffering for stable playback.
- Interactive Feedback: Sends track events to improve recommendations.
#### Configuration & Token
OAuth token is required. Methods to obtain:
1. **Built-in 1:** Drag the "Capture token" button to your browser's bookmark bar, click "Login to yandex", authenticate in the opened window, then click "Capture token" on the bookmark bar.
2. **Built-in 2, Drag-and-Drop:** Click "Login to yandex", authenticate in the opened window, and drag the URL with the token from the browser's address bar into the settings field.
3. **Manual:** Use [yandex-music-token](https://github.com/MarshalX/yandex-music-token) and paste the token manually.
#### Roadmap (TODO)
- FLAC and Ynison protocol support; start "My Vibe" by track, artist, album, or collection; multiple account support; deeper LMS integration.
#### Credits
For ideas and inspiration: [MarshalX](https://github.com/MarshalX), [philippe44](https://github.com/philippe44), [Michael Herger](https://github.com/michaelherger).
#### Installation
In LMS settings (Plugins -> Additional Repositories) add:
Stable: `https://chernyshalexander.github.io/YandexMusicLMS/public.xml`, Dev: `https://chernyshalexander.github.io/YandexMusicLMS/dev.xml`
#### License
MIT License. See LICENSE for details. Yandex Music is a trademark of Yandex LLC. No association between Yandex and this plugin.
