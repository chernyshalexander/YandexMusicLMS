package Plugins::yandex::Browse;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

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

    my @items = (
        {
            name => 'Popular Tracks',
            type => 'playlist',
            url => \&_handleArtistTracks,
            passthrough => [$yandex_client, $artist_id],
            play => 'yandexmusic://artist/' . $artist_id,
        },
        {
            name => 'Albums',
            type => 'link',
            url => \&_handleArtistAlbums,
            passthrough => [$yandex_client, $artist_id],
        }
    );

    $cb->({
        items => \@items,
        title => 'Artist',
    });
}

sub _handleArtistTracks {
    my ($client, $cb, $args, $yandex_client, $artist_id) = @_;

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
                    name => $title,
                    type => 'album',
                    url => \&_handleAlbum,
                    passthrough => [$yandex_client, $album->{id}],
                    image => $icon,
                    play => 'yandexmusic://album/' . $album->{id},
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

sub _handlePlaylist {
    my ($client, $cb, $args, $yandex_client, $user_id, $kind) = @_;

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
