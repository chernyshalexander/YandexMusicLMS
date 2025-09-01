package Plugins::yandex::Player;

use strict;
use warnings;
use Slim::Utils::Log;

use Slim::Player::Playlist;

my $log=Slim::Utils::Log::logger('plugin.yandex.api');

sub playTrackURL {
    # my ($class, $track_id, $token, $client) = @_;

    # my $url = Plugins::yandex::API::get_track_url($token, $track_id);
    # return undef unless $url;

    # Slim::Player::Playlist::clear($client);
    # Slim::Player::Playlist::add($client, $url);
    # Slim::Player::Playlist::play($client);
    my $url ='';
    return $url;
}

1;