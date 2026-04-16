package Plugins::yandex::Browse::InfoMenu;

# Context menu items injected into Slim::Menu::TrackInfo for Yandex Music tracks.
# Only activates for URLs matching yandexmusic://<track_id> (with or without query string).

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('plugin.yandex');

sub trackInfoMenu {
    my ($client, $url, $track, $remoteMeta) = @_;

    # Match yandexmusic://<digits> with optional ?query string
    return unless $url && $url =~ m{^yandexmusic://(\d+)(?:[?&]|$)};
    my $track_id = $1;

    my $api = Plugins::yandex::Plugin::getAPIForClient($client);
    return unless $api;

    my $wave_url = 'yandexmusic://rotor_session/track:' . $track_id;

    return {
        name  => 'Yandex Music',
        items => [
            {
                name        => cstring($client, 'PLUGIN_YANDEX_LIKE_TRACK'),
                type        => 'link',
                url         => \&_doLike,
                passthrough => [$api, $track_id],
            },
            {
                name        => cstring($client, 'PLUGIN_YANDEX_DISLIKE_TRACK'),
                type        => 'link',
                url         => \&_doDislike,
                passthrough => [$api, $track_id],
            },
            {
                name      => cstring($client, 'PLUGIN_YANDEX_WAVE_BY_TRACK'),
                type      => 'audio',
                url       => $wave_url,
                play      => $wave_url,
                on_select => 'play',
            },
        ],
    };
}

sub _doLike {
    my ($client, $cb, $args, $api, $track_id) = @_;
    $api->like_track(
        $track_id,
        sub { $cb->({ items => [{ name => cstring($client, 'PLUGIN_YANDEX_DONE'), type => 'text' }] }) },
        sub { $cb->({ items => [{ name => "Error: $_[0]", type => 'text' }] }) },
    );
}

sub _doDislike {
    my ($client, $cb, $args, $api, $track_id) = @_;
    $api->dislike_track(
        $track_id,
        sub { $cb->({ items => [{ name => cstring($client, 'PLUGIN_YANDEX_DONE'), type => 'text' }] }) },
        sub { $cb->({ items => [{ name => "Error: $_[0]", type => 'text' }] }) },
    );
}

1;
