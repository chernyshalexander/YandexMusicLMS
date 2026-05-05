package Plugins::yandex::API::Async;

=encoding utf8

=head1 NAME

Plugins::yandex::API::Async - Async Yandex Music API client

=head1 DESCRIPTION

Thin async HTTP wrapper around the Yandex Music API (api.music.yandex.net).
All methods are non-blocking: they accept a success callback and an error
callback, both called from the LMS event loop.

Authentication uses OAuth tokens passed in the C<Authorization: OAuth> header
with a spoofed C<X-Yandex-Music-Client: YandexMusicAndroid/...> header — the
Android client identity is required to access the C<encraw> transport for
lossless streams (the Desktop identity returns HTTP 403).

Stream resolution entry point: C<get_track_direct_url()>.

=cut

use strict;
use warnings;
use URI;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;
use Plugins::yandex::API::Common;
use Slim::Utils::Cache;
use Digest::MD5 qw(md5_hex);

my $log = logger('plugin.yandex');
my $cache = Slim::Utils::Cache->new();

use constant SEARCH_TTL => 3600;
use constant LONG_TTL   => 86400;

# Cached result of Crypt::Rijndael availability check (undef = not yet tested).
my $HAS_RIJNDAEL;

# Return an AES-128 ECB cipher object for $key_bytes (16 raw bytes).
# Respects the aes_backend preference: auto | rijndael | internal.
sub make_aes_cipher {
    my ($key_bytes) = @_;
    my $backend = Slim::Utils::Prefs::preferences('plugin.yandex')->get('aes_backend') || 'rijndael';
    if ($backend ne 'internal' && _has_rijndael()) {
        require Crypt::Rijndael;
        return Crypt::Rijndael->new($key_bytes, Crypt::Rijndael::MODE_ECB());
    }
    if ($backend ne 'internal' && !_has_rijndael()) {
        $log->warn("YANDEX: aes_backend=$backend but Crypt::Rijndael not installed - using internal AES128");
    }
    require Plugins::yandex::Decode::AES128;
    return Plugins::yandex::Decode::AES128->new($key_bytes);
}

sub new {
    my ($class, $token, %args) = @_;

    my $self = {
        token => $token,
        proxy_url => $args{proxy_url},
        me => undef,
        default_headers => Plugins::yandex::API::Common::get_default_headers($token),
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
            $log->info("Yandex API (GET): success. code=[" . ($http->code || '200') . "] length=[" . length($content) . "] url=[" . $uri->as_string . "]");
            my $json = eval { decode_json($content) };
            if ($@ || !defined $json) {
                $log->error("Yandex API (GET): JSON decode failed: $@. Content snippet: " . substr($content, 0, 100));
                $error_callback->($@ || "Failed to decode JSON response");
            } else {
                $callback->($json);
            }
        },
        sub {
            my ($http, $error) = @_;
            $log->error("Yandex API (GET): HTTP error: $error. code=[" . ($http->code || '') . "] url=[" . $uri->as_string . "]");
            $error_callback->($error);
        },
    );

    $log->info("Yandex API: Requesting GET " . $uri->as_string);
    $http->get($uri, %{$self->{default_headers}});
}

sub _cached_get {
    my ($self, $cache_key, $ttl, $url, $params, $callback, $error_callback) = @_;

    if (my $cached = $cache->get($cache_key)) {
        main::DEBUGLOG && $log->is_debug && $log->debug("Cache hit: $cache_key");
        $callback->($cached);
        return;
    }

    $self->get(
        $url,
        $params,
        sub {
            my $result = shift;
            if (ref $result eq 'HASH' && exists $result->{result}) {
                my $data = $result->{result};
                $cache->set($cache_key, $data, $ttl);
                $callback->($data);
            } else {
                my $err_msg = ref $result eq '' ? $result : "API request failed";
                $error_callback->($err_msg);
            }
        },
        $error_callback,
    );
}

sub post {
    my ($self, $url, $data, $callback, $error_callback) = @_;

    my $http = $self->_create_http_object(
        sub {
            my $http = shift;
            my $content = $http->content();
            my $json = eval { decode_json($content) };
            if ($@ || !defined $json) {
                $error_callback->($@ || "Failed to decode JSON response");
            } else {
                $callback->($json);
            }
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
            if ($@ || !defined $json) {
                $error_callback->($@ || "Failed to decode JSON response");
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
        Plugins::yandex::API::Common::BASE_URL . '/account/status',
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

sub like_track {
    my ($self, $track_id, $callback, $error_callback) = @_;
    my $uid = $self->get_me->{uid};
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $uid . '/likes/tracks/add?track-id=' . uri_escape_utf8($track_id);
    $self->post($url, {}, sub { $callback->() }, $error_callback);
}

sub dislike_track {
    my ($self, $track_id, $callback, $error_callback) = @_;
    my $uid = $self->get_me->{uid};
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $uid . '/dislikes/tracks/add?track-id=' . uri_escape_utf8($track_id);
    $self->post($url, {}, sub { $callback->() }, $error_callback);
}

sub users_likes_tracks {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $self->get_me->{uid} . '/likes/tracks/';
    my $cacheKey = 'yandex_likes_tracks_' . $self->get_me->{uid};

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        my @track_short_objects;
        if (exists $result->{library} && exists $result->{library}->{tracks}) {
            foreach my $item (@{$result->{library}->{tracks}}) {
                push @track_short_objects, {
                    id => $item->{id},
                    track_id => $item->{id},
                    album_id => $item->{albumId},
                    timestamp => $item->{timestamp},
                };
            }
        }
        $callback->(\@track_short_objects);
    }, $error_callback);
}

sub users_likes_albums {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $self->get_me->{uid} . '/likes/albums';
    my $params = { rich => 'true' };
    my $cacheKey = 'yandex_likes_albums_' . $self->get_me->{uid};

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, $params, sub {
        my $result = shift;
        my @albums;
        foreach my $item (@$result) {
            if ($item->{album}) { push @albums, $item->{album}; }
        }
        $callback->(\@albums);
    }, $error_callback);
}

sub users_likes_artists {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $self->get_me->{uid} . '/likes/artists';
    my $cacheKey = 'yandex_likes_artists_' . $self->get_me->{uid};

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        my @artists;
        foreach my $item (@$result) {
            push @artists, $item;
        }
        $callback->(\@artists);
    }, $error_callback);
}

sub users_likes_playlists {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $self->get_me->{uid} . '/likes/playlists';
    my $cacheKey = 'yandex_likes_playlists_' . $self->get_me->{uid};

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        my @playlists;
        foreach my $item (@$result) {
            if ($item->{playlist}) { push @playlists, $item->{playlist}; }
        }
        $callback->(\@playlists);
    }, $error_callback);
sub users_playlists_list {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $self->get_me->{uid} . '/playlists/list';
    my $cacheKey = 'yandex_my_playlists_' . $self->get_me->{uid};

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, $callback, $error_callback);
}

sub tracks {
    my ($self, $track_ids, $callback, $error_callback) = @_;
    my @ids = ref $track_ids eq 'ARRAY' ? @$track_ids : ($track_ids);
    my $url = Plugins::yandex::API::Common::BASE_URL . '/tracks/'; 

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
    my $url = Plugins::yandex::API::Common::BASE_URL . '/albums/' . $album_id . '/with-tracks';
    my $cacheKey = 'yandex_album_tracks_' . $album_id;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, $callback, $error_callback);
}

sub get_artist_tracks {
    my ($self, $artist_id, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/artists/' . $artist_id . '/tracks';
    my $params = { 'page-size' => 100 };
    my $cacheKey = 'yandex_artist_tracks_' . $artist_id;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, $params, $callback, $error_callback);
}

sub get_artist_albums {
    my ($self, $artist_id, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/artists/' . $artist_id . '/direct-albums';
    my $params = { 'page-size' => 100, 'sort-by' => 'year' };
    my $cacheKey = 'yandex_artist_albums_' . $artist_id;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, $params, $callback, $error_callback);
}

sub get_similar_artists {
   my ($self, $artist_id, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/artists/' . $artist_id . '/similar';
    my $cacheKey = 'yandex_artist_similar_' . $artist_id;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        if (exists $result->{similarArtists}) {
            $callback->($result->{similarArtists});
        } else {
            $callback->([]);
        }
    }, $error_callback);
}

sub get_artist_also_albums {
    my ($self, $artist_id, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/artists/' . $artist_id . '/also-albums';
    my $params = { 'page-size' => 100, 'sort-by' => 'year' };
    my $cacheKey = 'yandex_artist_also_' . $artist_id;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, $params, sub {
        my $result = shift;
        if (exists $result->{albums}) {
            $callback->($result->{albums});
        } else {
            $callback->([]);
        }
    }, $error_callback);
}

sub get_playlist {
    my ($self, $user_id, $kind, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/users/' . $user_id . '/playlists/' . $kind;
    my $cacheKey = "yandex_playlist_${user_id}_${kind}";
    
    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        if (exists $result->{result}) {
            $callback->($result->{result});
        } else {
            $error_callback->("Failed to get playlist");
        }
    }, $error_callback);
}

sub rotor_station_info {
    my ($self, $station, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/rotor/station/' . $station . '/info';
    my $cacheKey = 'yandex_station_info_' . $station;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, undef, sub {
        my $result = shift;
        if (exists $result->{result}) {
            $callback->($result->{result});
        } else {
            $error_callback->("Failed to get station info");
        }
    }, $error_callback);
}

sub rotor_session_new {
    my ($self, $station_id, $settings, $queue, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/rotor/session/new';

    my @seeds = ($station_id);
    push @seeds, 'settingDiversity:'  . $settings->{diversity}  if $settings && $settings->{diversity};
    push @seeds, 'settingMoodEnergy:' . $settings->{moodEnergy} if $settings && $settings->{moodEnergy};
    push @seeds, 'settingLanguage:'   . $settings->{language}   if $settings && $settings->{language};

    my $data = {
        'seeds'                   => \@seeds,
        'queue'                   => $queue || [],
        'includeTracksInResponse' => \1,
        'includeWaveModel'        => \1,
        'interactive'             => \1,
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
    my $url = Plugins::yandex::API::Common::BASE_URL . '/rotor/session/' . uri_escape_utf8($radio_session_id) . '/feedback';
    
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
    my $url = Plugins::yandex::API::Common::BASE_URL . '/rotor/session/' . uri_escape_utf8($radio_session_id) . '/tracks';
    
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
    my ($self, $query, $type, $callback, $error_callback, $page, $page_size) = @_;

    my $cacheKey = 'yandex_search_' . lc($type || 'all') . '_' . md5_hex(lc($query)) . '_p' . ($page || 0);
    my $url = Plugins::yandex::API::Common::BASE_URL . '/search';
    my $params = {
        'text' => $query,
        'type' => $type,
        'page' => $page || 0,
        'nocorrect' => 'true'
    };

    $params->{'page-size'} = $page_size if defined $page_size;

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, $params, $callback, $error_callback);
}

sub rotor_stations_list {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/rotor/stations/list';
    my $cacheKey = 'yandex_rotor_stations';

    $self->_cached_get($cacheKey, LONG_TTL, $url, { language => 'any' }, $callback, $error_callback);
}

sub landing_mixes {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/landing3';
    my $params = { 'blocks' => 'mixes' };
    my $cacheKey = 'yandex_landing_mixes';

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, $params, sub {
        my $result = shift;
        if (exists $result->{result} && exists $result->{result}->{blocks}) {
            $callback->($result->{result}->{blocks});
        } else {
            $callback->([]);
        }
    }, $error_callback);
}

sub landing_personal_playlists {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/landing3';
    my $params = { 'blocks' => 'personal-playlists' };
    my $cacheKey = 'yandex_landing_personal';

    $self->_cached_get($cacheKey, SEARCH_TTL, $url, $params, sub {
        my $result = shift;
        if (exists $result->{blocks}) {
            $callback->($result->{blocks});
        } else {
            $callback->([]);
        }
    }, $error_callback);
}

sub get_chart {
    my ($self, $chart_option, $callback, $error_callback) = @_;

    my $url = Plugins::yandex::API::Common::BASE_URL . '/landing3/chart';
    if ($chart_option) {
        $url .= '/' . $chart_option;
    }
    my $cacheKey = 'yandex_chart_' . ($chart_option || 'all');

    $self->_cached_get($cacheKey, LONG_TTL, $url, undef, sub {
        my $result = shift;
        if (exists $result->{chart}) {
            my $chart = $result->{chart};
            my $tracks = $chart->{tracks} // [];
            $callback->($tracks);
        } else {
            $callback->([]);
        }
    }, $error_callback);
}

sub get_new_releases {
    my ($self, $callback, $error_callback) = @_;

    my $url = Plugins::yandex::API::Common::BASE_URL . '/landing3/new-releases';
    my $cacheKey = 'yandex_new_releases';

    $self->_cached_get($cacheKey, LONG_TTL, $url, undef, sub {
        my $result = shift;
        if (exists $result->{newReleases}) {
            $callback->($result->{newReleases});
        } else {
            $callback->([]);
        }
    }, $error_callback);
}

sub get_new_playlists {
    my ($self, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/landing3/new-playlists';
    my $cacheKey = 'yandex_new_playlists';

    $self->_cached_get($cacheKey, LONG_TTL, $url, undef, sub {
        my $result = shift;
        if (exists $result->{newPlaylists}) {
            my $playlists = $result->{newPlaylists};
            my @playlist_data = map { { uid => $_->{uid}, kind => $_->{kind} } } @$playlists;
            $callback->(\@playlist_data);
        } else {
            $callback->([]);
        }
    }, $error_callback);
}

sub tags {
    my ($self, $tag_id, $callback, $error_callback) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . '/tags/' . $tag_id . '/playlist-ids';

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
    my $url = Plugins::yandex::API::Common::BASE_URL . '/playlists/list';
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

# Returns a hashref with keys 'rijndael' and 'ffmpeg' (boolean).
# Used by Plugin.pm and Settings.pm to show warnings about missing dependencies.
sub check_dependencies {
    return {
        rijndael => _has_rijndael(),
        ffmpeg   => !!_find_ffmpeg(),
    };
}

# Resolve the direct CDN URL for a track via the /get-file-info endpoint.
# This endpoint supports lossless codecs (flac, flac-mp4, aac-mp4) and returns
# an AES-128 key when transport=encraw is used.
#
# Request signing: HMAC-SHA256 over "${ts}${trackId}lossless${codecs_nosep}encraw"
# with key 'p93jhgh689SBReK6ghtw62', base64-encoded, first 43 chars.
# Source: https://github.com/MarshalX/yandex-music-api/issues/656
#
# Calls $cb->($url, $error, $codec, $bitrate_kbps, $aes_key_hex).
sub get_track_file_info {
    my ($self, $track_id, $cb) = @_;

    require Digest::SHA;
    require MIME::Base64;

    my $sign_key  = 'p93jhgh689SBReK6ghtw62';
    my $codecs    = 'flac,flac-mp4,aac-mp4,aac,he-aac,mp3,he-aac-mp4';

    my $ts            = int(time());
    my $codecs_nosep  = $codecs;
    $codecs_nosep     =~ s/,//g;
    my $param_string  = "${ts}${track_id}lossless${codecs_nosep}encraw";
    my $hmac_bytes    = Digest::SHA::hmac_sha256($param_string, $sign_key);
    my $sign          = substr(MIME::Base64::encode_base64($hmac_bytes, ''), 0, 43);

    my $url = Plugins::yandex::API::Common::BASE_URL . '/get-file-info'
            . '?ts='         . $ts
            . '&trackId='    . $track_id
            . '&quality=lossless'
            . '&codecs='     . uri_escape_utf8($codecs)
            . '&transports=encraw'
            . '&sign='       . uri_escape_utf8($sign);

    # Android client header works for encraw (Desktop returns 403)
    my %headers = %{$self->{default_headers}};

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $json = eval { decode_json($http->content()) };
            if ($@ || !$json || !$json->{result}) {
                $cb->(undef, "Invalid response from get-file-info");
                return;
            }
            my $di = $json->{result}{downloadInfo};
            unless ($di && $di->{url}) {
                $cb->(undef, "No downloadInfo in get-file-info response");
                return;
            }
            # $di->{key} is a hex AES-128 key present when transport=encraw
            $cb->($di->{url}, undef, $di->{codec} || 'mp3', $di->{bitrate} || 0, $di->{key});
        },
        sub {
            my ($http, $error) = @_;
            $cb->(undef, $error);
        },
        { headers => \%headers },
    );

    $http->get($url, %headers);
}

sub get_track_download_info {
    my ($self, $track_id, $cb) = @_;
    my $url = Plugins::yandex::API::Common::BASE_URL . "/tracks/" . $track_id . "/download-info";

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

    my $max_bitrate = Slim::Utils::Prefs::preferences('plugin.yandex')->get('max_bitrate') || 320;

    # For FLAC: use /get-file-info with encraw transport
    if ($max_bitrate eq 'flac') {
        $self->get_track_file_info($track_id, sub {
            my ($url, $error, $codec, $bitrate_kbps, $aes_key) = @_;
            unless ($url) {
                $log->warn("YANDEX: get-file-info failed ($error), falling back to MP3");
                $self->_get_track_mp3_url($track_id, 320, $cb);
                return;
            }

            $log->info("YANDEX: get-file-info OK codec=$codec bitrate=$bitrate_kbps encrypted=" . ($aes_key ? 'yes' : 'no'));

            # Fallback to MP3 if codec requires FFmpeg and it's missing
            if ($codec =~ /-mp4$/) {
                my $needs_fallback = 0;
                my $demux = Slim::Utils::Prefs::preferences('plugin.yandex')->get('demux_backend') || 'ffmpeg';
                
                # Both flac-mp4 and aac-mp4 are supported by the internal pure-Perl demuxer.
                if ($demux eq 'ffmpeg' && !_find_ffmpeg()) {
                    $needs_fallback = 1;
                }

                if ($needs_fallback) {
                    $log->warn("YANDEX: High-quality codec=$codec requires FFmpeg but it's missing, falling back to MP3");
                    $self->_get_track_mp3_url($track_id, 320, $cb);
                    return;
                }
            }

            my $bitrate = ($bitrate_kbps || 0) * 1000;

            unless ($aes_key) {
                # Unencrypted stream – use directly
                $cb->($url, undef, $bitrate, $codec, undef);
                return;
            }

            # Encrypted stream: AES backend is always available (Rijndael or internal pure-Perl)
            my $backend = Slim::Utils::Prefs::preferences('plugin.yandex')->get('aes_backend') || 'auto';
            $log->info("YANDEX FLAC: Streaming decryption for codec=$codec (aes_backend=$backend)");
            $cb->($url, undef, $bitrate, $codec, $aes_key);
        });
        return;
    }

    $self->_get_track_mp3_url($track_id, $max_bitrate, $cb);
}

# Resolve a plain MP3 (or legacy FLAC) CDN URL via the /download-info endpoint.
# Two-step process:
#   1. GET /tracks/{id}/download-info → list of codec/bitrate entries with downloadInfoUrl
#   2. GET downloadInfoUrl?format=json → JSON (or legacy XML) with {host, path, ts, s}
#      Final URL: https://{host}/get-{codec}/{sign}/{ts}{path}
#      where sign = MD5("XGRlBW9FXlekgbPrRHuSiA" + path[1:] + s)
# The CDN may redirect; we do one HEAD to resolve any redirect before returning.
sub _get_track_mp3_url {
    my ($self, $track_id, $max_bitrate, $cb) = @_;

    $self->get_track_download_info($track_id, sub {
        my ($info, $error) = @_;

        if ($error || !$info || !$info->{result}) {
            $cb->(undef, "No download info: " . ($error || 'unknown'));
            return;
        }

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

        my $codec = $target_info->{codec} || 'mp3';
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

                # URL prefix depends on codec: get-mp3, get-flac, get-flac-mp4, etc.
                my $url_prefix = 'get-' . $codec;
                my $initial_direct_url = "https://$data->{host}/$url_prefix/$sign/$data->{ts}$data->{path}";

                my $bitrate = ($codec eq 'flac' || $codec eq 'flac-mp4')
                    ? 0
                    : ($target_info->{bitrateInKbps} || 0) * 1000;

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
                                $cb->($location, undef, $bitrate, $codec);
                                return;
                            }
                        }
                        $cb->($initial_direct_url, undef, $bitrate, $codec);
                    },
                    sub {
                        my ($http, $error) = @_;
                        $cb->($initial_direct_url, undef, $bitrate, $codec);
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

sub _has_rijndael {
    unless (defined $HAS_RIJNDAEL) {
        eval { require Crypt::Rijndael; $HAS_RIJNDAEL = 1 };
        $HAS_RIJNDAEL = 0 unless $HAS_RIJNDAEL;
        if ($HAS_RIJNDAEL) {
            $log->info("YANDEX: Crypt::Rijndael available");
        } else {
            $log->info("YANDEX: Crypt::Rijndael not available - internal AES128 will be used");
        }
    }
    return $HAS_RIJNDAEL;
}

sub _find_ffmpeg {
    my @search_dirs;

    if ($^O eq 'MSWin32') {
        push @search_dirs, 'C:\\ffmpeg\\bin', 'C:\\Program Files\\ffmpeg\\bin',
                           'C:\\FFmpeg\\bin', 'C:\\Program Files\\FFmpeg\\bin',
                           'C:\\ffmpeg', 'C:\\tools\\ffmpeg\\bin';
        push @search_dirs, split /;/, ($ENV{PATH} || '');
    } else {
        push @search_dirs, '/usr/bin', '/usr/local/bin', '/opt/homebrew/bin', '/opt/local/bin';
        push @search_dirs, split /:/, ($ENV{PATH} || '');
    }

    my $ffmpeg_name = ($^O eq 'MSWin32') ? 'ffmpeg.exe' : 'ffmpeg';

    for my $dir (@search_dirs) {
        next unless $dir && -d $dir;
        my $p = ($^O eq 'MSWin32') ? "$dir\\$ffmpeg_name" : "$dir/$ffmpeg_name";
        if (-e $p || ($^O ne 'MSWin32' && -x $p)) {
            return $p;
        }
    }
    return undef;
}

sub albums {
    my ($self, $album_ids, $callback, $error_callback) = @_;

    return unless $album_ids && @$album_ids;

    my $url = Plugins::yandex::API::Common::BASE_URL . '/albums';
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
