package Plugins::yandex::Browse::InfoMenu;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('plugin.yandex');

sub trackInfoMenu {
    my ($client, $url, $track, $remoteMeta) = @_;

    my $api = Plugins::yandex::Plugin::getAPIForClient($client);
    return unless $api;

    # Extract metadata from any track
    my $artist = $remoteMeta->{artist} || ($track->artistName) || undef;
    my $album  = $remoteMeta->{album} || ($track->album ? $track->album->name : undef) || undef;
    my $title  = $remoteMeta->{title} || ($track->title) || undef;

    my @items;

    # Yandex-specific actions (Like, Dislike, Wave)
    if ($url && $url =~ m{^yandexmusic://(\d+)(?:[?&]|$)}) {
        my $track_id = $1;
        my $wave_url = 'yandexmusic://rotor_session/track:' . $track_id;

        push @items, (
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
        );
    }

    # Search on Yandex Music (for any track)
    my @search_items;

    if ($artist) {
        push @search_items, {
            name        => cstring($client, 'SEARCH') . ' ' .
                           cstring($client, 'ARTISTS') . " '$artist'",
            type        => 'link',
            url         => \&Plugins::yandex::Browse::Search::handleSearchArtists,
            image       => 'html/images/artists.png',
            passthrough => [$api, $artist],
        };
    }

    if ($album) {
        push @search_items, {
            name        => cstring($client, 'SEARCH') . ' ' .
                           cstring($client, 'ALBUMS') . " '$album'",
            type        => 'link',
            url         => \&Plugins::yandex::Browse::Search::handleSearchAlbums,
            image       => 'html/images/albums.png',
            passthrough => [$api, $album],
        };
    }

    if ($title) {
        push @search_items, {
            name        => cstring($client, 'SEARCH') . ' ' .
                           cstring($client, 'SONGS') . " '$title'",
            type        => 'link',
            url         => \&Plugins::yandex::Browse::Search::handleSearchTracks,
            image       => 'html/images/musicfolder.png',
            passthrough => [$api, $title],
        };
    }

    if (@search_items) {
        push @items, {
            type  => 'outline',
            name  => cstring($client, 'PLUGIN_YANDEX_ON_YANDEX'),
            items => \@search_items,
        };
    }

    return unless @items;
    return {
        name  => 'Yandex Music',
        items => \@items,
    };
}

sub albumInfoMenu {
    my ($client, $url, $album, $remoteMeta) = @_;

    return unless $album;
    my $albumName = ($remoteMeta && $remoteMeta->{album}) || ($album && $album->title);
    return unless $albumName;

    my $api = Plugins::yandex::Plugin::getAPIForClient($client);
    return unless $api;

    return {
        type        => 'link',
        name        => cstring($client, 'PLUGIN_YANDEX_ON_YANDEX'),
        url         => \&Plugins::yandex::Browse::Search::handleSearchAlbums,
        passthrough => [$api, $albumName],
    };
}

sub artistInfoMenu {
    my ($client, $url, $artist, $remoteMeta) = @_;

    return unless $artist;
    my $artistName = ($remoteMeta && $remoteMeta->{artist}) || ($artist && $artist->name);
    return unless $artistName;

    my $api = Plugins::yandex::Plugin::getAPIForClient($client);
    return unless $api;

    return {
        type        => 'link',
        name        => cstring($client, 'PLUGIN_YANDEX_ON_YANDEX'),
        url         => \&Plugins::yandex::Browse::Search::handleSearchArtists,
        passthrough => [$api, $artistName],
    };
}

sub browseArtistMenu {
    my ($client, $cb, $params, $args) = @_;

    my $artistId = $params->{artist_id} || $args->{artist_id};
    my $empty = [{ type => 'text', title => cstring($client, 'EMPTY') }];

    if (defined($artistId) && $artistId =~ /^\d+$/ &&
        (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {

        my $api = Plugins::yandex::Plugin::getAPIForClient($client);
        return $cb->($empty) unless $api;

        Plugins::yandex::Browse::Search::handleSearchArtists(
            $client, sub {
                my $result = shift;
                $cb->($result->{items} || $empty);
            }, $args, $api, $artistObj->name
        );
    } else {
        $cb->($empty);
    }
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
