package Plugins::yandex::API::Common;

use strict;
use warnings;
use utf8;

# Centralized constants for Yandex Music API
use constant CLIENT_VERSION => '24023621';
use constant USER_AGENT     => 'Yandex-Music-API';
use constant BASE_URL       => 'https://api.music.yandex.net';

# Shared function to generate standard Yandex API headers
sub get_default_headers {
    my ($token, $content_type) = @_;

    $content_type ||= 'application/json';

    my $headers = {
        'User-Agent'            => USER_AGENT,
        'X-Yandex-Music-Client' => 'YandexMusicAndroid/' . CLIENT_VERSION,
        'Accept-Language'       => 'ru',
        'Content-Type'          => $content_type,
    };

    if ($token) {
        $headers->{Authorization} = "OAuth $token";
    }

    return $headers;
}

1;
