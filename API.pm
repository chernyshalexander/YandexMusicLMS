package Plugins::yandex::API;

use strict;
use warnings;
use URI;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;


my $log = logger('plugin.yandex');

sub new {
    my ($class, $token, %args) = @_;

    my $self = {
        token => $token,
        proxy_url => $args{proxy_url},
        me => undef,
        default_headers => {
            'User-Agent' => 'Yandex-Music-API',
            'X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621',
            'Accept-Language' => 'ru',
            'Content-Type' => 'application/json',
            'Authorization' => "OAuth " . $token,
        },
    };

    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------------------
# CORE HTTP TRANSPORT METHODS (Ported from RequestAsync.pm)
# -----------------------------------------------------------------------------------------
sub _create_http_object {
    my ($self, $callback, $error_callback) = @_;

    my $params = {
        headers => $self->{default_headers},
    };

    return Slim::Networking::SimpleAsyncHTTP->new(
        $callback,
        $error_callback,
        $params,
    );
}

sub get {
    my ($self, $url, $params, $callback, $error_callback) = @_;

    my $uri = URI->new($url);
    $uri->query_form($params) if $params;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            my $content = $http->content();
            my $json = eval { decode_json($content) };
            $callback->($json);
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    $http->get($uri, %{$self->{default_headers}});
}

sub post {
    my ($self, $url, $data, $callback, $error_callback) = @_;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            my $content = $http->content();
            my $json = eval { decode_json($content) };
            $callback->($json);
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    $http->post(
        $url, %{$self->{default_headers}},       
        encode_json($data),
    );
}

sub post_form {
    my ($self, $url, $data, $callback, $error_callback) = @_;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            my $content = $http->content();
            my $json = eval { decode_json($content) };
            if ($@) {
                $callback->($content); 
            } else {
                $callback->($json);
            }
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    my %headers = %{$self->{default_headers}};
    $headers{'Content-Type'} = 'application/x-www-form-urlencoded';
    
    my @parts;
    foreach my $key (keys %$data) {
        my $val = $data->{$key};
        if (ref $val eq 'ARRAY') {
            foreach my $v (@$val) {
                 push @parts, uri_escape_utf8($key) . '=' . uri_escape_utf8($v);
            }
        } else {
            push @parts, uri_escape_utf8($key) . '=' . uri_escape_utf8($val);
        }
    }
    my $body = join('&', @parts);

    $http->post(
        $url, %headers,       
        $body,
    );
}

sub get_raw {
    my ($self, $url, $params, $callback, $error_callback) = @_;

    my $uri = URI->new($url);
    $uri->query_form($params) if $params;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            $callback->($http->content());
        },
        sub {
            my ($http, $error) = @_;
            $error_callback->($error);
        },
    );

    $http->get($uri, %{$self->{default_headers}});
}

# -----------------------------------------------------------------------------------------
# ENDPOINT WRAPPERS (Ported from ClientAsync.pm)
# -----------------------------------------------------------------------------------------

sub init {
    my ($self, $callback, $error_callback) = @_;
    $self->get(
        'https://api.music.yandex.net/account/status',
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{account}) {
                $self->{me} = $result->{result}->{account};
                $log->info("Yandex API: account status retrieved successfully.");
                $callback->($self);
            } else {
                $log->error("Yandex API: Failed to get user data");
                $error_callback->("Failed to get user data");
            }
        },
        $error_callback,
    );
}

sub get_me {
    my ($self) = @_;
    return $self->{me};
}

sub users_likes_tracks {
    my ($self, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/tracks/';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            my @track_short_objects;
            if (exists $result->{result} && exists $result->{result}->{library} && exists $result->{result}->{library}->{tracks}) {
                foreach my $item (@{$result->{result}->{library}->{tracks}}) {
                    push @track_short_objects, {
                        id => $item->{id},
                        track_id => $item->{id},
                        album_id => $item->{albumId},
                        timestamp => $item->{timestamp},
                    };
                }
            }
            $callback->(\@track_short_objects);
        },
        $error_callback,
    );
}

sub users_likes_albums {
    my ($self, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/albums';
    my $params = { rich => 'true' };

    $self->get(
        $url,
        $params,
        sub {
            my $result = shift;
            my @albums;
            if (exists $result->{result}) {
               foreach my $item (@{$result->{result}}) {
                   if ($item->{album}) { push @albums, $item->{album}; }
               }
            }
            $callback->(\@albums);
        },
        $error_callback,
    );
}

sub users_likes_artists {
    my ($self, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/artists';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            my @artists;
             if (exists $result->{result}) {
               foreach my $item (@{$result->{result}}) {
                   push @artists, $item;
               }
            }
            $callback->(\@artists);
        },
        $error_callback,
    );
}

sub users_likes_playlists {
    my ($self, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/likes/playlists';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            my @playlists;
             if (exists $result->{result}) {
               foreach my $item (@{$result->{result}}) {
                   if ($item->{playlist}) { push @playlists, $item->{playlist}; }
               }
            }
            $callback->(\@playlists);
        },
        $error_callback,
    );
}

sub users_playlists_list {
    my ($self, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/users/' . $self->get_me->{uid} . '/playlists/list';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            my @playlists;
            if (exists $result->{result}) {
                @playlists = @{$result->{result}};
            }
            $callback->(\@playlists);
        },
        $error_callback,
    );
}

sub tracks {
    my ($self, $track_ids, $callback, $error_callback) = @_;
    my @ids = ref $track_ids eq 'ARRAY' ? @$track_ids : ($track_ids);
    my $url = 'https://api.music.yandex.net/tracks/'; 

    my $data = {
        'track-ids' => \@ids,
        'with-positions' => 'true',
    };

    $self->post_form(
        $url,
        $data,
        sub {
            my $result = shift;
            my @tracks;
            my $list = $result;
            if (ref $result eq 'HASH' && exists $result->{result}) {
                $list = $result->{result};
            }

            if (ref $list eq 'ARRAY') {
                $callback->($list);
            } else {
                 $log->error("API tracks: unexpected result format");
                 $error_callback->("Unexpected result format from tracks endpoint");
            }
        },
        $error_callback,
    );
}

sub get_album_with_tracks {
    my ($self, $album_id, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/albums/' . $album_id . '/with-tracks';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result}) {
                $callback->($result->{result});
            } else {
                $error_callback->("Failed to get album with tracks");
            }
        },
        $error_callback,
    );
}

sub get_artist_tracks {
    my ($self, $artist_id, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/artists/' . $artist_id . '/tracks';
    my $params = { 'page-size' => 100 };

    $self->get(
        $url,
        $params,
        sub {
            my $result = shift;
             if (exists $result->{result} && exists $result->{result}->{tracks}) {
                $callback->($result->{result}->{tracks});
            } else {
                $error_callback->("Failed to get artist tracks");
            }
        },
        $error_callback,
    );
}

sub get_artist_albums {
    my ($self, $artist_id, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/artists/' . $artist_id . '/direct-albums';
    my $params = { 'page-size' => 100, 'sort-by' => 'year' };

    $self->get(
        $url,
        $params,
        sub {
            my $result = shift;
             if (exists $result->{result} && exists $result->{result}->{albums}) {
                $callback->($result->{result}->{albums});
            } else {
                $error_callback->("Failed to get artist albums");
            }
        },
        $error_callback,
    );
}

sub get_playlist {
    my ($self, $user_id, $kind, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/users/' . $user_id . '/playlists/' . $kind;
    
    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result}) {
                $callback->($result->{result});
            } else {
                $error_callback->("Failed to get playlist");
            }
        },
        $error_callback,
    );
}

sub rotor_station_tracks {
    my ($self, $station_id, $queue, $callback, $error_callback, $extra_params) = @_;
    my $url = 'https://api.music.yandex.net/rotor/station/' . $station_id . '/tracks';
    my $params = { 'settings2' => 'true' };
    
    if ($queue) { $params->{queue} = $queue; }
    if ($extra_params && ref $extra_params eq 'HASH') {
        foreach my $key (keys %$extra_params) { $params->{$key} = $extra_params->{$key}; }
    }

    $self->get(
        $url,
        $params,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{sequence}) {
                my @tracks;
                foreach my $item (@{$result->{result}->{sequence}}) {
                    next unless $item->{track};
                    push @tracks, $item->{track};
                }
                my $batch_id = $result->{result}->{batchId};
                $callback->({ tracks => \@tracks, batch_id => $batch_id });
            } else {
                $error_callback->("Failed to get station tracks");
            }
        },
        $error_callback,
    );
}

sub rotor_station_info {
    my ($self, $station, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/rotor/station/' . $station . '/info';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result}) {
                $callback->($result->{result});
            } else {
                $error_callback->("Failed to get station info");
            }
        },
        $error_callback,
    );
}

sub rotor_station_feedback {
    my ($self, $station, $type, $batch_id, $track_id, $total_played_seconds, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/rotor/station/' . $station . '/feedback';

    if ($batch_id) {
        $url .= '?batch-id=' . uri_escape_utf8($batch_id);
    }

    my $data = {
        'type' => $type,
        'timestamp' => time(),
    };
    if (defined $track_id) { $data->{'trackId'} = $track_id; }
    if (defined $total_played_seconds) { $data->{'totalPlayedSeconds'} = $total_played_seconds; }

    $self->post_form(
        $url,
        $data,
        sub { $callback->(1); },
        $error_callback,
    );
}

sub rotor_session_new {
    my ($self, $station_id, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/rotor/session/new';
    
    my $data = {
        'seeds' => [$station_id],
        'includeTracksInResponse' => \1, 
    };

    $self->post(
        $url,
        $data,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{radioSessionId}) {
                $callback->($result->{result}); 
            } else {
                $error_callback->("Failed to create new rotor session for station $station_id");
            }
        },
        $error_callback,
    );
}

sub rotor_session_feedback {
    my ($self, $radio_session_id, $batch_id, $event_type, $track_id, $total_played_seconds, $timestamp, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/rotor/session/' . uri_escape_utf8($radio_session_id) . '/feedback';
    
    my $event = {
        'type' => $event_type,
        'timestamp' => $timestamp,
    };
    
    if ($event_type eq 'radioStarted') {
        if ($track_id) { $event->{'from'} = $track_id; }
    } else {
        $event->{'trackId'} = $track_id;
    }
    
    if (defined $total_played_seconds && ($event_type eq 'skip' || $event_type eq 'trackFinished')) {
        $event->{'totalPlayedSeconds'} = $total_played_seconds;
    }

    my $data = {
        'event' => $event,
        'batchId' => $batch_id,
    };

    $self->post(
        $url,
        $data,
        sub { $callback->(1); },
        $error_callback,
    );
}

sub rotor_session_tracks {
    my ($self, $radio_session_id, $current_track_id, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/rotor/session/' . uri_escape_utf8($radio_session_id) . '/tracks';
    
    my $data = {
        'queue' => [$current_track_id],
    };

    $self->post(
        $url,
        $data,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{sequence}) {
                my $tracks = [];
                push @$tracks, map { $_->{track} } @{$result->{result}->{sequence}};
                my $res_formatted = {
                    'tracks' => $tracks,
                    'batch_id' => $result->{result}->{batchId},
                };
                $callback->($res_formatted);
            } else {
                $error_callback->("Failed to get next tracks from server");
            }
        },
        $error_callback,
    );
}

sub search {
    my ($self, $query, $type, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/search';
    my $params = {
        'text' => $query,
        'type' => $type, 
        'page' => 0,
        'noclear' => 'false'
    };

    $self->get(
        $url,
        $params,
        sub {
            my $result = shift;
            if (ref $result eq 'HASH' && exists $result->{result}) {
                $callback->($result->{result});
            } else {
                my $err_msg = ref $result eq '' ? $result : "Search query failed";
                $error_callback->($err_msg);
            }
        },
        $error_callback,
    );
}

sub rotor_stations_list {
    my ($self, $callback, $error_callback) = @_;

    $self->get(
        'https://api.music.yandex.net/rotor/stations/list',
        { language => 'any' },
        sub {
            my $result = shift;
            if (exists $result->{result} && ref $result->{result} eq 'ARRAY') {
                $callback->($result->{result});
            } else {
                $error_callback->("Failed to get stations list");
            }
        },
        $error_callback,
    );
}

sub landing_mixes {
    my ($self, $callback, $error_callback) = @_;

    $self->get(
        'https://api.music.yandex.net/landing3',
        { 'blocks' => 'mixes' },
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{blocks}) {
                $callback->($result->{result}->{blocks});
            } else {
                $error_callback->("Failed to get landing mixes");
            }
        },
        $error_callback,
    );
}

sub landing_personal_playlists {
    my ($self, $callback, $error_callback) = @_;

    $self->get(
        'https://api.music.yandex.net/landing3',
        { 'blocks' => 'personal-playlists' },
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{blocks}) {
                $callback->($result->{result}->{blocks});
            } else {
                $error_callback->("Failed to get personal playlists");
            }
        },
        $error_callback,
    );
}

sub get_chart {
    my ($self, $chart_option, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/landing3/chart';
    if ($chart_option) {
        $url .= '/' . $chart_option;
    }

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{chart}) {
                my $chart = $result->{result}->{chart};
                my $tracks = $chart->{tracks} // [];
                $callback->($tracks);
            } else {
                $error_callback->("Failed to get chart");
            }
        },
        $error_callback,
    );
}

sub get_new_releases {
    my ($self, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/landing3/new-releases';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{newReleases}) {
                my $releases = $result->{result}->{newReleases};
                $callback->($releases);
            } else {
                $error_callback->("Failed to get new releases");
            }
        },
        $error_callback,
    );
}

sub get_new_playlists {
    my ($self, $callback, $error_callback) = @_;

    my $url = 'https://api.music.yandex.net/landing3/new-playlists';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{newPlaylists}) {
                my $playlists = $result->{result}->{newPlaylists};
                my @playlist_data = map { { uid => $_->{uid}, kind => $_->{kind} } } @$playlists;
                $callback->(\@playlist_data);
            } else {
                $error_callback->("Failed to get new playlists");
            }
        },
        $error_callback,
    );
}

sub tags {
    my ($self, $tag_id, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/tags/' . $tag_id . '/playlist-ids';

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            if (exists $result->{result} && exists $result->{result}->{ids}) {
                $callback->($result->{result}->{ids});
            } else {
                $error_callback->("Failed to get tags for $tag_id");
            }
        },
        $error_callback,
    );
}

sub playlists_list {
    my ($self, $playlist_ids, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/playlists/list';
    my $data = { 'playlistIds' => join(',', @$playlist_ids) };

    $self->post_form(
        $url,
        $data,
        sub {
            my $result = shift;
            if (exists $result->{result}) {
                $callback->($result->{result});
            } else {
                $error_callback->("Failed to get playlists_list");
            }
        },
        $error_callback,
    );
}

# -----------------------------------------------------------------------------------------
# STREAM RESOLUTION
# -----------------------------------------------------------------------------------------

sub get_track_download_info {
    my ($self, $track_id, $cb) = @_;
    my $url = "https://api.music.yandex.net/tracks/" . $track_id . "/download-info";

    unless (defined $cb && ref($cb) eq 'CODE') {
         $log->error("Yandex API: get_track_download_info called without a valid callback!");
        return;
    }

    $self->get(
        $url,
        undef,
        sub {
            my $result = shift;
            $cb->($result);
        },
        sub {
            my $error_msg = shift;
            $cb->(undef, "HTTP request failed: $error_msg");
        }
    );
}

sub get_track_direct_url {
    my ($self, $track_id, $cb) = @_;

    $self->get_track_download_info($track_id, sub {
        my ($info, $error) = @_;

        if ($error || !$info || !$info->{result}) {
            $cb->(undef, "No download info: " . ($error || 'unknown'));
            return;
        }

        my $max_bitrate = Slim::Utils::Prefs::preferences('plugin.yandex')->get('max_bitrate') || 320;
        my $target_info;
        
        my @sorted_info = sort { $b->{bitrateInKbps} <=> $a->{bitrateInKbps} } 
                          grep { $_->{codec} eq 'mp3' } 
                          @{$info->{result}};

        foreach my $info_item (@sorted_info) {
            if ($info_item->{bitrateInKbps} <= $max_bitrate) {
                $target_info = $info_item;
                last;
            }
        }
        
        if (!$target_info && @sorted_info) {
            $target_info = $sorted_info[-1];
        }

        unless ($target_info && $target_info->{downloadInfoUrl}) {
            $cb->(undef, "No suitable MP3 stream found");
            return;
        }

        my $dw_url = $target_info->{downloadInfoUrl} . '&format=json';

        $self->get_raw(
            $dw_url,
            undef,
            sub {
                my $content = shift;
                my $data = eval { decode_json($content) };
                if ($@) {
                    my ($host, $path, $ts, $s) = $content =~ /host="([^"]+)"\s+path="([^"]+)"\s+ts="([^"]+)"\s+s="([^"]+)"/;
                    unless ($host && $path && $ts && $s) {
                        $cb->(undef, "Failed to parse response as JSON or XML");
                        return;
                    }
                    $data = { host => $host, path => $path, ts => $ts, s => $s };
                }
                
                require Digest::MD5;
                my $sign = Digest::MD5::md5_hex("XGRlBW9FXlekgbPrRHuSiA" . substr($data->{path}, 1) . $data->{s});
                my $initial_direct_url = "https://$data->{host}/get-mp3/$sign/$data->{ts}$data->{path}";
                
                my $http_resolver = Slim::Networking::SimpleAsyncHTTP->new(
                    sub {
                        my $http = shift;
                        my $code = $http->code || 200;
                        if ($code =~ /^30/) {
                            my $location;
                            if ($http->can('headers')) {
                                $location = $http->headers->header('Location');
                            }
                            elsif ($http->can('params') && $http->params && $http->params->{headers}) {
                                $location = $http->params->{headers}->{'Location'};
                            }
                            if ($location) {
                                $cb->($location, undef, $target_info->{bitrateInKbps} * 1000);
                                return;
                            }
                        }
                        $cb->($initial_direct_url, undef, $target_info->{bitrateInKbps} * 1000);
                    },
                    sub {
                        my ($http, $error) = @_;
                        $cb->($initial_direct_url, undef, $target_info->{bitrateInKbps} * 1000);
                    },
                    { maxRedirects => 0, timeout => 10, }
                );
                
                $http_resolver->head($initial_direct_url);
            },
            sub {
                my $error_msg = shift;
                $cb->(undef, "XML/JSON request failed: $error_msg");
            }
        );
    });
}

sub albums {
    my ($self, $album_ids, $callback, $error_callback) = @_;

    return unless $album_ids && @$album_ids;

    my $url = 'https://api.music.yandex.net/albums';
    my @ids = ref $album_ids eq 'ARRAY' ? @$album_ids : ($album_ids);

    my $data = {
        'album-ids' => \@ids,
    };

    $self->post_form(
        $url,
        $data,
        sub {
            my $result = shift;
            if (exists $result->{result}) {
                my $albums = $result->{result};
                $callback->($albums);
            } else {
                $error_callback->("Failed to get albums");
            }
        },
        $error_callback,
    );
}

1;
