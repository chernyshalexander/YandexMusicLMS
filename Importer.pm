package Plugins::yandex::Importer;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::OnlineLibraryBase);

use Digest::MD5 qw(md5_hex);
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Versions;
use Plugins::yandex::API::Common;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

my ($ct, $splitChar);
my $previousArtistId = '';

sub initPlugin {
    my $class = shift;

    if (!CAN_IMPORTER) {
        $log->warn('YANDEX: Library importer requires Lyrion Music Server 8.0.0+');
        return;
    }

    if (!main::SCANNER) {
        return;
    }

    $class->SUPER::initPlugin(@_);
}

sub startScan { if (main::SCANNER) {
    my ($class) = @_;

    require Plugins::yandex::API::Sync;
    $ct = 'mp3';
    $splitChar = substr(Slim::Utils::Prefs::preferences('server')->get('splitList'), 0, 1);

    my $accounts = _enabledAccounts();

    if (scalar keys %$accounts) {
        my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();

        $class->initOnlineTracksTable();

        if (!$playlistsOnly) {
            $class->scanAlbums($accounts);
            $class->scanArtists($accounts);
        }

        if (!$class->can('ignorePlaylists') || !$class->ignorePlaylists) {
            $class->scanPlaylists($accounts);
        }

        $class->deleteRemovedTracks();
        $cache->set('yandex_library_last_scan', time(), '1y');

        # Save library fingerprint for needsUpdate() to detect future changes
        my ($anyUserId) = values %$accounts;
        if ($anyUserId) {
            main::INFOLOG && $log->is_info && $log->info("Yandex startScan: computing library fingerprint for caching");
            my $fingerprint = Plugins::yandex::API::Sync->get_library_fingerprint($anyUserId);
            if ($fingerprint) {
                $cache->set('yandex_library_fingerprint', $fingerprint, '1y');
                main::INFOLOG && $log->is_info && $log->info("Yandex startScan: saved fingerprint=$fingerprint to cache");
            } else {
                main::INFOLOG && $log->is_info && $log->info("Yandex startScan: failed to compute fingerprint, skipping cache");
            }
        }
    }

    Slim::Music::Import->endImporter($class);
} }

sub scanAlbums { if (main::SCANNER) {
    my ($class, $accounts) = @_;

    my $progress = Slim::Utils::Progress->new({
        'type'  => 'importer',
        'name'  => 'plugin_yandex_albums',
        'total' => 1,
        'every' => 1,
    });

    while (my ($accountName, $userId) = each %$accounts) {
        my %missingAlbums;

        $progress->update(string('PLUGIN_YANDEX_PROGRESS_READ_ALBUMS', $accountName));

        my $albums = Plugins::yandex::API::Sync->users_likes_albums($userId) || [];
        $progress->total(scalar @$albums);

        foreach my $album (@$albums) {
            my $albumId = $album->{id} or next;
            my $albumDetails = $cache->get('yandex_album_with_tracks_' . $albumId);

            if ($albumDetails && $albumDetails->{volumes} && ref $albumDetails->{volumes}) {
                $progress->update($album->{title});

                $class->storeTracks([
                    map { _prepareTrack($albumDetails, $_) } _flattenTracks($albumDetails)
                ], undef, $accountName);

                main::SCANNER && Slim::Schema->forceCommit;
            }
            else {
                $missingAlbums{$albumId} = $album;
            }
        }

        while (my ($albumId, $album) = each %missingAlbums) {
            $progress->update($album->{title});

            my $albumDetails = Plugins::yandex::API::Sync->get_album_with_tracks($albumId, $userId);

            if (!$albumDetails || !$albumDetails->{volumes}) {
                $log->warn("Didn't receive tracks for " . ($album->{title} || 'unknown') . "/$albumId");
                next;
            }

            $cache->set('yandex_album_with_tracks_' . $albumId, $albumDetails, '3M');

            $class->storeTracks([
                map { _prepareTrack($albumDetails, $_) } _flattenTracks($albumDetails)
            ], undef, $accountName);

            main::SCANNER && Slim::Schema->forceCommit;
        }
    }

    $progress->final();
    main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanArtists { if (main::SCANNER) {
    my ($class, $accounts) = @_;

    my $progress = Slim::Utils::Progress->new({
        'type'  => 'importer',
        'name'  => 'plugin_yandex_artists',
        'total' => 1,
        'every' => 1,
    });

    $previousArtistId = '';

    while (my ($accountName, $userId) = each %$accounts) {
        $progress->update(string('PLUGIN_YANDEX_PROGRESS_READ_ARTISTS', $accountName));

        my $artists = Plugins::yandex::API::Sync->users_likes_artists($userId) || [];
        $progress->total($progress->total + scalar @$artists);

        foreach my $artist (@$artists) {
            my $name = $artist->{name} or next;

            $progress->update($name);
            main::SCANNER && Slim::Schema->forceCommit;

            Slim::Schema::Contributor->add({
                'artist' => $class->normalizeContributorName($name),
                'extid'  => 'yandex:artist:' . $artist->{id},
            });

            _cacheArtistPicture($artist, '3M');
        }
    }

    $progress->final();
    main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanPlaylists { if (main::SCANNER) {
    my ($class, $accounts) = @_;

    my $dbh = Slim::Schema->dbh();
    my $insertTrackInTempTable_sth = $dbh->prepare_cached("INSERT OR IGNORE INTO online_tracks (url) VALUES (?)") if !$main::wipe;

    my $progress = Slim::Utils::Progress->new({
        'type'  => 'importer',
        'name'  => 'plugin_yandex_playlists',
        'total' => 0,
        'every' => 1,
    });

    $progress->update(string('PLAYLIST_DELETED_PROGRESS'), $progress->done);
    my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'yandexmusic://playlist/%'");
    $deletePlaylists_sth->execute();

    while (my ($accountName, $userId) = each %$accounts) {
        $progress->update(string('PLUGIN_YANDEX_PROGRESS_READ_PLAYLISTS', $accountName));

        my $playlists = Plugins::yandex::API::Sync->users_likes_playlists($userId) || [];
        $progress->total($progress->total + @$playlists);

        my $prefix = 'Yandex' . string('COLON') . ' ';

        foreach my $playlist (@{$playlists || []}) {
            my $id = $playlist->{kind} or next;
            my $ownerUid = $playlist->{owner}{uid} or next;

            my $tracks = Plugins::yandex::API::Sync->get_playlist_tracks($userId, $ownerUid, $id) || [];

            $progress->update($accountName . string('COLON') . ' ' . $playlist->{title});
            Slim::Schema->forceCommit;

            my $url = "yandexmusic://playlist/$ownerUid/$id";

            my $cover = $playlist->{cover} ? _normalizeImageUrl($playlist->{cover}{uri} || '') : '';

            my $playlistObj = Slim::Schema->updateOrCreate({
                url        => $url,
                playlist   => 1,
                integrateRemote => 1,
                attributes => {
                    TITLE        => $prefix . $playlist->{title},
                    COVER        => $cover,
                    AUDIO        => 1,
                    EXTID        => $url,
                    CONTENT_TYPE => 'ssp'
                },
            });

            my @trackIds = map { "yandexmusic://$_->{id}." . $ct } @$tracks;

            $playlistObj->setTracks(\@trackIds) if $playlistObj && scalar @trackIds;
            $insertTrackInTempTable_sth && $insertTrackInTempTable_sth->execute($url);
        }

        Slim::Schema->forceCommit;
    }

    $progress->final();
    Slim::Schema->forceCommit;
} }

# Called from SCANNER process — synchronous API call is valid here
sub getArtistPicture { if (main::SCANNER) {
    my ($class, $id) = @_;

    my $url = $cache->get('yandex_artist_image_' . $id);
    return $url if $url;

    $id =~ s/yandex:artist://;

    my $accounts = _enabledAccounts();
    my ($anyUserId) = keys %$accounts;
    return unless $anyUserId;

    require Plugins::yandex::API::Sync;
    my $artist = Plugins::yandex::API::Sync->get_artist($id, $anyUserId) || {};

    if ($artist->{cover_uri}) {
        my $cover = _normalizeImageUrl($artist->{cover_uri});
        $cache->set('yandex_artist_image_yandex:artist:' . $id, $cover, '3M');
        return $cover;
    }

    return;
} }

sub trackUriPrefix { 'yandexmusic://' }

sub needsUpdate { if (!main::SCANNER) {
    my ($class, $cb) = @_;

    my $accounts = _enabledAccounts();
    return $cb->(0) unless scalar keys %$accounts;

    my $lastScanTime = $cache->get('yandex_library_last_scan');
    my $lastFingerprint = $cache->get('yandex_library_fingerprint') || '';

    main::INFOLOG && $log->is_info && $log->info("Yandex needsUpdate called. lastScanTime=" . ($lastScanTime || 'never') . ", lastFingerprint=" . ($lastFingerprint || 'none'));

    return $cb->(1) unless $lastScanTime;

    # For multi-account setups, fingerprint is checked for first account only.
    # Different accounts may have different libraries; manual rescan can be triggered via UI.
    my @userIds = sort values %$accounts;
    my ($anyUserId) = @userIds;
    my $token = ($prefs->get('accounts') || {})->{$anyUserId}{token};

    unless ($token) {
        main::INFOLOG && $log->is_info && $log->info("Yandex needsUpdate: no token found for user $anyUserId, falling back to time-based check");
        return $cb->( (time() - $lastScanTime) / 86400 > 7 ? 1 : 0 );
    }

    require Plugins::yandex::API::Async;
    require Plugins::yandex::API::Common;
    my $api = Plugins::yandex::API::Async->new($token);

    main::INFOLOG && $log->is_info && $log->info("Yandex needsUpdate: fetching fingerprint from /library/all-ids endpoint");

    $api->get(
        Plugins::yandex::API::Common::BASE_URL . '/library/all-ids',
        undef,
        sub {
            my $result = shift;
            my $r = ref $result eq 'HASH' ? ($result->{result} || {}) : {};

            my $albumsCount = scalar keys %{$r->{albums} || {}};
            my $artistsCount = scalar keys %{$r->{artists} || {}};
            my $libraryCount = scalar keys %{$r->{library} || {}};
            my $playlistsCount = scalar keys %{$r->{playlists} || {}};

            my $fingerprint = md5_hex(
                'albums='    . $albumsCount . '|' .
                'artists='   . $artistsCount . '|' .
                'library='   . $libraryCount . '|' .
                'playlists=' . $playlistsCount
            );

            main::INFOLOG && $log->is_info && $log->info("Yandex fingerprint computed: albums=$albumsCount, artists=$artistsCount, library=$libraryCount, playlists=$playlistsCount, md5=$fingerprint");
            main::INFOLOG && $log->is_info && $log->info("Yandex fingerprint comparison: current=$fingerprint vs cached=$lastFingerprint");

            my $needsScan = $fingerprint ne $lastFingerprint;
            main::INFOLOG && $log->is_info && $log->info("Yandex needsUpdate result: " . ($needsScan ? 'SCAN NEEDED (fingerprint changed)' : 'SKIP SCAN (fingerprint unchanged)'));

            $cb->($needsScan ? 1 : 0);
        },
        sub {
            my $error = shift;
            main::INFOLOG && $log->is_info && $log->info("Yandex fingerprint check failed: $error, falling back to time-based check");
            my $daysSinceScan = (time() - $lastScanTime) / 86400;
            my $needsScan = $daysSinceScan > 7 ? 1 : 0;
            main::INFOLOG && $log->is_info && $log->info("Yandex fallback: days since last scan=$daysSinceScan, needsScan=$needsScan");
            $cb->($needsScan);
        }
    );
} }

sub _enabledAccounts {
    my $accounts = $prefs->get('accounts') || {};
    my $dontImportAccounts = $prefs->get('dontImportAccounts') || {};

    my $enabledAccounts = {};

    while (my ($uid, $account) = each %$accounts) {
        next if $uid eq 'migrating';
        next if $dontImportAccounts->{$uid};

        $enabledAccounts->{ $account->{name} || $account->{login} || $uid } = $uid;
    }

    return $enabledAccounts;
}

sub _flattenTracks {
    my ($album) = @_;
    return unless $album->{volumes};
    return map { @{$_} } grep { ref $_ eq 'ARRAY' } @{$album->{volumes}};
}

sub _normalizeImageUrl {
    my ($url) = @_;
    return '' unless $url;
    $url =~ s/%%/200x200/;
    $url = "https://$url" if $url !~ /^https?:/;
    return $url;
}

sub _prepareTrack {
    my ($album, $track) = @_;

    my $trackId = $track->{id} or return;
    my $url = 'yandexmusic://' . $trackId . '.' . $ct;

    my $duration = $track->{durationMs} ? int($track->{durationMs} / 1000) : 0;

    my $artist_name = 'Unknown';
    if ($track->{artists} && ref $track->{artists} eq 'ARRAY' && @{$track->{artists}}) {
        $artist_name = $track->{artists}[0]{name};
    }

    my $trackData = {
        url          => $url,
        TITLE        => $track->{title} || 'Unknown',
        ARTIST       => $artist_name,
        ARTIST_EXTID => 'yandex:artist:' . ($track->{artists}[0]{id} || ''),
        ALBUM        => $album->{title} || 'Unknown',
        ALBUM_EXTID  => 'yandex:album:' . $album->{id},
        TRACKNUM     => $track->{trackNumber} || 0,
        SECS         => $duration,
        COVER        => $album->{coverUri} ? _normalizeImageUrl($album->{coverUri}) : '',
        AUDIO        => 1,
        EXTID        => $url,
        CONTENT_TYPE => $ct,
        LOSSLESS     => 0,
    };

    if ($track->{artists} && @{$track->{artists}} > 1) {
        my @otherArtists = map { $_->{name} } grep { $_->{name} ne $artist_name } @{$track->{artists}};
        if (@otherArtists) {
            $trackData->{TRACKARTIST} = join($splitChar, @otherArtists);
        }
    }

    return $trackData;
}

sub _cacheArtistPicture {
    my ($artist, $ttl) = @_;

    my $artistId = $artist->{id};
    return if !$artistId || $artistId eq $previousArtistId;

    my $cover = ref $artist->{cover} eq 'HASH' ? $artist->{cover}{uri} : '';
    return unless $cover;

    $cache->set('yandex_artist_image_yandex:artist:' . $artistId, _normalizeImageUrl($cover), $ttl || '3M');
    $previousArtistId = $artistId;
}

1;
