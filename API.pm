package Plugins::yandex::API;

use strict;
use warnings;
use URI;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;
use POSIX qw(mkfifo);


my $log = logger('plugin.yandex');

my $HAS_RIJNDAEL;

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

    $http->get($uri, %{$self->{default_headers}});
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

sub rotor_session_new {
    my ($self, $station_id, $settings, $queue, $callback, $error_callback) = @_;
    my $url = 'https://api.music.yandex.net/rotor/session/new';

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
    my ($self, $query, $type, $callback, $error_callback, $page, $page_size) = @_;
    my $url = 'https://api.music.yandex.net/search';
    my $params = {
        'text' => $query,
        'type' => $type, 
        'page' => $page || 0,
        'nocorrect' => 'false'
    };

    $params->{'page-size'} = $page_size if defined $page_size;

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

# Get direct stream URL via /get-file-info (supports lossless/FLAC).
# Key and signing format from https://github.com/MarshalX/yandex-music-api/issues/656
# Calls $cb->($url, $error, $codec, $bitrate_kbps)
sub check_dependencies {
    return {
        rijndael => _has_rijndael(),
        ffmpeg   => !!_find_ffmpeg(),
    };
}

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

    my $url = 'https://api.music.yandex.net/get-file-info'
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
            my $bitrate = ($bitrate_kbps || 0) * 1000;

            unless ($aes_key) {
                # Unencrypted stream – use directly
                $cb->($url, undef, $bitrate, $codec, undef);
                return;
            }

            # Encrypted stream: pick decryption method
            if (_has_rijndael()) {
                # Tier 1: Real-time protocol-level decryption via ProtocolHandler._sysread()
                # For flac-mp4: LMS pipes decrypted MP4 to ffmpeg via stdin (custom-convert.conf rule)
                # For plain flac: ProtocolHandler returns plain FLAC bytes
                $log->info("YANDEX FLAC: Rijndael available - streaming decryption for codec=$codec");
                $cb->($url, undef, $bitrate, $codec, $aes_key);
            } elsif (my $openssl = _find_openssl()) {
                # Tier 2: download encrypted file, decrypt with openssl, return file:// URL
                # Backup for systems without Crypt::Rijndael
                $log->info("YANDEX FLAC: Using openssl for decryption (codec=$codec)");
                $self->_decrypt_flac_via_openssl($url, $aes_key, $openssl, $codec, sub {
                    my ($file_url, $err) = @_;
                    if ($file_url) {
                        $cb->($file_url, undef, $bitrate, $codec, undef);
                    } else {
                        $log->warn("YANDEX FLAC: openssl decryption failed ($err), falling back to MP3");
                        $self->_get_track_mp3_url($track_id, 320, $cb);
                    }
                });
            } else {
                # Tier 3: no decryption available
                $log->warn("YANDEX FLAC: No decryption available (install libcrypt-rijndael-perl or openssl), falling back to MP3 320");
                $self->_get_track_mp3_url($track_id, 320, $cb);
            }
        });
        return;
    }

    $self->_get_track_mp3_url($track_id, $max_bitrate, $cb);
}

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
            $log->info("YANDEX: Crypt::Rijndael available - streaming FLAC decryption enabled");
        } else {
            $log->warn("YANDEX: Crypt::Rijndael NOT available - will try openssl fallback for FLAC");
        }
    }
    return $HAS_RIJNDAEL;
}

sub _find_openssl {
    for my $path ('/usr/bin/openssl', '/usr/local/bin/openssl', '/opt/homebrew/bin/openssl', '/opt/local/bin/openssl') {
        return $path if -x $path;
    }
    if ($^O eq 'MSWin32') {
        for my $dir (split /;/, $ENV{PATH} || '') {
            my $p = "$dir\\openssl.exe";
            return $p if -e $p;
        }
    }
    return undef;
}

# Download encrypted FLAC to temp file, decrypt with openssl, demux if needed, return file:// URL
sub _decrypt_flac_via_openssl {
    my ($self, $enc_url, $hex_key, $openssl, $codec, $cb) = @_;

    require File::Temp;
    my $tmpdir = $ENV{TMPDIR} || $ENV{TEMP} || '/tmp';

    # Create output FIFO (named pipe) for streaming
    my ($out_fh, $out_file) = File::Temp::tempfile('yandex_flac_XXXXXX', SUFFIX => '.flac', DIR => $tmpdir);
    close($out_fh);
    unlink($out_file);  # Remove temp file, we'll create FIFO in its place

    # Create FIFO on Unix-like systems
    if ($^O ne 'MSWin32') {
        if (!POSIX::mkfifo($out_file, 0600)) {
            $cb->(undef, "mkfifo failed: $!");
            return;
        }
    } else {
        # Windows: use regular temp file (pipeline not as efficient but still works)
        # Can be improved with Named Pipes if needed
        $log->warn("YANDEX FLAC: Using temp file on Windows instead of FIFO (slower)");
    }

    # Build pipeline command: curl | openssl | ffmpeg (if flac-mp4)
    my $pipeline_cmd;
    my $curl = _find_curl();

    # Escape shell special characters
    my $safe_url = quotemeta($enc_url);
    my $safe_out = quotemeta($out_file);

    if ($codec eq 'flac-mp4') {
        # curl encrypted_stream | openssl decrypt | ffmpeg demux MP4→FLAC > FIFO
        my $ffmpeg = _find_ffmpeg();
        unless ($ffmpeg && $curl) {
            unlink($out_file);
            $cb->(undef, "curl or ffmpeg not found");
            return;
        }
        $pipeline_cmd = "$curl -s $safe_url 2>/dev/null | $openssl enc -aes-128-ctr -d -K $hex_key -iv " . ('0' x 32) . " -nosalt 2>/dev/null | $ffmpeg -loglevel quiet -i - -f flac $safe_out 2>&1";
    } else {
        # curl encrypted_stream | openssl decrypt > FIFO (plain FLAC)
        unless ($curl) {
            unlink($out_file);
            $cb->(undef, "curl not found");
            return;
        }
        $pipeline_cmd = "$curl -s $safe_url 2>/dev/null | $openssl enc -aes-128-ctr -d -K $hex_key -iv " . ('0' x 32) . " -nosalt > $safe_out 2>&1";
    }

    # Run pipeline in background
    $log->info("YANDEX FLAC: Starting streaming pipeline for $codec: $pipeline_cmd");
    system("($pipeline_cmd) > /dev/null 2>&1 &");

    # Wait for FIFO to be opened/readable (max 3 seconds)
    my $wait_count = 0;
    while (!-e $out_file && $wait_count < 30) {
        select(undef, undef, undef, 0.1);  # Sleep 100ms
        $wait_count++;
    }

    unless (-e $out_file) {
        $log->warn("YANDEX FLAC: FIFO not created: $out_file");
        $cb->(undef, "Failed to create streaming FIFO");
        return;
    }

    $log->info("YANDEX FLAC: Streaming to $out_file via pipeline");
    $cb->('file://' . $out_file, undef);
}

# Download encrypted flac-mp4, decrypt with Rijndael in-memory, demux FLAC, return file:// URL

# AES-128-CTR decryption using Rijndael in ECB mode (keystream XOR)
sub _aes_ctr_decrypt {
    use bytes;
    my ($cipher, $data) = @_;
    my $len = length($data);
    my $out = '';
    my $i   = 0;
    while ($i < $len) {
        my $blk_num  = int($i / 16);
        my $blk_off  = $i % 16;
        my $counter  = "\x00" x 12 . pack('N', $blk_num);
        my $keystream = $cipher->encrypt($counter);
        my $take      = 16 - $blk_off;
        $take = $len - $i if $len - $i < $take;
        $out .= substr($data, $i, $take) ^ substr($keystream, $blk_off, $take);
        $i   += $take;
    }
    return $out;
}

# Run ffmpeg to extract raw FLAC from a decrypted FLAC-in-MP4 file, then call $cb
sub _demux_flac_mp4 {
    my ($m4a_file, $cb) = @_;

    my $ffmpeg = _find_ffmpeg();
    unless ($ffmpeg) {
        $log->warn("YANDEX FLAC: ffmpeg not found, serving m4a as-is (may not play)");
        $cb->('file://' . $m4a_file, undef);
        return;
    }

    (my $flac_file = $m4a_file) =~ s/\.[^.]+$/.flac/;
    my $ret = system($ffmpeg, '-y', '-i', $m4a_file,
                     '-vn', '-acodec', 'copy', '-f', 'flac', $flac_file);
    unlink($m4a_file);
    if ($ret != 0 || !-f $flac_file) {
        unlink($flac_file) if -f $flac_file;
        $cb->(undef, "ffmpeg demux failed with exit " . ($ret >> 8));
        return;
    }
    $log->info("YANDEX FLAC: Demuxed flac-mp4 -> $flac_file");
    $cb->('file://' . $flac_file, undef);
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

sub _find_curl {
    for my $path ('/usr/bin/curl', '/usr/local/bin/curl', '/opt/homebrew/bin/curl', '/opt/local/bin/curl') {
        return $path if -x $path;
    }
    if ($^O eq 'MSWin32') {
        for my $dir (split /;/, $ENV{PATH} || '') {
            my $p = "$dir\\curl.exe";
            return $p if -e $p;
        }
    }
    return undef;
}

sub album {
    my ($self, $album_id, $callback, $error_callback) = @_;

    $self->albums([$album_id], sub {
        my $albums = shift;
        if ($albums && @$albums) {
            $callback->($albums->[0]);
        } else {
            $error_callback->("Album not found");
        }
    }, $error_callback);
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
