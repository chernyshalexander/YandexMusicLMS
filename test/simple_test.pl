use strict;
use warnings;
use LWP::UserAgent;
use Data::Dumper;
use JSON;

# Создаём объект для выполнения запросов
my $ua = LWP::UserAgent->new(
    ssl_opts => {
        verify_hostname => 0,  # Отключаем проверку хоста (если сертификат не валидный)
        SSL_verify_mode => 0,  # Отключаем проверку сертификата
    }
);

# Устанавливаем заголовки
$ua->default_header('User-Agent' => 'Yandex-Music-API');
$ua->default_header('X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621');
$ua->default_header('Accept-Language' => 'ru');
$ua->default_header('Authorization' => 'OAuth YOUR_YANDEX_OAUTH_TOKEN');

# Выполняем GET-запрос
my $response = $ua->get('https://api.music.yandex.net/account/status');

# Проверяем результат
if ($response->is_success) {
    my $json = decode_json($response->decoded_content);
    print "Результат:\n";
    print Dumper($json);  # Используем Dumper для удобного вывода структуры
} else {
    print "Ошибка: " . $response->status_line . "\n";
}
