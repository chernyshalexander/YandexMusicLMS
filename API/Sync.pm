package Plugins::yandex::API::Sync;

=encoding utf8

=head1 NAME

Plugins::yandex::API::Sync - Synchronous Yandex Music API client for library scanning

=head1 DESCRIPTION

Synchronous (blocking) HTTP wrapper around Yandex Music API endpoints.
Used by the library importer/scanner process to fetch user library data:
liked albums, artists, playlists, and track metadata.

All methods perform direct HTTP requests without callbacks.
Includes rate-limiting (200ms between requests) and caching to avoid
excessive API calls during library scans.

=head1 METHODS

Fetch operations (return data or empty list on error):

=over 4

=item B<users_likes_albums($user_id)> - User's liked albums

=item B<users_likes_artists($user_id)> - User's liked artists

=item B<users_likes_playlists($user_id)> - User's liked playlists

=item B<get_album_with_tracks($album_id, $user_id)> - Full album with all tracks

=item B<get_playlist_tracks($user_id, $playlist_uid, $kind)> - Playlist tracks

=item B<get_library_fingerprint($user_id)> - MD5 hash of library state for change detection

=back

=cut

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
use Digest::MD5 qw(md5_hex);
use Plugins::yandex::API::Common;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

my $lastRequestTime = 0;
my $minRequestInterval = 0.2;  # 200ms between requests to avoid rate limiting

# Synchronous HTTP GET with caching for scanner process
sub _get {
    my ($class, $path, $uid, $params) = @_;

    my ($token, $userId) = $class->_get_auth_data($uid);
    return unless $token;

    my $url = Plugins::yandex::API::Common::BASE_URL . $path;
    my $uri = URI->new($url);
    $uri->query_form($params) if $params;

    my $headers = Plugins::yandex::API::Common::get_default_headers($token);

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

    my ($token, $userId) = $class->_get_auth_data($uid);
    return [] unless $token;

    my $url = Plugins::yandex::API::Common::BASE_URL . '/tracks/';

    my $body = 'track-ids=' . join(',', @ids) . '&with-positions=true';

    my $headers = Plugins::yandex::API::Common::get_default_headers($token, 'application/x-www-form-urlencoded');

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

sub get_library_fingerprint {
    my ($class, $uid) = @_;

    my $result = $class->_get('/library/all-ids', $uid);
    my $r = ref $result eq 'HASH' ? ($result->{result} || {}) : {};

    return md5_hex(
        'albums='    . (scalar keys %{$r->{albums}    || {}}) . '|' .
        'artists='   . (scalar keys %{$r->{artists}   || {}}) . '|' .
        'library='   . (scalar keys %{$r->{library}   || {}}) . '|' .
        'playlists=' . (scalar keys %{$r->{playlists} || {}})
    );
}

sub _get_auth_data {
    my ($class, $uid) = @_;

    my $accounts = $prefs->get('accounts') || {};
    my $account = $accounts->{$uid} || return;
    my $token = $account->{token} || return;

    return ($token, $uid);
}

1;
