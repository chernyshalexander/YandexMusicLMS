#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use Digest::SHA qw(hmac_sha256);
use MIME::Base64;
use Time::HiRes qw(time);
use Data::Dumper;

my $TOKEN    = $ENV{YANDEX_MUSIC_TOKEN} or die "Set YANDEX_MUSIC_TOKEN environment variable\n";
my $TRACK_ID = '16580941';

sub uri_escape {
    my $str = shift;
    $str =~ s/([^a-zA-Z0-9_.\-~])/sprintf("%%%02X", ord($1))/eg;
    return $str;
}

sub do_request {
    my ($label, $sign_key, $codecs, $transport, $client_header) = @_;

    my $ts           = int(time());
    my $codecs_sign  = $codecs;
    $codecs_sign     =~ s/,//g;
    my $param_string = "${ts}${TRACK_ID}lossless${codecs_sign}${transport}";

    my $sign = substr(encode_base64(hmac_sha256($param_string, $sign_key), ''), 0, 43);

    my $url = "https://api.music.yandex.net/get-file-info"
            . "?ts=$ts&trackId=$TRACK_ID&quality=lossless"
            . "&codecs=" . uri_escape($codecs)
            . "&transports=$transport"
            . "&sign=" . uri_escape($sign);

    print "\n=== $label ===\n";
    print "Param string: $param_string\n";

    my $http = HTTP::Tiny->new(default_headers => {
        'Authorization'         => "OAuth $TOKEN",
        'X-Yandex-Music-Client' => $client_header,
    });

    my $resp = $http->get($url);
    if ($resp->{success}) {
        my $data = decode_json($resp->{content});
        my $di   = $data->{result}{downloadInfo};
        printf "codec=%-10s  bitrate=%-6s  has_key=%s\n",
            $di->{codec}   // '?',
            $di->{bitrate} // '?',
            (exists $di->{key} ? "YES (encrypted)" : "no");
        print "url: " . ($di->{url} // '?') . "\n";
        print Dumper($di) if exists $di->{key};
    } else {
        print "FAILED $resp->{status}: $resp->{content}\n";
    }
}

# Approach 1: raw transport (issue #656)
do_request(
    "raw / kzqU4XhfCaY6B6JTHODeq5",
    'kzqU4XhfCaY6B6JTHODeq5',
    'flac,aac,he-aac,mp3',
    'raw',
    'YandexMusicDesktopAppWindows/5.13.2',
);

# Approach 2: encraw / Music Assistant key / Desktop client
do_request(
    "encraw / p93jhgh689SBReK6ghtw62 / Desktop",
    'p93jhgh689SBReK6ghtw62',
    'flac-mp4,flac,aac-mp4,aac,he-aac,mp3,he-aac-mp4',
    'encraw',
    'YandexMusicDesktopAppWindows/5.13.2',
);

# Approach 3: encraw / Music Assistant key / Android client
do_request(
    "encraw / p93jhgh689SBReK6ghtw62 / Android",
    'p93jhgh689SBReK6ghtw62',
    'flac-mp4,flac,aac-mp4,aac,he-aac,mp3,he-aac-mp4',
    'encraw',
    'YandexMusicAndroid/24023621',
);
