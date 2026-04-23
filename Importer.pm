package Plugins::yandex::Importer;

use strict;
use warnings;
use utf8;

# can't "use base ()", as this would fail in LMS 7
BEGIN {
    eval {
        require Slim::Plugin::OnlineLibraryBase;
        our @ISA = qw(Slim::Plugin::OnlineLibraryBase);
    };
}

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Versions;
use Slim::Utils::PluginManager;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

my ($ct, $splitChar);

sub initPlugin {
    my $class = shift;

    my $isScanner = main::SCANNER ? 'YES' : 'NO';
    my $lastArg = $ARGV[-1] || 'UNDEFINED';
    my $isImportEnabled = $class->isImportEnabled();
    my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);
    my $pluginName = $pluginData ? $pluginData->{name} : 'N/A';

    main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: initPlugin() - SCANNER=$isScanner, lastArg=$lastArg, importEnabled=$isImportEnabled, pluginName=$pluginName (CAN_IMPORTER=" . CAN_IMPORTER . ")");

    if (!CAN_IMPORTER) {
        $log->warn('YANDEX: The library importer feature requires at least Lyrion Music Server 8.0.0');
        return;
    }

    if (!main::SCANNER) {
        main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: initPlugin() - not SCANNER, returning");
        return;
    }

    $class->SUPER::initPlugin(@_);
    main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: initPlugin() completed, called SUPER");
}

sub startScan { if (main::SCANNER) {
    my ($class) = @_;

    main::INFOLOG && $log->is_info && $log->info("=========== YANDEX SCANNER: startScan() STARTED ===========");

    require Plugins::yandex::API::Sync;
    $ct = 'mp3';  # Default content type
    $splitChar = substr(Slim::Utils::Prefs::preferences('server')->get('splitList'), 0, 1);

    my $accounts = _enabledAccounts();
    main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: startScan - found " . scalar(keys %$accounts) . " enabled accounts");

    if (scalar keys %$accounts) {
        my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();
        main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: playlistsOnly=" . ($playlistsOnly ? 'true' : 'false'));

        $class->initOnlineTracksTable();
        main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: initialized online tracks table");

        if (!$playlistsOnly) {
            main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: starting to scan albums");
            $class->scanAlbums($accounts);
            main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: completed scanning albums");

            main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: starting to scan artists");
            $class->scanArtists($accounts);
            main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: completed scanning artists");
        }

        if (!$class->can('ignorePlaylists') || !$class->ignorePlaylists) {
            main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: starting to scan playlists");
            $class->scanPlaylists($accounts);
            main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: completed scanning playlists");
        }

        $class->deleteRemovedTracks();
        main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: deleted removed tracks");

        $cache->set('yandex_library_last_scan', time(), '1y');
        main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: set last_scan cache");
    } else {
        main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: no enabled accounts, skipping scan");
    }

    main::INFOLOG && $log->is_info && $log->info("YANDEX IMPORTER: calling endImporter");
    Slim::Music::Import->endImporter($class);
    main::INFOLOG && $log->is_info && $log->info("=========== YANDEX SCANNER: startScan() COMPLETED ===========");
} }

sub scanAlbums { if (main::SCANNER) {
    my ($class, $accounts) = @_;

    main::INFOLOG && $log->is_info && $log->info("YANDEX SCANNER: scanAlbums() starting");

    my $progress = Slim::Utils::Progress->new({
        'type'  => 'importer',
        'name'  => 'plugin_yandex_albums',
        'total' => 1,
        'every' => 1,
    });

    main::INFOLOG && $log->is_info && $log->info("YANDEX SCANNER: Created Progress object - type=" . $progress->type . ", name=" . $progress->name);

    while (my ($accountName, $userId) = each %$accounts) {
        my %missingAlbums;

        main::INFOLOG && $log->is_info && $log->info("Reading albums for $accountName (userId=$userId)...");
        my $progressMsg = string('PLUGIN_YANDEX_PROGRESS_READ_ALBUMS', $accountName);
        main::INFOLOG && $log->is_info && $log->info("YANDEX SCANNER: Updating progress - message='$progressMsg', type=" . $progress->type . ", name=" . $progress->name);
        $progress->update($progressMsg);

        my $albums = Plugins::yandex::API::Sync->users_likes_albums($userId) || [];
        $progress->total(scalar @$albums);

        foreach my $album (@$albums) {
            my $albumId = $album->{id} or next;
            my $albumDetails = $cache->get('yandex_album_with_tracks_' . $albumId);

            if ($albumDetails && $albumDetails->{volumes} && ref $albumDetails->{volumes}) {
                $progress->update($album->{title});

                my @tracks = _flattenTracks($albumDetails);
                $class->storeTracks([
                    map { _prepareTrack($albumDetails, $_) } @tracks
                ], undef, $accountName);

                main::SCANNER && Slim::Schema->forceCommit;
            }
            else {
                $missingAlbums{$albumId} = $album;
            }
        }

        # Fetch albums that weren't in cache
        while (my ($albumId, $album) = each %missingAlbums) {
            $progress->update($album->{title});

            my $albumDetails = Plugins::yandex::API::Sync->get_album_with_tracks($albumId, $userId);

            if (!$albumDetails || !$albumDetails->{volumes}) {
                $log->warn("Didn't receive tracks for " . ($album->{title} || 'unknown') . "/$albumId");
                next;
            }

            $cache->set('yandex_album_with_tracks_' . $albumId, $albumDetails, '3M');

            my @tracks = _flattenTracks($albumDetails);
            $class->storeTracks([
                map { _prepareTrack($albumDetails, $_) } @tracks
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

    while (my ($accountName, $userId) = each %$accounts) {
        main::INFOLOG && $log->is_info && $log->info("Reading artists for $accountName...");
        my $progressMsg = string('PLUGIN_YANDEX_PROGRESS_READ_ARTISTS', $accountName);
        main::INFOLOG && $log->is_info && $log->info("PROGRESS UPDATE: $progressMsg (type=" . $progress->type . ", name=" . $progress->name . ")");
        $progress->update($progressMsg);

        my $artists = Plugins::yandex::API::Sync->users_likes_artists($userId) || [];
        $progress->total($progress->total + scalar @$artists);

        foreach my $artist (@$artists) {
            my $name = $artist->{name} or next;
            my $artistId = $artist->{id};

            $progress->update($name);
            main::SCANNER && Slim::Schema->forceCommit;

            my $artist_data = {
                'artist' => $class->normalizeContributorName($name),
                'extid'  => 'yandex:artist:' . $artistId,
            };

            # Add artist cover/image if available
            if ($artist->{cover} && $artist->{cover}{uri}) {
                my $cover = $artist->{cover}{uri};
                $cover =~ s/%%/200x200/;
                $artist_data->{cover} = "https://$cover" if $cover && $cover !~ /^https?:/;
            }

            Slim::Schema::Contributor->add($artist_data);

            _cacheArtistPicture($artistId, $userId, '3M');
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

    main::INFOLOG && $log->is_info && $log->info("Removing old playlists...");
    $progress->update(string('PLAYLIST_DELETED_PROGRESS'), $progress->done);
    my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'yandexmusic://playlist/%'");
    $deletePlaylists_sth->execute();

    while (my ($accountName, $userId) = each %$accounts) {
        my $progressMsg = string('PLUGIN_YANDEX_PROGRESS_READ_PLAYLISTS', $accountName);
        main::INFOLOG && $log->is_info && $log->info("PROGRESS UPDATE: $progressMsg (type=" . $progress->type . ", name=" . $progress->name . ")");
        $progress->update($progressMsg);

        main::INFOLOG && $log->is_info && $log->info("Reading playlists for $accountName...");
        my $playlists = Plugins::yandex::API::Sync->users_likes_playlists($userId) || [];

        $progress->total($progress->total + @$playlists);

        my $prefix = 'Yandex' . string('COLON') . ' ';

        main::INFOLOG && $log->is_info && $log->info(sprintf("Importing tracks for %s playlists...", scalar @$playlists));
        foreach my $playlist (@{$playlists || []}) {
            my $id = $playlist->{kind} or next;
            my $ownerUid = $playlist->{owner}{uid} or next;

            my $tracks = Plugins::yandex::API::Sync->get_playlist_tracks($userId, $ownerUid, $id);
            $tracks = $tracks || [];

            $progress->update($accountName . string('COLON') . ' ' . $playlist->{title});
            Slim::Schema->forceCommit;

            my $url = "yandexmusic://playlist/$ownerUid/$id";

            my $cover = '';
            if ($playlist->{cover}) {
                $cover = $playlist->{cover}{uri} || '';
                $cover =~ s/%%/200x200/;
                $cover = "https://$cover" if $cover && $cover !~ /^https?:/;
            }

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

# Check if library needs update (runs in main LMS process, not scanner)
sub getArtistPicture { if (main::SCANNER) {
    my ($class, $id) = @_;

    my $url = $cache->get('yandex_artist_image_' . $id);
    return $url if $url;

    $id =~ s/yandex:artist://;

    # Get any available uid (scanner doesn't have access to specific user context)
    my $accounts = _enabledAccounts();
    my ($anyUserId) = keys %$accounts;
    return unless $anyUserId;

    require Plugins::yandex::API::Sync;
    my $artist = Plugins::yandex::API::Sync->get_artist($id, $anyUserId) || {};

    if ($artist->{cover_uri}) {
        my $cover = $artist->{cover_uri};
        $cover =~ s/%%/200x200/;
        $cover = "https://$cover" if $cover && $cover !~ /^https?:/;
        $cache->set('yandex_artist_image_' . 'yandex:artist:' . $id, $cover, '3M');
        return $cover;
    }

    return;
} }

sub trackUriPrefix { 'yandexmusic://' }

# Check if library needs update (runs in main LMS process, not scanner)
sub needsUpdate { if (!main::SCANNER) {
    my ($class, $cb) = @_;

    main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate() called with callback");

    my $enabledAccounts = _enabledAccounts();
    my $accountCount = scalar keys %{$enabledAccounts};

    unless ($accountCount) {
        main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate - no enabled accounts found, returning 0");
        my $result = $cb->(0);
        main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate callback returned: $result");
        return $result;
    }

    main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate - found $accountCount enabled accounts");

    my $lastScanTime = $cache->get('yandex_library_last_scan');
    unless ($lastScanTime) {
        main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate - never scanned before, requesting update (returning 1)");
        my $result = $cb->(1);
        main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate callback returned: $result");
        return $result;
    }

    my $daysSinceScan = (time() - $lastScanTime) / 86400;
    main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate - last scan was $daysSinceScan days ago");

    # For now, always rescan if more than 7 days have passed
    # TODO: Implement fingerprinting like Deezer to check for actual changes
    if ($daysSinceScan > 7) {
        main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate - requesting update (7+ days since last scan, returning 1)");
        my $result = $cb->(1);
        main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate callback returned: $result");
        return $result;
    }

    main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate - library is up to date (returning 0)");
    my $result = $cb->(0);
    main::INFOLOG && $log->is_info && $log->info("YANDEX: needsUpdate callback returned: $result");
    return $result;
} }

# Filter accounts based on import preferences
# Returns hash: { account_name => uid, ... }
sub _enabledAccounts {
    my $accounts = $prefs->get('accounts') || {};
    my $dontImportAccounts = $prefs->get('dontImportAccounts') || {};

    my $enabledAccounts = {};

    while (my ($uid, $account) = each %$accounts) {
        next if $uid eq 'migrating';
        next if $dontImportAccounts->{$uid};

        # Use account name/login for display, uid for API calls
        my $accountName = $account->{name} || $account->{login} || $uid;
        $enabledAccounts->{$accountName} = $uid;
    }

    return $enabledAccounts;
}

# Flatten nested volumes structure into flat track list
sub _flattenTracks {
    my ($album) = @_;

    my @tracks;
    if ($album->{volumes} && ref $album->{volumes} eq 'ARRAY') {
        foreach my $volume (@{$album->{volumes}}) {
            if ($volume && ref $volume eq 'ARRAY') {
                foreach my $track (@$volume) {
                    push @tracks, $track;
                }
            }
        }
    }

    return @tracks;
}

# Prepare track data for LMS database storage
sub _prepareTrack {
    my ($album, $track) = @_;

    my $trackId = $track->{id} or return;
    my $url = 'yandexmusic://' . $trackId . '.' . $ct;

    my $duration = $track->{durationMs} ? int($track->{durationMs} / 1000) : 0;

    my $artist_name = 'Unknown';
    if ($track->{artists} && ref $track->{artists} eq 'ARRAY' && @{$track->{artists}}) {
        $artist_name = $track->{artists}[0]{name};
    }

    my $cover = '';
    if ($album->{coverUri}) {
        $cover = $album->{coverUri};
        $cover =~ s/%%/200x200/;
        $cover = "https://$cover" if $cover;
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
        COVER        => $cover,
        AUDIO        => 1,
        EXTID        => $url,
        CONTENT_TYPE => $ct,
        LOSSLESS     => 0,
    };

    # Add additional artists if present
    if ($track->{artists} && @{$track->{artists}} > 1) {
        my @otherArtists = map { $_->{name} } grep { $_->{name} ne $artist_name } @{$track->{artists}};
        if (@otherArtists) {
            $splitChar ||= substr(Slim::Utils::Prefs::preferences('server')->get('splitList'), 0, 1);
            $trackData->{TRACKARTIST} = join($splitChar, @otherArtists);
        }
    }

    return $trackData;
}

# Cache artist picture with TTL
sub _cacheArtistPicture {
    my ($artistId, $userId, $ttl) = @_;

    my $artist = Plugins::yandex::API::Sync->get_artist($artistId, $userId) || {};

    if ($artist->{cover_uri}) {
        my $cover = $artist->{cover_uri};
        $cover =~ s/%%/200x200/;
        $cover = "https://$cover" if $cover && $cover !~ /^https?:/;
        $cache->set('yandex_artist_image_yandex:artist:' . $artistId, $cover, $ttl || '3M');
    }
}

1;
