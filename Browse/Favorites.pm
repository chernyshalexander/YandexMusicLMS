package Plugins::yandex::Browse::Favorites;

# Browse handlers for the user's personal library:
# liked tracks, albums, artists, playlists, and podcasts.
# All handlers follow the same pattern: fetch a list of short objects from the
# API, then fetch full metadata in chunks of 50 (the API's max per request).

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::yandex::Browse::Common;

my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

sub handleFavorites {
    my ($client, $cb, $args, $yandex_client) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_TRACKS'),
            type => 'link',
            url  => \&handleLikedTracks,
            passthrough => [$yandex_client],
            image => 'html/images/musicfolder.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_ALBUMS'),
            type => 'link',
            url  => \&handleLikedAlbums,
            passthrough => [$yandex_client],
            image => 'html/images/albums.png',
        },
    );

    my $has_podcasts = $prefs->get('yandex_has_podcasts');
    if (!defined $has_podcasts) {
        $has_podcasts = 1; 
        $yandex_client->users_likes_albums(
            sub {
                my $albums = shift;
                my $found = 0;
                foreach my $album (@$albums) {
                    if (($album->{type} // '') =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i)) {
                        $found = 1;
                        last;
                    }
                }
                $prefs->set('yandex_has_podcasts', $found);
            },
            sub {}
        );
    }

    if ($has_podcasts) {
        push @items, {
            name => cstring($client, 'PLUGIN_YANDEX_AUDIOBOOKS_PODCASTS'),
            type => 'link',
            url  => \&handleLikedPodcasts,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/podcast_svg.png',
        };
    }

    push @items, (
        {
            name => cstring($client, 'PLUGIN_YANDEX_ARTISTS'),
            type => 'link',
            url  => \&handleLikedArtists,
            passthrough => [$yandex_client],
            image => 'html/images/artists.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_PLAYLISTS'),
            type => 'link',
            url  => \&handleLikedPlaylists,
            passthrough => [$yandex_client],
            image => 'html/images/playlists.png',
        },
        {
            name      => cstring($client, 'PLUGIN_YANDEX_WAVE_FAVORITES'),
            type      => 'audio',
            url       => 'yandexmusic://rotor_session/user:onyourwave?diversity=favorite',
            play      => 'yandexmusic://rotor_session/user:onyourwave?diversity=favorite',
            on_select => 'play',
            image     => 'plugins/yandex/html/images/radio.png',
        },
    );

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_MY_COLLECTION'),
    });
}

sub handleLikedTracks {
    my ($client, $cb, $args, $yandex_client) = @_;

    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 500;

    $yandex_client->users_likes_tracks(
        sub {
            my $tracks_short = shift;
            my @track_ids = reverse map { $_->{id} } @$tracks_short;
            my $total_tracks = scalar @track_ids;

            if ($total_tracks == 0) {
                 Plugins::yandex::Browse::Common::renderTrackList([], $cb, 'Favorite tracks');
                return;
            }

            my $end = $index + $quantity - 1;
            $end = $total_tracks - 1 if $end >= $total_tracks;
            my @slice_ids = @track_ids[$index .. $end];

            $yandex_client->tracks(
                \@slice_ids,
                sub {
                    my $tracks_detailed = shift;
                    my %detailed_map = map { $_->{id} => $_ } @$tracks_detailed;
                    my @sorted_tracks = map { $detailed_map{$_} } grep { exists $detailed_map{$_} } @slice_ids;
                    
                    Plugins::yandex::Browse::Common::renderTrackList(\@sorted_tracks, $cb, 'Favorite tracks', 'yandexmusic://favorites/tracks', {
                        offset => $index,
                        total  => $total_tracks,
                    });
                },
                sub {
                    my $error = shift;
                    $log->error("Error fetching tracks details chunk for favorites: $error");
                    $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => 'Favorite tracks' });
                }
            );
        },
        sub {
            my $error = shift;
            $log->error("Error retrieving favorite tracks list: $error");
            $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => 'Favorite tracks' });
        },
    );
}

sub handleLikedAlbums {
    my ($client, $cb, $args, $yandex_client) = @_;
    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 500;

    $yandex_client->users_likes_albums(
        sub {
            my $albums_all = shift;
            my @items;
            my $has_podcasts = 0;

            my @filtered_albums;
            foreach my $album (reverse @$albums_all) {
                if (($album->{type} // '') =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i)) {
                    $has_podcasts = 1;
                    next;
                }
                push @filtered_albums, $album;
            }

            my $total = scalar @filtered_albums;
            my $end = $index + $quantity - 1;
            $end = $total - 1 if $end >= $total;
            my @slice = ($index <= $end) ? @filtered_albums[$index .. $end] : ();

            foreach my $album (@slice) {
                my $title = $album->{title} // 'Unknown Album';
                my $artist = $album->{artists}[0]->{name} // 'Unknown Artist';
                
                my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                if ($album->{coverUri}) {
                    $icon = $album->{coverUri};
                    $icon =~ s/%%/200x200/;
                    $icon = "https://$icon";
                }

                push @items, {
                    name => $title . ' (' . $artist . ')',
                    type => 'album',
                    url => \&Plugins::yandex::Browse::_handleAlbum,
                    passthrough => [$yandex_client, $album->{id}],
                    image => $icon,
                    play => 'yandexmusic://album/' . $album->{id},
                };
            }

            $prefs->set('yandex_has_podcasts', $has_podcasts);

            $cb->({
                items => \@items,
                title => 'Favorite Albums',
                offset => $index,
                total => $total,
            });
        },
        sub {
            my $error = shift;
            $cb->({
                items => [{ name => "Error: $error", type => 'text' }],
                title => 'Favorite Albums',
            });
        }
    );
}

sub handleLikedPodcasts {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->users_likes_albums(
        sub {
            my $albums = shift;
            my @items;
            my $has_podcasts = 0;

            foreach my $album (@$albums) {
                unless (($album->{type} // '') =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i)) {
                    next;
                }
                $has_podcasts = 1;

                my $title = $album->{title} // 'Unknown Podcast/Audiobook';
                my $artist = $album->{artists}[0]->{name} // 'Unknown Artist';
                
                my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                if ($album->{coverUri}) {
                    $icon = $album->{coverUri};
                    $icon =~ s/%%/200x200/;
                    $icon = "https://$icon";
                }

                push @items, {
                    name => $title . ' (' . $artist . ')',
                    type => 'album',
                    url => \&Plugins::yandex::Browse::_handleAlbum,
                    passthrough => [$yandex_client, $album->{id}],
                    image => $icon,
                    play => 'yandexmusic://album/' . $album->{id},
                };
            }

            $prefs->set('yandex_has_podcasts', $has_podcasts);

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_AUDIOBOOKS_PODCASTS'),
            });
        },
        sub {
            my $error = shift;
            $cb->({
                items => [{ name => "Error: $error", type => 'text' }],
                title => cstring($client, 'PLUGIN_YANDEX_AUDIOBOOKS_PODCASTS'),
            });
        }
    );
}

sub handleLikedArtists {
    my ($client, $cb, $args, $yandex_client) = @_;
    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 500;

    $yandex_client->users_likes_artists(
        sub {
            my $artists_all = shift;
            my @artists = reverse @$artists_all;
            my $total = scalar @artists;

            my $end = $index + $quantity - 1;
            $end = $total - 1 if $end >= $total;
            my @slice = ($index <= $end) ? @artists[$index .. $end] : ();

            my @items;
            foreach my $artist (@slice) {
                my $name = $artist->{name} // 'Unknown Artist';
                
                my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                if ($artist->{cover} && $artist->{cover}->{uri}) {
                    $icon = $artist->{cover}->{uri};
                    $icon =~ s/%%/200x200/;
                    $icon = "https://$icon";
                }

                push @items, {
                    name => $name,
                    type => 'link',
                    url => \&Plugins::yandex::Browse::_handleArtist,
                    passthrough => [$yandex_client, $artist->{id}],
                    image => $icon,
                };
            }

            $cb->({
                items => \@items,
                title => 'Favorite Artists',
                offset => $index,
                total => $total,
            });
        },
        sub {
            my $error = shift;
            $cb->({
                items => [{ name => "Error: $error", type => 'text' }],
                title => 'Favorite Artists',
            });
        }
    );
}

sub handleLikedPlaylists {
    my ($client, $cb, $args, $yandex_client) = @_;
    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 500;

    $yandex_client->users_likes_playlists(
        sub {
            my $liked_playlists = shift;

            $yandex_client->users_playlists_list(
                sub {
                    my $user_playlists = shift;
                    
                    my @all_playlists_raw = (@$liked_playlists, @$user_playlists);
                    my @deduped;
                    my %seen_ids;

                    foreach my $playlist (reverse @all_playlists_raw) {
                        my $uid = $playlist->{owner}->{uid};
                        my $kind = $playlist->{kind};
                        next if $seen_ids{"$uid:$kind"}++;
                        push @deduped, $playlist;
                    }
                    
                    my $total = scalar @deduped;
                    my $end = $index + $quantity - 1;
                    $end = $total - 1 if $end >= $total;
                    my @slice = ($index <= $end) ? @deduped[$index .. $end] : ();

                    my @items;
                    foreach my $playlist (@slice) {
                        my $uid = $playlist->{owner}->{uid};
                        my $kind = $playlist->{kind};
                        my $title = $playlist->{title} // 'Unknown Playlist';
                        my $owner = $playlist->{owner}->{name} // 'Unknown User';
                        
                        my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                        if ($playlist->{cover} && $playlist->{cover}->{uri}) {
                            $icon = $playlist->{cover}->{uri};
                            $icon =~ s/%%/200x200/;
                            $icon = "https://$icon";
                        } elsif ($playlist->{ogImage}) {
                             $icon = $playlist->{ogImage};
                             $icon =~ s/%%/200x200/;
                             $icon = "https://$icon";
                        }

                        push @items, {
                            name => $title . ' (' . $owner . ')',
                            type => 'link',
                            url => \&Plugins::yandex::Browse::_handlePlaylist,
                            passthrough => [$yandex_client, $uid, $kind],
                            image => $icon,
                            play => 'yandexmusic://playlist/' . $uid . '/' . $kind,
                        };
                    }

                    $cb->({
                        items => \@items,
                        title => 'Favorite Playlists',
                        offset => $index,
                        total => $total,
                    });
                },
                sub {
                    my $error = shift;
                    $log->error("Error fetching user playlists: $error");
                    $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => 'Favorite Playlists' });
                }
            );
        },
        sub {
            my $error = shift;
            $log->error("Error retrieving favorite playlists: $error");
            $cb->({ items => [{ name => "Error: $error", type => 'text' }], title => 'Favorite Playlists' });
        },
    );
}

1;
