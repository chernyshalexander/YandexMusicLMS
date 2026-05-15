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

1;
