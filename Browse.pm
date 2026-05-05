package Plugins::yandex::Browse;

=encoding utf8

=head1 NAME

Plugins::yandex::Browse - Thin facade over Browse:: submodules

=head1 DESCRIPTION

Re-exports all browse entry points under a single namespace so that
Plugin.pm and ProtocolHandler.pm only need to C<use> one module.
Actual logic lives in Browse::Search, Browse::Favorites, Browse::Radio,
Browse::Collection, and Browse::Common.

Also owns C<_handleAlbum>, C<_handleArtist>, C<explodePlaylist>, and
C<canDoAction> — functions that depend on multiple submodules and don't
belong cleanly in any one of them.

=cut

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

my $prefs = preferences('plugin.yandex');

use Plugins::yandex::Browse::Common;
use Plugins::yandex::Browse::Search;
use Plugins::yandex::Browse::Favorites;
use Plugins::yandex::Browse::Radio;
use Plugins::yandex::Browse::Collection;

my $log = logger('plugin.yandex');

# --- Entry Points ---

# Search
sub _handleRecentSearches { Plugins::yandex::Browse::Search::handleRecentSearches(@_) }
sub _handleSearch         { Plugins::yandex::Browse::Search::handleSearch(@_) }
sub _handleSearchTracks   { Plugins::yandex::Browse::Search::handleSearchTracks(@_) }
sub _handleSearchAlbums   { Plugins::yandex::Browse::Search::handleSearchAlbums(@_) }
sub _handleSearchArtists  { Plugins::yandex::Browse::Search::handleSearchArtists(@_) }
sub _handleSearchPlaylists { Plugins::yandex::Browse::Search::handleSearchPlaylists(@_) }
sub _handleSearchPodcasts { Plugins::yandex::Browse::Search::handleSearchPodcasts(@_) }

# Favorites
sub _handleFavorites      { Plugins::yandex::Browse::Favorites::handleFavorites(@_) }
sub _handleLikedTracks    { Plugins::yandex::Browse::Favorites::handleLikedTracks(@_) }
sub _handleLikedAlbums    { Plugins::yandex::Browse::Favorites::handleLikedAlbums(@_) }
sub _handleLikedPodcasts  { Plugins::yandex::Browse::Favorites::handleLikedPodcasts(@_) }
sub _handleLikedArtists   { Plugins::yandex::Browse::Favorites::handleLikedArtists(@_) }
sub _handleLikedPlaylists { Plugins::yandex::Browse::Favorites::handleLikedPlaylists(@_) }

# Radio
sub _handleRadioCategories { Plugins::yandex::Browse::Radio::handleRadioCategories(@_) }
sub _handleRadioCategoryList { Plugins::yandex::Browse::Radio::handleRadioCategoryList(@_) }
sub _handleWaveModes      { Plugins::yandex::Browse::Radio::handleWaveModes(@_) }

# Discovery & Collections
sub _handleChart          { Plugins::yandex::Browse::Collection::handleChart(@_) }
sub _handleNewReleases    { Plugins::yandex::Browse::Collection::handleNewReleases(@_) }
sub _handleNewPlaylists   { Plugins::yandex::Browse::Collection::handleNewPlaylists(@_) }
sub _handleForYou         { Plugins::yandex::Browse::Collection::handleForYou(@_) }
sub _handleSmartPlaylists { Plugins::yandex::Browse::Collection::handleSmartPlaylists(@_) }
sub _handlePicks          { Plugins::yandex::Browse::Collection::handlePicks(@_) }
sub _handleMixes          { Plugins::yandex::Browse::Collection::handleMixes(@_) }
sub _handleTagPlaylists   { Plugins::yandex::Browse::Collection::handleTagPlaylists(@_) }

# Individual Items
sub _handleAlbum {
    my ($client, $cb, $args, $yandex_client, $album_id) = @_;
    if (ref $yandex_client eq 'HASH') {
        $album_id ||= $yandex_client->{id};
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    $yandex_client->get_album_with_tracks(
        $album_id,
        sub {
            my $album = shift;
            my $tracks = $album->{volumes} ? [ map { @$_ } @{$album->{volumes}} ] : [];
            Plugins::yandex::Browse::Common::renderTrackList($tracks, $cb, $album->{title}, 'yandexmusic://album/' . $album_id);
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handleArtist {
    my ($client, $cb, $args, $yandex_client, $artist_id) = @_;
    if (ref $yandex_client eq 'HASH') {
        $artist_id ||= $yandex_client->{id};
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    my $base_url = 'yandexmusic://rotor_session/';

    my @items = (
        {
            name  => cstring($client, 'PLUGIN_YANDEX_POPULAR_TRACKS'),
            type  => 'playlist',
            url   => \&_handleArtistTracks,
            passthrough => [$yandex_client, $artist_id],
            play  => 'yandexmusic://artist/' . $artist_id,
            image => 'html/images/musicfolder.png',
        },
        {
            name  => cstring($client, 'PLUGIN_YANDEX_ALBUMS'),
            type  => 'link',
            url   => \&_handleArtistAlbums,
            passthrough => [$yandex_client, $artist_id],
            image => 'html/images/albums.png',
        },
        {
            name  => cstring($client, 'PLUGIN_YANDEX_ALSO_ALBUMS'),
            type  => 'link',
            url   => \&_handleArtistAlsoAlbums,
            passthrough => [$yandex_client, $artist_id],
            image => 'html/images/albums.png',
        },
        {
            name     => cstring($client, 'PLUGIN_YANDEX_WAVE_BY_ARTIST'),
            type     => 'audio',
            url      => $base_url . 'artist:' . $artist_id,
            play     => $base_url . 'artist:' . $artist_id,
            on_select => 'play',
            image    => 'plugins/yandex/html/images/radio.png',
        },
        {
            name  => cstring($client, 'PLUGIN_YANDEX_SIMILAR_ARTISTS'),
            type  => 'link',
            url   => \&_handleSimilarArtists,
            passthrough => [$yandex_client, $artist_id],
            image => 'html/images/artists.png',
        },
    );

    $cb->({
        items => \@items,
        title => 'Artist',
    });
}

sub _handleArtistTracks {
    my ($client, $cb, $args, $yandex_client, $artist_id) = @_;
    if (ref $yandex_client eq 'HASH') {
        $artist_id ||= $yandex_client->{id}; # id or undef
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    $yandex_client->get_artist_tracks(
        $artist_id,
        sub {
            my $tracks = shift;
            Plugins::yandex::Browse::Common::renderTrackList($tracks, $cb, 'Popular Tracks', 'yandexmusic://artist/' . $artist_id);
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handleArtistAlbums {
    my ($client, $cb, $args, $yandex_client, $artist_id) = @_;
    if (ref $yandex_client eq 'HASH') {
        $artist_id ||= $yandex_client->{id};
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    $yandex_client->get_artist_albums(
        $artist_id,
        sub {
            my $albums = shift;
            my @items;

            foreach my $album (@$albums) {
                my $title = $album->{title} // 'Unknown Album';
                my $year = $album->{year} // '';
                $title .= " ($year)" if $year;

                my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                if ($album->{coverUri}) {
                    $icon = $album->{coverUri};
                    $icon =~ s/%%/200x200/;
                    $icon = "https://$icon";
                }

                push @items, {
                    name  => $title,
                    type  => 'album',
                    url   => \&_handleAlbum,
                    passthrough => [$yandex_client, $album->{id}],
                    image => $icon,
                    play  => 'yandexmusic://album/' . $album->{id},
                };
            }

            $cb->({
                items => \@items,
                title => 'Albums',
            });
        },
        sub {
             my $error = shift;
             $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handleArtistAlsoAlbums {
    my ($client, $cb, $args, $yandex_client, $artist_id) = @_;
    if (ref $yandex_client eq 'HASH') {
        $artist_id ||= $yandex_client->{id};
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    $yandex_client->get_artist_also_albums(
        $artist_id,
        sub {
            my $albums = shift;
            my @items;

            foreach my $album (@$albums) {
                my $title  = $album->{title} // 'Unknown Album';
                my $artist = ($album->{artists} && $album->{artists}[0]) ? ($album->{artists}[0]->{name} // '') : '';
                my $year   = $album->{year} // '';
                $title .= " ($year)" if $year;
                $title .= " — $artist" if $artist;

                my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                if ($album->{coverUri}) {
                    $icon = $album->{coverUri};
                    $icon =~ s/%%/200x200/;
                    $icon = "https://$icon";
                }

                push @items, {
                    name  => $title,
                    type  => 'album',
                    url   => \&_handleAlbum,
                    passthrough => [$yandex_client, $album->{id}],
                    image => $icon,
                    play  => 'yandexmusic://album/' . $album->{id},
                };
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_ALSO_ALBUMS'),
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handleSimilarArtists {
    my ($client, $cb, $args, $yandex_client, $artist_id) = @_;
    if (ref $yandex_client eq 'HASH') {
        $artist_id ||= $yandex_client->{id};
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    $yandex_client->get_similar_artists(
        $artist_id,
        sub {
            my $artists = shift;
            my @items;

            foreach my $artist (@$artists) {
                my $name = $artist->{name} // 'Unknown Artist';

                my $icon = 'html/images/artists.png';
                if ($artist->{cover} && $artist->{cover}->{uri}) {
                    $icon = $artist->{cover}->{uri};
                    $icon =~ s/%%/200x200/;
                    $icon = "https://$icon";
                }

                push @items, {
                    name  => $name,
                    type  => 'link',
                    url   => \&_handleArtist,
                    passthrough => [$yandex_client, $artist->{id}],
                    image => $icon,
                };
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_SIMILAR_ARTISTS'),
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handlePlaylist {
    my ($client, $cb, $args, $yandex_client, $user_id, $kind) = @_;
    if (ref $yandex_client eq 'HASH') {
        $user_id ||= $yandex_client->{uid};
        $kind    ||= $yandex_client->{kind};
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    $yandex_client->get_playlist(
        $user_id,
        $kind,
        sub {
            my $playlist = shift;
            my $tracks_container = $playlist->{tracks} // [];
            
            my @tracks;
            foreach my $item (@$tracks_container) {
                if ($item->{track}) {
                    push @tracks, $item->{track};
                } else {
                    push @tracks, $item;
                }
            }

            Plugins::yandex::Browse::Common::renderTrackList(\@tracks, $cb, $playlist->{title}, 'yandexmusic://playlist/' . $user_id . '/' . $kind);
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

# --- Legacy/Utility Hooks ---
# (Some other modules might still call these via Plugins::yandex::Browse::...)

sub cache_track_metadata { Plugins::yandex::Browse::Common::cache_track_metadata(@_) }
sub hasRecentSearches    { Plugins::yandex::Browse::Search::hasRecentSearches(@_) }

1;
