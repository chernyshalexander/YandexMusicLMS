package Plugins::yandex::Browse;

use strict;
use warnings;
use utf8;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Encode qw(encode);

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.yandex',
    'defaultLevel' => 'ERROR',
    'description'  => 'PLUGIN_YANDEX',
});

my $prefs = preferences('plugin.yandex');

use constant MAX_RECENT => 10;

# Recent Searches logic

sub hasRecentSearches {
    return scalar @{ $prefs->get('yandex_recent_search') || [] };
}

sub addRecentSearch {
    my ( $search ) = @_;

    my $list = $prefs->get('yandex_recent_search') || [];

    # remove potential duplicates
    $list = [ grep { lc($_) ne lc($search) } @$list ];

    unshift @$list, $search;

    # we only want MAX_RECENT items
    $list = [ @$list[0..(MAX_RECENT-1)] ] if scalar @$list > MAX_RECENT;

    $prefs->set( 'yandex_recent_search', $list );
}

sub clearRecentSearches {
    $prefs->set( 'yandex_recent_search', [] );
}

sub _handleRecentSearches {
    my ($client, $cb, $args, $yandex_client, $extra_args) = @_;

    if ($extra_args && $extra_args->{clear_history}) {
        clearRecentSearches();
    }

    my $items = [];

    push @$items, {
        name  => 'New Search',
        type  => 'search',
        url   => \&_handleSearch,
        passthrough => [$yandex_client],
        image => 'html/images/search.png',
    };

    my $history = $prefs->get('yandex_recent_search') || [];
    for my $recent ( @$history ) {
        push @$items, {
            name  => $recent,
            type  => 'link',
            url   => \&_handleSearch,
            passthrough => [$yandex_client, { query => $recent, recent => 1 }],
            image => 'plugins/yandex/html/images/history.png',
        };
    }

    if (@$history) {
        push @$items, {
            name => 'Clear Search History',
            type => 'link',
            url  => \&_handleRecentSearches,
            passthrough => [$yandex_client, { clear_history => 1 }],
            image => 'plugins/yandex/html/images/icon_blank.png'
        };
    }

    $cb->({ items => $items, title => 'Search' });
}

# Search handlers

sub _handleSearch {
    my ($client, $cb, $args, $yandex_client, $extra_args) = @_;

    my $query = $args->{search} || ($extra_args && $extra_args->{query}) || '';
    if (!$query) {
        $cb->({ items => [] });
        return;
    }

    addRecentSearch($query) unless ($extra_args && $extra_args->{recent});

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'all',
        sub {
            my $result = shift;
            
            my @items;

            if ($result->{tracks} && $result->{tracks}->{results} && @{$result->{tracks}->{results}}) {
                push @items, {
                    name => cstring($client, 'PLUGIN_YANDEX_TRACKS'),
                    type => 'link',
                    url  => \&_handleSearchTracks,
                    passthrough => [$yandex_client, $query],
                    image => 'html/images/musicfolder.png',
                };
            }

            if ($result->{albums} && $result->{albums}->{results} && @{$result->{albums}->{results}}) {
                push @items, {
                    name => cstring($client, 'PLUGIN_YANDEX_ALBUMS'),
                    type => 'link',
                    url  => \&_handleSearchAlbums,
                    passthrough => [$yandex_client, $query],
                    image => 'html/images/albums.png',
                };
            }

            if ($result->{artists} && $result->{artists}->{results} && @{$result->{artists}->{results}}) {
                push @items, {
                    name => cstring($client, 'PLUGIN_YANDEX_ARTISTS'),
                    type => 'link',
                    url  => \&_handleSearchArtists,
                    passthrough => [$yandex_client, $query],
                    image => 'html/images/artists.png',
                };
            }

            if ($result->{playlists} && $result->{playlists}->{results} && @{$result->{playlists}->{results}}) {
                push @items, {
                    name => cstring($client, 'PLUGIN_YANDEX_PLAYLISTS'),
                    type => 'link',
                    url  => \&_handleSearchPlaylists,
                    passthrough => [$yandex_client, $query],
                    image => 'html/images/playlists.png',
                };
            }

            if (!@items) {
                 push @items, { name => 'No results found', type => 'text' };
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_SEARCH') . ": $query"
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Search Error: $error", type => 'text' }] });
        }
    );
}

sub _handleSearchTracks {
    my ($client, $cb, $args, $yandex_client, $query) = @_;

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'track',
        sub {
            my $result = shift;
            my $tracks = [];
            if ($result->{tracks} && $result->{tracks}->{results}) {
                $tracks = $result->{tracks}->{results};
            }
            _renderTrackList($tracks, $cb, "Tracks: $query");
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handleSearchAlbums {
    my ($client, $cb, $args, $yandex_client, $query) = @_;

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'album',
        sub {
            my $result = shift;
            my @items;

            if ($result->{albums} && $result->{albums}->{results}) {
                foreach my $album (@{$result->{albums}->{results}}) {
                    my $title = $album->{title} // 'Unknown Album';
                    my $artist = $album->{artists} && @{$album->{artists}} ? $album->{artists}[0]->{name} : 'Unknown Artist';
                    
                    my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                    if ($album->{coverUri}) {
                        $icon = $album->{coverUri};
                        $icon =~ s/%%/200x200/;
                        $icon = "https://$icon";
                    }

                    push @items, {
                        name => $title . ' (' . $artist . ')',
                        type => 'album',
                        url => \&_handleAlbum,
                        passthrough => [$yandex_client, $album->{id}],
                        image => $icon,
                        play => 'yandexmusic://album/' . $album->{id},
                    };
                }
            }

            $cb->({
                items => \@items,
                title => "Albums: $query",
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handleSearchArtists {
    my ($client, $cb, $args, $yandex_client, $query) = @_;

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'artist',
        sub {
            my $result = shift;
            my @items;

            if ($result->{artists} && $result->{artists}->{results}) {
                foreach my $artist (@{$result->{artists}->{results}}) {
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
                        url => \&_handleArtist,
                        passthrough => [$yandex_client, $artist->{id}],
                        image => $icon,
                    };
                }
            }

            $cb->({
                items => \@items,
                title => "Artists: $query",
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

sub _handleSearchPlaylists {
    my ($client, $cb, $args, $yandex_client, $query) = @_;

    $yandex_client->search(
        $query,
        'playlist',
        sub {
            my $result = shift;
            my @items;

            if ($result->{playlists} && $result->{playlists}->{results}) {
                foreach my $playlist (@{$result->{playlists}->{results}}) {
                    my $title = $playlist->{title} // 'Unknown Playlist';
                    my $owner = $playlist->{owner} && $playlist->{owner}->{name} ? $playlist->{owner}->{name} : 'Unknown User';
                    
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
                        url => \&_handlePlaylist,
                        passthrough => [$yandex_client, $playlist->{owner}->{uid}, $playlist->{kind}],
                        image => $icon,
                        play => 'yandexmusic://playlist/' . $playlist->{owner}->{uid} . '/' . $playlist->{kind},
                    };
                }
            }

            $cb->({
                items => \@items,
                title => "Playlists: $query",
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

# Individual Item Handlers

sub _handleAlbum {
    my ($client, $cb, $args, $yandex_client, $album_id) = @_;

    $yandex_client->get_album_with_tracks(
        $album_id,
        sub {
            my $album = shift;
            my $tracks = $album->{volumes} ? [ map { @$_ } @{$album->{volumes}} ] : [];
            _renderTrackList($tracks, $cb, $album->{title}, 'yandexmusic://album/' . $album_id);
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
            _renderTrackList($tracks, $cb, 'Popular Tracks', 'yandexmusic://artist/' . $artist_id);
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

            _renderTrackList(\@tracks, $cb, $playlist->{title}, 'yandexmusic://playlist/' . $user_id . '/' . $kind);
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

# Favorites handlers

sub _handleFavorites {
    my ($client, $cb, $args, $yandex_client) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_TRACKS'),
            type => 'playlist',
            url  => \&_handleLikedTracks,
            passthrough => [$yandex_client],
            image => 'html/images/musicfolder.png',
            play => 'yandexmusic://favorites/tracks',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_ALBUMS'),
            type => 'link',
            url  => \&_handleLikedAlbums,
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
                    if ($album->{type} =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i)) {
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
            name => 'Audiobooks & Podcasts',
            type => 'link',
            url  => \&_handleLikedPodcasts,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/podcast.png',
        };
    }

    push @items, (
        {
            name => cstring($client, 'PLUGIN_YANDEX_ARTISTS'),
            type => 'link',
            url  => \&_handleLikedArtists,
            passthrough => [$yandex_client],
            image => 'html/images/artists.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_PLAYLISTS'),
            type => 'link',
            url  => \&_handleLikedPlaylists,
            passthrough => [$yandex_client],
            image => 'html/images/playlists.png',
        }
    );

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_MY_COLLECTION'),
    });
}

sub _handleLikedTracks {
    my ($client, $cb, $args, $yandex_client) = @_;

    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 100;

    $yandex_client->users_likes_tracks(
        sub {
            my $tracks_short = shift;
            my @track_ids = reverse map { $_->{id} } @$tracks_short;
            my $total_tracks = scalar @track_ids;

            if ($total_tracks == 0) {
                 _renderTrackList([], $cb, 'Favorite tracks');
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
                    
                    _renderTrackList(\@sorted_tracks, $cb, 'Favorite tracks', 'yandexmusic://favorites/tracks', {
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

sub _handleLikedAlbums {
    my ($client, $cb, $args, $yandex_client) = @_;
    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 100;

    $yandex_client->users_likes_albums(
        sub {
            my $albums_all = shift;
            my @items;
            my $has_podcasts = 0;

            my @filtered_albums;
            foreach my $album (reverse @$albums_all) {
                if ($album->{type} =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i)) {
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
                    url => \&_handleAlbum,
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

sub _handleLikedPodcasts {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->users_likes_albums(
        sub {
            my $albums = shift;
            my @items;
            my $has_podcasts = 0;

            foreach my $album (@$albums) {
                unless ($album->{type} =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i)) {
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
                    url => \&_handleAlbum,
                    passthrough => [$yandex_client, $album->{id}],
                    image => $icon,
                    play => 'yandexmusic://album/' . $album->{id},
                };
            }

            $prefs->set('yandex_has_podcasts', $has_podcasts);

            $cb->({
                items => \@items,
                title => 'Audiobooks & Podcasts',
            });
        },
        sub {
            my $error = shift;
            $cb->({
                items => [{ name => "Error: $error", type => 'text' }],
                title => 'Audiobooks & Podcasts',
            });
        }
    );
}

sub _handleLikedArtists {
    my ($client, $cb, $args, $yandex_client) = @_;
    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 100;

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
                    url => \&_handleArtist,
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

sub _handleLikedPlaylists {
    my ($client, $cb, $args, $yandex_client) = @_;
    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 100;

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
                            url => \&_handlePlaylist,
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

# Radio handlers

sub _handleRadioCategories {
    my ($client, $cb, $args, $yandex_client) = @_;

    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_MY_WAVE'),
            type => 'link',
            url  => \&_handleWaveModes,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_GENRES'),
            type => 'link',
            url  => \&_handleRadioCategoryList,
            passthrough => [$yandex_client, 'genre'],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_MOODS'),
            type => 'link',
            url  => \&_handleRadioCategoryList,
            passthrough => [$yandex_client, 'mood'],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_ACTIVITIES'),
            type => 'link',
            url  => \&_handleRadioCategoryList,
            passthrough => [$yandex_client, 'activity'],
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_RADIO_ERAS'),
            type => 'link',
            url  => \&_handleRadioCategoryList,
            passthrough => [$yandex_client, 'epoch'],
            image => 'plugins/yandex/html/images/radio.png',
        },
    );

    $cb->(\@items);
}

sub _handleRadioCategoryList {
    my ($client, $cb, $args, $yandex_client, $category_type) = @_;

    $yandex_client->rotor_stations_list(
        sub {
            my $stations = shift;
            my @items;

            foreach my $item (@$stations) {
                my $st = $item->{station};
                if ($st && $st->{id} && $st->{id}->{type} eq $category_type) {
                    my $tag = $st->{id}->{tag};
                    
                    my $icon = 'plugins/yandex/html/images/radio.png';

                    my $use_new_radio = $prefs->get('use_new_radio_api');
                    my $base_url = $use_new_radio ? 'yandexmusic://rotor_session/' : 'yandexmusic://rotor/';

                    push @items, {
                        name => $st->{name},
                        type => 'audio',
                        url  => $base_url . "$category_type:$tag",
                        play => $base_url . "$category_type:$tag",
                        on_select => 'play',
                        image => $icon,
                    };
                }
            }

            @items = sort { $a->{name} cmp $b->{name} } @items;

            $cb->(\@items);
        },
        sub {
            my $error = shift;
            $log->error("Failed to fetch radio stations: $error");
            $cb->([{ name => "Error: $error", type => 'text' }]);
        }
    );
}

sub _handleWaveModes {
    my ($client, $cb, $args, $yandex_client) = @_;

    my $use_new_radio = $prefs->get('use_new_radio_api');
    my $base_url = $use_new_radio ? 'yandexmusic://rotor_session/' : 'yandexmusic://rotor/';

    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_DEFAULT'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave',
            play => $base_url . 'user:onyourwave',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_DISCOVER'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?diversity=discover',
            play => $base_url . 'user:onyourwave?diversity=discover',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_FAVORITE'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?diversity=favorite',
            play => $base_url . 'user:onyourwave?diversity=favorite',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_POPULAR'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?diversity=popular',
            play => $base_url . 'user:onyourwave?diversity=popular',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_CALM'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=calm',
            play => $base_url . 'user:onyourwave?moodEnergy=calm',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_ACTIVE'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=active',
            play => $base_url . 'user:onyourwave?moodEnergy=active',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_FUN'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=fun',
            play => $base_url . 'user:onyourwave?moodEnergy=fun',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
        {
            name => cstring($client, 'PLUGIN_YANDEX_MODE_SAD'),
            type => 'audio',
            url  => $base_url . 'user:onyourwave?moodEnergy=sad',
            play => $base_url . 'user:onyourwave?moodEnergy=sad',
            on_select => 'play',
            image => 'plugins/yandex/html/images/radio.png',
        },
    );

    $cb->({
        items => \@items,
        title => cstring($client, 'PLUGIN_YANDEX_MY_WAVE'),
    });
}

# For You (Picks & Mixes)

my %TAG_SLUG_CATEGORY = (
    "chill" => "mood", "sad" => "mood", "romantic" => "mood", "party" => "mood", "relax" => "mood", "in the mood" => "mood",
    "workout" => "activity", "focus" => "activity", "morning" => "activity", "evening" => "activity", "driving" => "activity", "background" => "activity",
    "80s" => "era", "90s" => "era", "2000s" => "era", "retro" => "era",
    "rock" => "genres", "jazz" => "genres", "classical" => "genres", "electronic" => "genres", "rnb" => "genres", "hiphop" => "genres", "top" => "genres", "newbies" => "genres",
    "winter" => "seasonal", "spring" => "seasonal", "summer" => "seasonal", "autumn" => "seasonal", "newyear" => "seasonal",
);

sub _translate {
    my ($client, $str) = @_;
    my $key;
    if ($str =~ /^(mood|activity|era|genres)$/) {
        $key = 'PLUGIN_YANDEX_CAT_' . uc($str);
    } elsif ($str =~ /^(picks|mixes)$/) {
        $key = 'PLUGIN_YANDEX_' . uc($str);
    } else {
        $key = 'PLUGIN_YANDEX_TAG_' . uc($str);
        $key =~ s/\-/_/g; 
        $key =~ s/\s/_/g; 
    }
    my $translation = cstring($client, $key);
    return ($translation && $translation ne $key) ? $translation : ucfirst($str);
}

sub _handleForYou {
    my ($client, $cb, $args, $yandex_client) = @_;
    my @items = (
        {
            name => cstring($client, 'PLUGIN_YANDEX_SMART_PLAYLISTS'),
            type => 'link',
            url  => \&_handleSmartPlaylists,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/personal.png',
        },
        {
            name => _translate($client, 'picks'),
            type => 'link',
            url  => \&_handlePicks,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/personal.png',
        },
        {
            name => _translate($client, 'mixes'),
            type => 'link',
            url  => \&_handleMixes,
            passthrough => [$yandex_client],
            image => 'plugins/yandex/html/images/personal.png',
        }
    );
    $cb->({ items => \@items, title => cstring($client, 'PLUGIN_YANDEX_FOR_YOU') });
}

sub _handleSmartPlaylists {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->landing_personal_playlists(
        sub {
            my $blocks = shift;
            my @items;

            foreach my $block (@$blocks) {
                if ($block->{entities}) {
                    foreach my $entity (@{$block->{entities}}) {
                        if ($entity->{type} eq 'personal-playlist' && $entity->{data} && $entity->{data}->{data}) {
                            my $pl = $entity->{data}->{data};
                            my $uid = $pl->{owner}->{uid};
                            my $kind = $pl->{kind};
                            my $title = $pl->{title};

                            my $icon = 'plugins/yandex/html/images/personal.png';
                            if ($pl->{cover} && $pl->{cover}->{uri}) {
                                $icon = "https://" . $pl->{cover}->{uri};
                                $icon =~ s/%%/200x200/;
                            }

                            push @items, {
                                name => $title,
                                type => 'playlist',
                                url  => \&_handlePlaylist,
                                passthrough => [$yandex_client, $uid, $kind],
                                image => $icon,
                                play => "yandexmusic://playlist/$uid/$kind",
                            };
                        }
                    }
                }
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_SMART_PLAYLISTS'),
            });
        },
        sub {
            my $error = shift;
            $cb->([{ name => "Error: $error", type => 'text' }]);
        }
    );
}

sub _handlePicks {
    my ($client, $cb, $args, $yandex_client, $category) = @_;

    $yandex_client->landing_mixes(
        sub {
            my $blocks = shift;
            my @discovered_tags;
            
            foreach my $block (@$blocks) {
                if ($block->{entities}) {
                    foreach my $entity (@{$block->{entities}}) {
                        if ($entity->{type} eq 'mix-link' && $entity->{data} && $entity->{data}->{url}) {
                            my $url = $entity->{data}->{url};
                            if ($url =~ /^\/tag\/([^\/]+)\/?$/) {
                                my $slug = $1;
                                my $title = $entity->{data}->{title} || $slug;
                                push @discovered_tags, { slug => $slug, title => $title };
                            }
                        }
                    }
                }
            }

            if (!$category) {
                my %active_categories;
                foreach my $t (@discovered_tags) {
                    my $cat = $TAG_SLUG_CATEGORY{$t->{slug}} || 'mood';
                    next if $cat eq 'seasonal';
                    $active_categories{$cat} = 1;
                }

                my @items;
                for my $cat (qw(mood activity era genres)) {
                    if ($active_categories{$cat}) {
                        push @items, {
                            name => _translate($client, $cat),
                            type => 'link',
                            url  => \&_handlePicks,
                            passthrough => [$yandex_client, $cat],
                            image => 'plugins/yandex/html/images/personal.png',
                        }
                    }
                }
                
                if (!@items) {
                    for my $cat (qw(mood activity era genres)) {
                         push @items, {
                            name => _translate($client, $cat),
                            type => 'link',
                            url  => \&_handlePicks,
                            passthrough => [$yandex_client, $cat],
                            image => 'plugins/yandex/html/images/personal.png',
                         }
                    }
                }

                return $cb->({ items => \@items, title => _translate($client, 'picks') });
            } 
            
            my @items;
            my %seen_slugs;
            foreach my $t (@discovered_tags) {
                my $slug = $t->{slug};
                my $cat = $TAG_SLUG_CATEGORY{$slug} || 'mood';
                if ($cat eq $category && !$seen_slugs{$slug}++) {
                    push @items, {
                        name => _translate($client, $slug),
                        type => 'link',
                        url  => \&_handleTagPlaylists,
                        passthrough => [$yandex_client, $slug],
                        image => 'plugins/yandex/html/images/personal.png',
                    };
                }
            }

            if (!@items) {
                foreach my $slug (keys %TAG_SLUG_CATEGORY) {
                    if ($TAG_SLUG_CATEGORY{$slug} eq $category) {
                        push @items, {
                            name => _translate($client, $slug),
                            type => 'link',
                            url  => \&_handleTagPlaylists,
                            passthrough => [$yandex_client, $slug],
                            image => 'plugins/yandex/html/images/personal.png',
                        };
                    }
                }
            }

            $cb->({ items => \@items, title => _translate($client, $category) });
        },
        sub {
            my $error = shift;
            $cb->([{ name => "Error loading mixes: $error", type => 'text' }]);
        }
    );
}

sub _handleMixes {
    my ($client, $cb, $args, $yandex_client) = @_;
    
    my @seasonal_tags = qw(winter spring summer autumn newyear);
    my @items;

    foreach my $tag (@seasonal_tags) {
        push @items, {
            name => _translate($client, $tag),
            type => 'link',
            url  => \&_handleTagPlaylists,
            passthrough => [$yandex_client, $tag],
            image => 'plugins/yandex/html/images/personal.png',
        };
    }

    $cb->({ items => \@items, title => _translate($client, 'mixes') });
}

sub _handleTagPlaylists {
    my ($client, $cb, $args, $yandex_client, $tag_id) = @_;

    $yandex_client->tags(
        $tag_id,
        sub {
            my $ids = shift;
            
            if (!@$ids) {
                return $cb->({ items => [{ name => "No playlists found for tag", type => 'text' }] });
            }

            my @playlist_uids;
            foreach my $id_obj (@$ids) {
                if ($id_obj->{uid} && $id_obj->{kind}) {
                    push @playlist_uids, $id_obj->{uid} . ":" . $id_obj->{kind};
                }
            }

            $yandex_client->playlists_list(
                \@playlist_uids,
                sub {
                    my $playlists = shift;
                    my @items;

                    foreach my $playlist (@$playlists) {
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
                            type => 'playlist',
                            url => \&_handlePlaylist,
                            passthrough => [$yandex_client, $playlist->{owner}->{uid}, $playlist->{kind}],
                            image => $icon,
                            play => 'yandexmusic://playlist/' . $playlist->{owner}->{uid} . '/' . $playlist->{kind},
                        };
                    }

                    $cb->({ items => \@items, title => _translate($client, $tag_id) });
                },
                sub {
                    my $err = shift;
                    $cb->([{ name => "Error fetching playlists: $err", type => 'text' }]);
                }
            );
        },
        sub {
            my $error = shift;
            $cb->([{ name => "Error fetching tags: $error", type => 'text' }]);
        }
    );
}

# Shared Rendering Function

sub _renderTrackList {
    my ($tracks, $cb, $title, $container_url, $params) = @_;

    my @items;
    
    foreach my $track_object (@$tracks) {
         my $track_title = $track_object->{title} // 'Unknown';
         my $artist_name = 'Unknown';
         if ($track_object->{artists} && ref $track_object->{artists} eq 'ARRAY' && @{$track_object->{artists}}) {
             $artist_name = $track_object->{artists}[0]->{name};
         }

         my $track_id = $track_object->{id};
         my $track_url = 'yandexmusic://' . $track_id;
         
         my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
         
         my $cover_uri;
         if ($track_object->{coverUri}) {
             $cover_uri = $track_object->{coverUri};
         } elsif ($track_object->{raw} && $track_object->{raw}->{coverUri}) {
             $cover_uri = $track_object->{raw}->{coverUri};
         } elsif ($track_object->{ogImage}) {
             $cover_uri = $track_object->{ogImage};
         } elsif ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && $track_object->{albums}[0]->{coverUri}) {
             $cover_uri = $track_object->{albums}[0]->{coverUri};
         }
         
         if ($cover_uri) {
             $icon = $cover_uri;
             $icon =~ s/%%/200x200/;
             $icon = "https://$icon";
         }

         my $duration_ms = $track_object->{durationMs} || $track_object->{duration_ms} || ($track_object->{raw} ? $track_object->{raw}->{durationMs} : 0);

         my $album_name = 'Unknown';
         if ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}}) {
             $album_name = $track_object->{albums}[0]->{title};
         }

         my $line2 = $artist_name;
         $line2 .= " \x{2022} " . $album_name if $album_name && $album_name ne 'Unknown';

         push @items, {
            name      => $artist_name . ' - ' . $track_title,
            line1     => $track_title,
            line2     => $line2,
            type      => 'audio',
            url       => $track_url,
            image     => $icon,
            duration  => $duration_ms ? int($duration_ms / 1000) : undef,
            playall   => 1,
            on_select => 'play',
            play      => $track_url,
         };

         cache_track_metadata($track_object);
    }

    my $result = {
        items => \@items,
        title => $title,
    };
    
    if ($params) {
        $result->{offset} = $params->{offset} if defined $params->{offset};
        $result->{total}  = $params->{total} if defined $params->{total};
    }

    $cb->($result);
}

sub cache_track_metadata {
    my ($track_object) = @_;
    my $track_id = $track_object->{id};
    return unless $track_id;

    my $track_title = $track_object->{title} // 'Unknown';
    my $artist_name = 'Unknown';
    if ($track_object->{artists} && ref $track_object->{artists} eq 'ARRAY' && @{$track_object->{artists}}) {
        $artist_name = $track_object->{artists}[0]->{name};
    }

    my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
    my $cover_uri;
    if ($track_object->{coverUri}) {
        $cover_uri = $track_object->{coverUri};
    } elsif ($track_object->{raw} && $track_object->{raw}->{coverUri}) {
        $cover_uri = $track_object->{raw}->{coverUri};
    } elsif ($track_object->{ogImage}) {
        $cover_uri = $track_object->{ogImage};
    } elsif ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}} && $track_object->{albums}[0]->{coverUri}) {
        $cover_uri = $track_object->{albums}[0]->{coverUri};
    }
    
    if ($cover_uri) {
        $icon = $cover_uri;
        $icon =~ s/%%/200x200/;
        $icon = "https://$icon";
    }

    my $duration_ms = $track_object->{durationMs} || $track_object->{duration_ms} || ($track_object->{raw} ? $track_object->{raw}->{durationMs} : 0);

    my $album_name = 'Unknown';
    if ($track_object->{albums} && ref $track_object->{albums} eq 'ARRAY' && @{$track_object->{albums}}) {
        $album_name = $track_object->{albums}[0]->{title};
    }

    my $cache = Slim::Utils::Cache->new();
    $cache->set('yandex_meta_' . $track_id, {
        title    => $track_title,
        artist   => $artist_name,
        album    => $album_name,
        duration => $duration_ms ? int($duration_ms / 1000) : 0,
        cover    => $icon,
        bitrate  => 192,
    }, '24h');
}

1;
