package Plugins::yandex::Plugin;

use strict;
use utf8;
use vars qw(@ISA);
use File::Basename;
use Cwd 'abs_path';
use File::Spec;
use feature qw(fc);
use Data::Dumper;
use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Player::Song;
use base qw(Slim::Plugin::OPMLBased);
use URI::Escape;
use URI::Escape qw(uri_escape_utf8);
use Encode qw(encode decode);
use Encode::Guess;
use Slim::Player::ProtocolHandlers;
use warnings;
use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use utf8;
use URI::Escape;
use URI::Escape qw(uri_escape_utf8);
use Encode::Guess;
use Plugins::yandex::ClientAsync;

my $log;
$log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.yandex',
    'defaultLevel' => 'DEBUG',
    'description'  => string('PLUGIN_YANDEX'),
});


use constant MAX_RECENT => 10;
my $prefs = preferences('plugin.yandex');
# Добавляем переменную для хранения экземпляра клиента
my $yandex_client_instance;


sub initPlugin {
    my $class = shift;

    $prefs->init({
        token => '',
        max_bitrate => 320,
    });


    # Регистрация протокола
    $log->error("YANDEX INIT: Registering ProtocolHandler...");
    Slim::Player::ProtocolHandlers->registerHandler('yandexmusic', 'Plugins::yandex::ProtocolHandler');

    # Подписка на события плеера (newsong, jump, stop, clear) для отслеживания пропусков
    Slim::Control::Request::subscribe(
        \&playerEventCallback,
        [['playlist'], ['newsong', 'jump', 'stop', 'clear']]
    );

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'yandex',
        menu   => 'apps',
        weight => 50,
    );

    if (main::WEBUI) {
        require Plugins::yandex::Settings;
        Plugins::yandex::Settings->new();
    }
}

sub shutdownPlugin {
    my $class = shift;
    Slim::Control::Request::unsubscribe(\&playerEventCallback);
}

# Обработчик событий плеера для отправки обратной связи о пропуске трека (skip)
sub playerEventCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    if ($client->isSynced()) {
        return unless Slim::Player::Sync::isMaster($client);
    }

    my $command = $request->getRequest(1);

    if ($command eq 'newsong') {
        # Запоминаем время начала трека
        $client->pluginData('yandex_track_start_time', time());
    }
    elsif ($command eq 'jump' || $command eq 'stop' || $command eq 'clear') {
        _handleSkipCheck($client, $command);
    }
}

sub _handleSkipCheck {
    my ($client, $command) = @_;
    
    my $song = $client->playingSong();
    return unless $song;

    my $url = $song->track()->url;
    
    # Проверяем, играет ли станция Яндекс Радио
    if ($url && $url =~ /rotor_station=([^&]+)&batch_id=([^&]+)/) {
        my $station = URI::Escape::uri_unescape($1);
        my $batch_id = URI::Escape::uri_unescape($2);
        my $track_id = ($url =~ /yandexmusic:\/\/(\d+)/)[0];
        
        my $start_time = $client->pluginData('yandex_track_start_time');
        my $duration = $song->duration() || 0;
        
        # Получаем фактически проигранное время
        my $played_seconds = Slim::Player::Source::songTime($client);
        
        # Если played_seconds = 0 (например, при быстром переключении) 
        # или метод вернул undef (что бывает), пробуем рассчитать через start_time
        if (!$played_seconds && $start_time) {
            $played_seconds = time() - $start_time;
        }
        $played_seconds ||= 0;

        # Если трек проигран меньше чем на 90% и прошло хотя бы 2 секунды (чтобы не спамить при очень быстрых скипах)
        my $threshold = $duration > 0 ? $duration * 0.9 : 0;
        
        # Если проиграли меньше 90% трека, значит это skip
        if (($duration > 0 && $played_seconds < $threshold) || ($duration == 0 && $played_seconds > 2)) {
            my $yandex_client = Plugins::yandex::Plugin->getClient();
            if ($yandex_client && $track_id) {
                $log->info("YANDEX ROTOR: Track skipped! Sending 'skip' feedback. Played: $played_seconds s. Station: $station, batch: $batch_id, track: $track_id, trigger: $command");
                $yandex_client->rotor_station_feedback($station, 'skip', $batch_id, $track_id, $played_seconds, sub {}, sub {});
            }
        }
    }
}

sub getDisplayName { 'Yandex Music' }

sub handleFeed {
    my ($client, $cb, $args) = @_;
    
    my $token = $prefs->get('token');
    #$log->info("handleFeed: token: $token");
    unless ($token) {
        $log->error("Токен не установлен. Проверьте настройки плагина.");
        $cb->([{
            name => 'Ошибка: токен не установлен',
            type => 'text',
        }]);
        return;
    }

    my $yandex_client = Plugins::yandex::ClientAsync->new($token);
    #$log->info("yandex_client created: yandex_client token: $token");

    $yandex_client->init(
        sub {
            #my $client_async = shift;
            $yandex_client_instance = shift;

            my @items = (
                {
                    name => 'My Collection',
                    type => 'link',
                    url  => \&_handleFavorites,
                    passthrough => [$yandex_client_instance],
                    image => 'plugins/yandex/html/images/favorites.png',
                },
                {
                    name => 'My Vibe',
                    type => 'playlist',
                    url  => 'yandexmusic://rotor/user:onyourwave',
                    play => 'yandexmusic://rotor/user:onyourwave',
                    on_select => 'play',
                    image => 'plugins/yandex/html/images/radio.png',
                },
                {
                    name => 'Search',
                    type => 'link',
                    url  => \&_handleRecentSearches,
                    passthrough => [$yandex_client_instance],
                    image => 'html/images/search.png',
                },
            );

            $cb->(\@items);
        },
        sub {
            my $error = shift;
            $log->error("Initialization error: $error");
            $cb->([{
                name => "Error: $error",
                type => 'text',
            }]);
        },
    );
}
sub _renderTrackList {
    my ($tracks, $cb, $title, $container_url) = @_;

    my @items;
    
    # if ($container_url && @$tracks > 1) {
    #     push @items, {
    #         name => 'Play All',
    #         type => 'link',
    #         url  => $container_url,
    #         play => $container_url,
    #         on_select => 'play',
    #         image => 'html/images/playall.png',
    #     };
    # }
    foreach my $track_object (@$tracks) {
         my $track_title = $track_object->{title} // 'Unknown';
         # Handle nested 'artists' array or simple object
         my $artist_name = 'Unknown';
         if ($track_object->{artists} && ref $track_object->{artists} eq 'ARRAY' && @{$track_object->{artists}}) {
             $artist_name = $track_object->{artists}[0]->{name};
         }

         my $track_id = $track_object->{id};
         # If track object is wrapped (e.g. inside 'track' key), unwrap it?
         # The API inconsistency is annoying. Let's assume we pass clean track objects here.
         
         my $track_url = 'yandexmusic://' . $track_id;
         
         my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
         
         # Try to find coverUri in various places
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

         push @items, {
            name      => $artist_name . ' - ' . $track_title,
            type      => 'audio',
            url       => $track_url,
            image     => $icon,
            duration  => $duration_ms ? int($duration_ms / 1000) : undef,
            playall   => 1,
            on_select => 'play',
            play      => $track_url,
         };

         # Cache metadata for ProtocolHandler
         cache_track_metadata($track_object);
    }

    $cb->({
        items => \@items,
        title => $title,
    });
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

    my $cache = Slim::Utils::Cache->new();
    $cache->set('yandex_meta_' . $track_id, {
        title    => $track_title,
        artist   => $artist_name,
        duration => $duration_ms ? int($duration_ms / 1000) : 0,
        cover    => $icon,
        bitrate  => 192,
    }, '24h');
}

sub _handleLikedTracks {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->users_likes_tracks(
        sub {
            my $tracks_short = shift; # Array of TrackShort objects
            
            # Extract IDs
            my @track_ids = map { $_->{id} } @$tracks_short;
            my $total_tracks = scalar @track_ids;

            if ($total_tracks == 0) {
                # Empty list
                 _renderTrackList([], $cb, 'Favorite tracks');
                return;
            }

            my @all_tracks_detailed;
            my $chunk_size = 50; 
            my @chunks;
            
            # Split into chunks
            while (@track_ids) {
                push @chunks, [ splice(@track_ids, 0, $chunk_size) ];
            }
            
            my $pending_chunks = scalar @chunks;

            foreach my $chunk_ids (@chunks) {
                $yandex_client->tracks(
                    $chunk_ids,
                    sub {
                        my $tracks_chunk = shift; # Array of Track objects
                        push @all_tracks_detailed, @$tracks_chunk;
                        
                        $pending_chunks--;
                         if ($pending_chunks == 0) {
                              _renderTrackList(\@all_tracks_detailed, $cb, 'Favorite tracks', 'yandexmusic://favorites/tracks');
                         }
                    },
                    sub {
                        my $error = shift;
                        $log->error("Error fetching tracks chunk: $error");
                        $pending_chunks--;
                         if ($pending_chunks == 0) {
                              _renderTrackList(\@all_tracks_detailed, $cb, 'Favorite tracks (Partial)', 'yandexmusic://favorites/tracks');
                         }
                    }
                );
            }
        },
        sub {
            my $error = shift;
            $log->error("Error retrieving favorite tracks list: $error");
            $cb->({
                items => [{
                    name => "Error: $error",
                    type => 'text',
                }],
                title => 'Favorite tracks',
            });
        },
    );
}

#  метод для доступа к клиенту из других модулей
sub getClient {
    return $yandex_client_instance;
}
sub _handleFavorites {
    my ($client, $cb, $args, $yandex_client) = @_;

    my @items = (
        {
            name => 'Tracks',
            type => 'playlist',
            url  => \&_handleLikedTracks,
            passthrough => [$yandex_client],
            image => 'html/images/musicfolder.png',
            play => 'yandexmusic://favorites/tracks',
        },
        {
            name => 'Albums',
            type => 'link',
            url  => \&_handleLikedAlbums,
            passthrough => [$yandex_client],
            image => 'html/images/albums.png',
        },
    );

    # Check if we should show Audiobooks & Podcasts
    my $has_podcasts = $prefs->get('yandex_has_podcasts');
    if (!defined $has_podcasts) {
        # Default to showing it until we know for sure, 
        # but trigger a background fetch to update the pref for next time.
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
            sub {} # ignore errors in background
        );
    }

    if ($has_podcasts) {
        push @items, {
            name => 'Audiobooks & Podcasts',
            type => 'link',
            url  => \&_handleLikedPodcasts,
            passthrough => [$yandex_client],
            # Use Spotty podcast icon or a fallback
            image => 'plugins/yandex/html/images/podcast.png',
        };
    }

    push @items, (
        {
            name => 'Artists',
            type => 'link',
            url  => \&_handleLikedArtists,
            passthrough => [$yandex_client],
            image => 'html/images/artists.png',
        },
        {
            name => 'Playlists',
            type => 'link',
            url  => \&_handleLikedPlaylists,
            passthrough => [$yandex_client],
            image => 'html/images/playlists.png',
        }
    );

    $cb->({
        items => \@items,
        title => 'My Collection',
    });
}

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
                    name => 'Tracks',
                    type => 'link',
                    url  => \&_handleSearchTracks,
                    passthrough => [$yandex_client, $query],
                    image => 'html/images/musicfolder.png',
                };
            }

            if ($result->{albums} && $result->{albums}->{results} && @{$result->{albums}->{results}}) {
                push @items, {
                    name => 'Albums',
                    type => 'link',
                    url  => \&_handleSearchAlbums,
                    passthrough => [$yandex_client, $query],
                    image => 'html/images/albums.png',
                };
            }

            if ($result->{artists} && $result->{artists}->{results} && @{$result->{artists}->{results}}) {
                push @items, {
                    name => 'Artists',
                    type => 'link',
                    url  => \&_handleSearchArtists,
                    passthrough => [$yandex_client, $query],
                    image => 'html/images/artists.png',
                };
            }

            if ($result->{playlists} && $result->{playlists}->{results} && @{$result->{playlists}->{results}}) {
                push @items, {
                    name => 'Playlists',
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
                title => "Search: $query"
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
                        type => 'playlist',
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

sub _handleLikedAlbums {
    my ($client, $cb, $args, $yandex_client) = @_;

    $yandex_client->users_likes_albums(
        sub {
            my $albums = shift;
            my @items;
            my $has_podcasts = 0;

            foreach my $album (@$albums) {
                if ($album->{type} =~ /podcast|audiobook/i || ($album->{metaType} && $album->{metaType} =~ /podcast|audiobook/i)) {
                    $has_podcasts = 1;
                    next; # Skip podcasts/audiobooks from Albums view
                }

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

            # Update preference
            $prefs->set('yandex_has_podcasts', $has_podcasts);

            $cb->({
                items => \@items,
                title => 'Favorite Albums',
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
                # Only include podcasts and audiobooks
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

    $yandex_client->users_likes_artists(
        sub {
            my $artists = shift;
            my @items;

            foreach my $artist (@$artists) {
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

    # 1. Fetch Liked Playlists
    $yandex_client->users_likes_playlists(
        sub {
            my $liked_playlists = shift;

            # 2. Fetch User's Own Playlists
            $yandex_client->users_playlists_list(
                sub {
                    my $user_playlists = shift;
                    
                    # 3. Merge lists
                    my @all_playlists = (@$liked_playlists, @$user_playlists);
                    my @items;
                    my %seen_ids;

                    foreach my $playlist (@all_playlists) {
                        # Dedup based on kind and uid
                        my $uid = $playlist->{owner}->{uid};
                        my $kind = $playlist->{kind};
                        next if $seen_ids{"$uid:$kind"}++;

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
                            passthrough => [$yandex_client, $uid, $kind],
                            image => $icon,
                            play => 'yandexmusic://playlist/' . $uid . '/' . $kind,
                        };
                    }

                    $cb->({
                        items => \@items,
                        title => 'Playlists',
                    });
                },
                sub {
                    my $error = shift;
                    $log->error("Error fetching user playlists: $error");
                    # If user playlists fail, at least show liked ones
                    my @items;
                     foreach my $playlist (@$liked_playlists) {
                        my $title = $playlist->{title} // 'Unknown Playlist';
                        my $owner = $playlist->{owner}->{name} // 'Unknown User';
                         my $icon = 'plugins/yandex/html/images/foundbroadcast1_svg.png';
                         if ($playlist->{cover}->{uri}) {
                            $icon = "https://" . $playlist->{cover}->{uri};
                            $icon =~ s/%%/200x200/;
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
                    $cb->({
                        items => \@items,
                         title => 'Playlists (Partial)',
                    });
                }
            );
        },
        sub {
            my $error = shift;
            $cb->({
                items => [{ name => "Error: $error", type => 'text' }],
                title => 'Favorite Playlists',
            });
        }
    );
}

sub _handleAlbum {
    my ($client, $cb, $args, $yandex_client, $album_id) = @_;

    $yandex_client->get_album_with_tracks(
        $album_id,
        sub {
            my $album = shift;
            my $tracks = $album->{volumes} ? [ map { @$_ } @{$album->{volumes}} ] : [];
            
            # The 'volumes' is array of arrays (discs).  Flatten it.
            # Also, tracks inside might need processing if structure differs, 
            # but usually 'with-tracks' returns full track objects.
            
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
            # Playlist tracks structure: array of objects like { id => ..., albumId => ..., track => { ... } }
            # We need to extract the inner 'track' object.
            
            my @tracks;
            foreach my $item (@$tracks_container) {
                if ($item->{track}) {
                    push @tracks, $item->{track};
                } else {
                    # Fallback if track object is direct? Unlikely for playlist detail.
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

sub _handleMyVibe {
    my ($client, $cb, $args, $yandex_client) = @_;

    # Use 'queue' from args if available (for pagination)
    my $queue = $args->{queue};

    $yandex_client->rotor_station_tracks(
        'user:ON_AIR',
        $queue,
        sub {
            my $result = shift;
            my $tracks = $result->{tracks};
            my $batch_id = $result->{batch_id};
            
            # Render the track list
            # For infinite scroll/pagination, we need to pass a 'next' item or handle it via callback
            # But Slim::Plugin::OPMLBased usually handles a single list. 
            # To support "next batch", we can append a special item at the end "Load more..."
            # OR we can just return the list and rely on the user to re-click "My Vibe"? No that resets it.
            # A common pattern for "infinite" lists in LMS plugins is to just return a moderate number of tracks (e.g. 50).
            # If we want a true infinite stream, we might need a different approach (e.g. Custom protocol handler for the station itself).
            # For now, let's just return the batch of tracks. 
            # But wait, if we play them, we want the *next* batch to play automatically.
            # This requires strict playlist management which is hard in OPMLBased.
            # Let's start by just rendering the batch.
            # Crucially, we MUST fix the callback to use $result->{tracks} instead of $result directly.
            
            # To allow "More", let's add a "Next Batch" item at the end.
            
             my $items = [];
             
             # Use the helper to get track items
             # We can't use _renderTrackList directly because we want to modify the list
             # implementation of _renderTrackList uses $cb->({ items => ... }) which finalizes the response.
             # We should probably modify _renderTrackList to return items if $cb is not passed?
             # Or just inline the logic for now or wrap the callback.
             
             # Let's wrap the callback to append the "Next" button
             my $wrapped_cb = sub {
                 my $response = shift;
                 my $items = $response->{items} // [];
                 
                 if (@$items && $tracks->[-1]) {
                     my $last_track_id = $tracks->[-1]->{id};
                     push @$items, {
                         name => "Next Batch...",
                         type => 'link',
                         url => \&_handleMyVibe,
                         passthrough => [$yandex_client],
                         args => { queue => $last_track_id },
                         image => 'plugins/yandex/html/images/wave.png',
                     };
                 }
                 
                 $cb->($response);
             };

             _renderTrackList($tracks, $wrapped_cb, 'My Vibe');
        },
        sub {
            my $error = shift;
            $cb->({ items => [{ name => "Error: $error", type => 'text' }] });
        }
    );
}

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

    # Если мы пришли сюда для очистки истории
    if ($extra_args && $extra_args->{clear_history}) {
        clearRecentSearches();
        # После очистки просто показываем обновленное меню
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

1;
