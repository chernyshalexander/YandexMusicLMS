package Plugins::yandex::API::Common;

=encoding utf8

=head1 NAME

Plugins::yandex::API::Common - Centralized constants and utilities for Yandex Music API

=head1 DESCRIPTION

Provides shared constants and utility functions used by all Yandex Music API modules.
Includes OAuth authentication headers, API endpoint base URL, and client version information.

=head1 EXPORTS

=over 4

=item B<BASE_URL>

Yandex Music API base URL: C<https://api.music.yandex.net>

=item B<CLIENT_VERSION>

Spoofed Android client version for API access (required for C<encraw> lossless transport)

=item B<USER_AGENT>

User agent string for HTTP requests

=item B<get_default_headers($token, $content_type)>

Generate standard HTTP headers with OAuth token and proper client identification.

=back

=cut

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
