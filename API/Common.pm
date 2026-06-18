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

# Get language parameter for API calls based on client language preference
# Returns 'ru' if Russian, 'en' for all other languages
sub get_api_language {
    my ($client) = @_;

    # Try to get language from client override (transient, per-request)
    my $lang;
    if ($client && $client->can('languageOverride')) {
        $lang = $client->languageOverride();
    }

    # Fall back to server default
    if (!$lang) {
        require Slim::Utils::Prefs;
        $lang = Slim::Utils::Prefs::preferences('server')->get('language') || 'en';
    }

    # Normalize: Russian -> 'ru', everything else -> 'en'
    return ($lang && $lang =~ /^ru/i) ? 'ru' : 'en';
}

1;
