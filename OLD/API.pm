package Plugins::yandex::API;

use strict;
#use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;  
use warnings;

use LWP::UserAgent;
use JSON;
use URI::Escape;


my $log=Slim::Utils::Log::logger('plugin.yandex.api');

our $API_URL = 'https://api.music.yandex.net ';

sub get_liked_tracks {
    my ($token) = @_;

    my $url = "$API_URL/users/me/likes/tracks";

    my $ua = LWP::UserAgent->new;
    $ua->default_header('Authorization' => "OAuth $token");

    my $response = $ua->get($url);
    if (!$response->is_success) {
        $log->error("Ошибка получения плейлиста: " . $response->status_line);
        return [];
    }

    my $json = decode_json($response->decoded_content);
    return $json->{tracks} || [];
}

sub get_track_url {
    my ($token, $track_id) = @_;

    my $url = "$API_URL/tracks/$track_id/downloadinfo";

    my $ua = LWP::UserAgent->new;
    $ua->default_header('Authorization' => "OAuth $token");

    my $response = $ua->get($url);
    if (!$response->is_success) {
        $log->error("Ошибка получения URL трека: " . $response->status_line);
        return undef;
    }

    my $json = decode_json($response->decoded_content);
    return $json->{downloadInfo}->[0]->{directLink} if $json->{downloadInfo} && $json->{downloadInfo}->[0]->{directLink};

    return undef;
}

1;