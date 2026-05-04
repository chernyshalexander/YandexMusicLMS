package Plugins::yandex::Browse::Search;

# Search handlers: recent searches, per-type search results (tracks, albums,
# artists, playlists, podcasts). The "recent searches" screen shows a keyboard
# prompt; the actual search is dispatched to per-type handlers.

use strict;
use warnings;
use utf8;
use Encode qw(encode);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::yandex::Browse::Common;

my $log = logger('plugin.yandex');
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

sub handleRecentSearches {
    my ($client, $cb, $args, $yandex_client, $extra_args) = @_;

    if ($extra_args && $extra_args->{clear_history}) {
        clearRecentSearches();
    }

    my $items = [];

    push @$items, {
        name  => 'New Search',
        type  => 'search',
        url   => \&handleSearch,
        passthrough => [$yandex_client],
        image => 'html/images/search.png',
    };

    my $history = $prefs->get('yandex_recent_search') || [];
    for my $recent ( @$history ) {
        push @$items, {
            name  => $recent,
            type  => 'link',
            url   => \&handleSearch,
            passthrough => [$yandex_client, { query => $recent, recent => 1 }],
            image => 'plugins/yandex/html/images/history.png',
        };
    }

    if (@$history) {
        push @$items, {
            name => 'Clear Search History',
            type => 'link',
            url  => \&handleRecentSearches,
            passthrough => [$yandex_client, { clear_history => 1 }],
            image => 'plugins/yandex/html/images/icon_blank.png'
        };
    }

    $cb->({ items => $items, title => 'Search' });
}

# Search handlers

sub handleSearch {
    my ($client, $cb, $args, $yandex_client, $extra_args) = @_;

    my $query = $args->{search} || ($extra_args && $extra_args->{query}) || '';
    if (!$query) {
        $cb->({ items => [] });
        return;
    }

    addRecentSearch($query) unless ($extra_args && $extra_args->{recent});

    my $encoded_query = encode('utf8', $query);

    my $items = [];
    my $pending = 1;

    my $finish = sub {
        my $new_items = shift;
        push @$items, @$new_items if $new_items;
        $pending--;
        if ($pending == 0) {
            if (!@$items) {
                 push @$items, { name => 'No results found', type => 'text' };
            }
            $cb->({
                items => $items,
                title => cstring($client, 'PLUGIN_YANDEX_SEARCH') . ": $query"
            });
        }
    };

    if ($prefs->get('search_podcasts')) {
        $pending++;
        $yandex_client->search(
            $encoded_query,
            'podcast',
            sub {
                my $result = shift;

                if (!$result || ref $result ne 'HASH') {
                    $finish->();
                    return;
                }

                my @pod_items;
                if ($result->{podcasts} && $result->{podcasts}->{results} && @{$result->{podcasts}->{results}}) {
                    push @pod_items, {
                        name => cstring($client, 'PLUGIN_YANDEX_AUDIOBOOKS_PODCASTS'),
                        type => 'link',
                        url  => \&handleSearchPodcasts,
                        passthrough => [$yandex_client, { query => $query }],
                        image => 'plugins/yandex/html/images/podcast.png',
                    };
                }
                $finish->(\@pod_items);
            },
            sub { $finish->() },
            0, 1 # We only need to know if there's at least one result to show the category
        );
    }

    $yandex_client->search(
        $encoded_query,
        'all',
        sub {
            my $result = shift;

            if (!$result || ref $result ne 'HASH') {
                $finish->();
                return;
            }

            my @all_items;

            if ($result->{tracks} && $result->{tracks}->{results} && @{$result->{tracks}->{results}}) {
                push @all_items, {
                    name => cstring($client, 'PLUGIN_YANDEX_TRACKS'),
                    type => 'link',
                    url  => \&handleSearchTracks,
                    passthrough => [$yandex_client, { query => $query }],
                    image => 'html/images/musicfolder.png',
                };
            }

            if ($result->{albums} && $result->{albums}->{results} && @{$result->{albums}->{results}}) {
                push @all_items, {
                    name => cstring($client, 'PLUGIN_YANDEX_ALBUMS'),
                    type => 'link',
                    url  => \&handleSearchAlbums,
                    passthrough => [$yandex_client, { query => $query }],
                    image => 'html/images/albums.png',
                };
            }

            if ($result->{artists} && $result->{artists}->{results} && @{$result->{artists}->{results}}) {
                push @all_items, {
                    name => cstring($client, 'PLUGIN_YANDEX_ARTISTS'),
                    type => 'link',
                    url  => \&handleSearchArtists,
                    passthrough => [$yandex_client, { query => $query }],
                    image => 'html/images/artists.png',
                };
            }

            if ($result->{playlists} && $result->{playlists}->{results} && @{$result->{playlists}->{results}}) {
                push @all_items, {
                    name => cstring($client, 'PLUGIN_YANDEX_PLAYLISTS'),
                    type => 'link',
                    url  => \&handleSearchPlaylists,
                    passthrough => [$yandex_client, { query => $query }],
                    image => 'html/images/playlists.png',
                };
            }

            # Check for podcasts in 'all' too, just in case (and if not already added)
            if (!$prefs->get('search_podcasts') && $result->{podcasts} && $result->{podcasts}->{results} && @{$result->{podcasts}->{results}}) {
                push @all_items, {
                    name => cstring($client, 'PLUGIN_YANDEX_AUDIOBOOKS_PODCASTS'),
                    type => 'link',
                    url  => \&handleSearchPodcasts,
                    passthrough => [$yandex_client, { query => $query }],
                    image => 'plugins/yandex/html/images/podcast.png',
                };
            }

            $finish->(\@all_items);
        },
        sub {
            my $error = shift;
            $finish->([{ name => "Search Error: $error", type => 'text' }]);
        }
    );
}

sub handleSearchTracks {
    my ($client, $cb, $args, $yandex_client, $params) = @_;

    if (ref $yandex_client eq 'HASH' && !defined $params) {
        $params = $yandex_client;
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    my $query  = (ref $params eq 'HASH' ? $params->{query} : $params) || $args->{search} || '';
    return $cb->({ items => [] }) unless $yandex_client && $query;

    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 50;

    my $page = int($index / $quantity);

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'track',
        sub {
            my $result = shift;

            if (!$result || ref $result ne 'HASH') {
                $cb->({ items => [{ name => "Error: Invalid response format", type => 'text' }] });
                return;
            }

            my $tracks = [];
            my $total = 0;
            if ($result->{tracks} && $result->{tracks}->{results}) {
                $tracks = $result->{tracks}->{results};
                $total = $result->{tracks}->{total} || 0;
                $total = 200 if $total > 200;
            }
            Plugins::yandex::Browse::Common::renderTrackList($tracks, $cb, "Tracks: $query", undef, {
                offset => $page * $quantity,
                total  => $total,
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        $page,
        $quantity
    );
}

sub handleSearchAlbums {
    my ($client, $cb, $args, $yandex_client, $params) = @_;

    if (ref $yandex_client eq 'HASH' && !defined $params) {
        $params = $yandex_client;
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    my $query  = (ref $params eq 'HASH' ? $params->{query} : $params) || $args->{search} || '';
    return $cb->({ items => [] }) unless $yandex_client && $query;

    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 50;
    my $page = int($index / $quantity);

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'album',
        sub {
            my $result = shift;

            if (!$result || ref $result ne 'HASH') {
                $cb->({ items => [{ name => "Error: Invalid response format", type => 'text' }] });
                return;
            }

            my @items;
            my $total = 0;

            if ($result->{albums} && $result->{albums}->{results}) {
                $total = $result->{albums}->{total} || 0;
                $total = 200 if $total > 200;
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
                        url => \&Plugins::yandex::Browse::_handleAlbum,
                        passthrough => [{ id => $album->{id} }],
                        image => $icon,
                        play => 'yandexmusic://album/' . $album->{id},
                    };
                }
            }

            $cb->({
                items => \@items,
                title => "Albums: $query",
                offset => $page * $quantity,
                total => $total,
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        $page,
        $quantity
    );
}

sub handleSearchArtists {
    my ($client, $cb, $args, $yandex_client, $params) = @_;

    if (ref $yandex_client eq 'HASH' && !defined $params) {
        $params = $yandex_client;
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    my $query  = (ref $params eq 'HASH' ? $params->{query} : $params) || $args->{search} || '';
    return $cb->({ items => [] }) unless $yandex_client && $query;

    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 50;
    my $page = int($index / $quantity);

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'artist',
        sub {
            my $result = shift;

            if (!$result || ref $result ne 'HASH') {
                $cb->({ items => [{ name => "Error: Invalid response format", type => 'text' }] });
                return;
            }

            my @items;
            my $total = 0;

            if ($result->{artists} && $result->{artists}->{results}) {
                $total = $result->{artists}->{total} || 0;
                $total = 200 if $total > 200;
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
                        url => \&Plugins::yandex::Browse::_handleArtist,
                        passthrough => [{ id => $artist->{id} }],
                        image => $icon,
                    };
                }
            }

            $cb->({
                items => \@items,
                title => "Artists: $query",
                offset => $page * $quantity,
                total => $total,
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        $page,
        $quantity
    );
}

sub handleSearchPlaylists {
    my ($client, $cb, $args, $yandex_client, $params) = @_;

    if (ref $yandex_client eq 'HASH' && !defined $params) {
        $params = $yandex_client;
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    my $query  = (ref $params eq 'HASH' ? $params->{query} : $params) || $args->{search} || '';
    return $cb->({ items => [] }) unless $yandex_client && $query;

    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 50;
    my $page = int($index / $quantity);

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'playlist',
        sub {
            my $result = shift;

            if (!$result || ref $result ne 'HASH') {
                $cb->({ items => [{ name => "Error: Invalid response format", type => 'text' }] });
                return;
            }

            my @items;
            my $total = 0;

            if ($result->{playlists} && $result->{playlists}->{results}) {
                $total = $result->{playlists}->{total} || 0;
                $total = 200 if $total > 200;
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
                        url => \&Plugins::yandex::Browse::_handlePlaylist,
                        passthrough => [{ uid => $playlist->{owner}->{uid}, kind => $playlist->{kind} }],
                        image => $icon,
                        play => 'yandexmusic://playlist/' . $playlist->{owner}->{uid} . '/' . $playlist->{kind},
                    };
                }
            }

            $cb->({
                items => \@items,
                title => "Playlists: $query",
                offset => $page * $quantity,
                total => $total,
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        $page,
        $quantity
    );
}

sub handleSearchPodcasts {
    my ($client, $cb, $args, $yandex_client, $params) = @_;

    if (ref $yandex_client eq 'HASH' && !defined $params) {
        $params = $yandex_client;
        $yandex_client = undef;
    }
    $yandex_client ||= Plugins::yandex::Plugin::getAPIForClient($client);

    my $query  = (ref $params eq 'HASH' ? $params->{query} : $params) || $args->{search} || '';
    return $cb->({ items => [] }) unless $yandex_client && $query;

    my $index = $args->{index} || 0;
    my $quantity = $args->{quantity} || 50;
    my $page = int($index / $quantity);

    my $encoded_query = encode('utf8', $query);

    $yandex_client->search(
        $encoded_query,
        'podcast',
        sub {
            my $result = shift;

            if (!$result || ref $result ne 'HASH') {
                $cb->({ items => [{ name => "Error: Invalid response format", type => 'text' }] });
                return;
            }

            my @items;
            my $total = 0;

            if ($result->{podcasts} && $result->{podcasts}->{results}) {
                $total = $result->{podcasts}->{total} || 0;
                $total = 200 if $total > 200;
                foreach my $album (@{$result->{podcasts}->{results}}) {
                    my $title = $album->{title} // 'Unknown Podcast/Audiobook';
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
                        url => \&Plugins::yandex::Browse::_handleAlbum,
                        passthrough => [{ id => $album->{id} }],
                        image => $icon,
                        play => 'yandexmusic://album/' . $album->{id},
                    };
                }
            }

            $cb->({
                items => \@items,
                title => cstring($client, 'PLUGIN_YANDEX_AUDIOBOOKS_PODCASTS') . ": $query",
                offset => $page * $quantity,
                total => $total,
            });
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        },
        $page,
        $quantity
    );
}

1;
