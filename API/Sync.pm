package Plugins::yandex::API::Sync;

use strict;
use warnings;
use utf8;

use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use URI;
use URI::Escape qw(uri_escape_utf8);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

my $lastRequestTime = 0;
my $minRequestInterval = 0.2;  # 200ms between requests to avoid rate limiting

# Synchronous HTTP GET with caching for scanner process
sub _get {
    my ($class, $path, $uid, $params) = @_;

    my $accounts = $prefs->get('accounts') || {};
    my $account = $accounts->{$uid} || return;
    my $token = $account->{token} || return;

    my $url = 'https://api.music.yandex.net' . $path;
    my $uri = URI->new($url);
    $uri->query_form($params) if $params;

    my $headers = {
        'User-Agent' => 'Yandex-Music-API',
        'X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621',
        'Accept-Language' => 'ru',
        'Content-Type' => 'application/json',
        'Authorization' => "OAuth " . $token,
    };

    main::INFOLOG && $log->is_info && $log->info("Sync GET: $uri");

    # Rate limiting: avoid hitting Yandex API too fast
    my $now = time();
    if ($lastRequestTime && ($now - $lastRequestTime) < $minRequestInterval) {
        my $sleepTime = $minRequestInterval - ($now - $lastRequestTime);
        select(undef, undef, undef, $sleepTime);
    }
    $lastRequestTime = time();

    my $response = Slim::Networking::SimpleSyncHTTP->new({
        timeout => 15,
    })->get($uri, %{$headers});

    if ($response && $response->code == 200) {
        my $content = $response->content;
        my $result = eval { decode_json($content) };

        if ($@) {
            $log->error("Failed to decode JSON: $@");
            return;
        }

        main::DEBUGLOG && $log->is_debug && $log->debug("Sync response: " . substr($content, 0, 200));
        return $result;
    } else {
        my $code = $response ? $response->code : 'no response';
        my $content = $response ? $response->content : '';
        $log->error("Sync request failed for $url: $code. Body: " . substr($content || '', 0, 500));
        return;
    }
}

# Get list of liked albums with full details (rich=true)
sub users_likes_albums {
    my ($class, $uid) = @_;

    my $result = $class->_get("/users/$uid/likes/albums", $uid, { rich => 'true' });

    my @albums;
    if ($result && ref $result eq 'HASH' && exists $result->{result}) {
        foreach my $item (@{$result->{result} || []}) {
            if ($item->{album}) {
                push @albums, $item->{album};
            }
        }
    }

    return \@albums;
}

# Get complete album with all tracks in volumes structure
sub get_album_with_tracks {
    my ($class, $album_id, $uid) = @_;

    my $result = $class->_get("/albums/$album_id/with-tracks", $uid);

    if ($result && ref $result eq 'HASH' && exists $result->{result}) {
        return $result->{result};
    }

    return;
}

# Get list of liked artists
sub users_likes_artists {
    my ($class, $uid) = @_;

    my $result = $class->_get("/users/$uid/likes/artists", $uid);

    my @artists;
    if ($result && ref $result eq 'HASH' && exists $result->{result}) {
        foreach my $item (@{$result->{result} || []}) {
            push @artists, $item;
        }
    }

    return \@artists;
}

# Get artist brief info (includes cover_uri)
sub get_artist {
    my ($class, $artist_id, $uid) = @_;

    my $result = $class->_get("/artists/$artist_id/brief-info", $uid);

    if ($result && ref $result eq 'HASH' && exists $result->{result}) {
        return $result->{result};
    }

    return;
}

# Get list of liked playlists
sub users_likes_playlists {
    my ($class, $uid) = @_;

    my $result = $class->_get("/users/$uid/likes/playlists", $uid);

    my @playlists;
    if ($result && ref $result eq 'HASH' && exists $result->{result}) {
        foreach my $item (@{$result->{result} || []}) {
            if ($item->{playlist}) {
                push @playlists, $item->{playlist};
            }
        }
    }

    return \@playlists;
}

# Get user's own playlists
sub users_playlists_list {
    my ($class, $uid) = @_;

    my $result = $class->_get("/users/$uid/playlists/list", $uid);

    my @playlists;
    if ($result && ref $result eq 'HASH' && exists $result->{result}) {
        @playlists = @{$result->{result} || []};
    }

    return \@playlists;
}

# Get tracks for a specific playlist
sub get_playlist_tracks {
    my ($class, $uid, $playlist_uid, $kind) = @_;

    my $path = "/users/$playlist_uid/playlists/$kind";
    my $result = $class->_get($path, $uid);

    my @tracks;
    if ($result && ref $result eq 'HASH' && exists $result->{result}) {
        my $playlist_result = $result->{result};
        if ($playlist_result && exists $playlist_result->{tracks}) {
            @tracks = @{$playlist_result->{tracks} || []};
        }
    }

    return \@tracks;
}

# Fetch full track data by IDs
sub tracks {
    my ($class, $track_ids, $uid) = @_;

    my @ids = ref $track_ids eq 'ARRAY' ? @$track_ids : ($track_ids);
    return [] unless @ids;

    my $accounts = $prefs->get('accounts') || {};
    my $account = $accounts->{$uid} || return [];
    my $token = $account->{token} || return [];

    my $url = 'https://api.music.yandex.net/tracks/';

    my $body = 'track-ids=' . join(',', @ids) . '&with-positions=true';

    my $headers = {
        'User-Agent' => 'Yandex-Music-API',
        'X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621',
        'Accept-Language' => 'ru',
        'Content-Type' => 'application/x-www-form-urlencoded',
        'Authorization' => "OAuth " . $token,
    };

    main::INFOLOG && $log->is_info && $log->info("Sync POST: $url (tracks: " . scalar(@ids) . ")");

    # Rate limiting: avoid hitting Yandex API too fast
    my $now = time();
    if ($lastRequestTime && ($now - $lastRequestTime) < $minRequestInterval) {
        my $sleepTime = $minRequestInterval - ($now - $lastRequestTime);
        select(undef, undef, undef, $sleepTime);
    }
    $lastRequestTime = time();

    my $response = Slim::Networking::SimpleSyncHTTP->new({
        timeout => 15,
    })->post($url, %{$headers}, $body);

    my @tracks;
    if ($response && $response->code == 200) {
        my $content = $response->content;
        my $result = eval { decode_json($content) };

        if ($@) {
            $log->error("Failed to decode JSON: $@");
            return [];
        }

        if (ref $result eq 'HASH' && exists $result->{result}) {
            @tracks = @{$result->{result} || []};
        }
    } else {
        $log->error("Sync POST failed for $url: " . ($response ? $response->code : 'no response'));
    }

    return \@tracks;
}

1;
