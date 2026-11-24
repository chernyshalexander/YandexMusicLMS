package Plugins::yandex::DontStopTheMusic;

=encoding utf8

=head1 NAME

Plugins::yandex::DontStopTheMusic - Don't Stop The Music providers for the Yandex Music plugin

=head1 DESCRIPTION

Registers two "Don't Stop The Music" (DSTM) providers with the LMS core
(Slim::Plugin::DontStopTheMusic::Plugin). When a player's queue is nearly
finished, the core invokes the registered handler as

    $handler->($client, $cb)

and the provider MUST call the callback exactly once, either with a list of
tracks to append:

    $cb->($client, \@urls)

or with nothing to add:

    $cb->($client)

The LMS core keeps the player flagged as active until $cb is called; a
provider that dies or returns without calling $cb would block DSTM for that
player until the server restarts. All provider bodies and every asynchronous
API callback therefore run through _guarded(), which wraps $cb so that it
fires exactly once even when provider code or a deferred callback throws
(the failure is logged and the player is released without tracks).

Providers:

=over 4

=item myWaveHandler

Continues playback with My Wave (yandexmusic://rotor_session/user:onyourwave).

=item playlistWaveHandler

Builds a Rotor radio session from the current queue. Native Yandex Music
tracks are used as seeds directly (track radio for one id, a multi-seed
vibe wave for several). Otherwise the catalog is searched candidate by
candidate (the playing track first, then the queue tail) until up to three
tracks match, and a wave is launched over everything that matched (one match
-> track radio). If nothing matched, the most frequent candidate artist is
searched, and finally My Wave is queued.

=back

=cut

use strict;
use warnings;
use utf8;

use Scalar::Util qw(blessed);
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log;

# dstm=1 marks provider-launched sessions: explodePlaylist uses the flag to
# leave the Vibe Wheel alone unless the dstm_wheel_rebuild preference is on.
use constant MY_WAVE_URL  => 'yandexmusic://rotor_session/user:onyourwave?dstm=1';
use constant MAX_SEEDS    => 3;
use constant CANDIDATE_CAP => 5;   # catalog candidates: playing track + queue tail
use constant ROTOR_URL_RE => qr/rotor_(?:session|station)=/;

# logger() is not exported by Slim::Utils::Log, use the fully-qualified call.
# The category 'plugin.yandex' is registered by Plugin.pm.
my $log = Slim::Utils::Log::logger('plugin.yandex');

sub init {
    my $class = shift;

    if ( Slim::Plugin::DontStopTheMusic::Plugin->can('registerHandler') ) {
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_YANDEX_DSTM_MY_WAVE', \&myWaveHandler);
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_YANDEX_DSTM_PLAYLIST_WAVE', \&playlistWaveHandler);
        $log->info("YANDEX DSTM: registered providers (my wave, playlist wave)");
    }
}

sub shutdown {
    my $class = shift;

    if ( Slim::Plugin::DontStopTheMusic::Plugin->can('unregisterHandler') ) {
        Slim::Plugin::DontStopTheMusic::Plugin->unregisterHandler('PLUGIN_YANDEX_DSTM_MY_WAVE');
        Slim::Plugin::DontStopTheMusic::Plugin->unregisterHandler('PLUGIN_YANDEX_DSTM_PLAYLIST_WAVE');
        $log->info("YANDEX DSTM: unregistered providers");
    }
}

# The LMS core keeps the player flagged as busy until $cb is called: a
# provider that dies or never calls back would block Don't Stop The Music
# for that player until the server restarts. _guarded() runs the provider
# and wraps $cb so it runs exactly once, even if the provider body or an
# asynchronous API callback throws (the error is logged and the player is
# released without tracks).
sub _guarded {
    my ($client, $cb, $provider) = @_;

    my $done = 0;
    my $finish = sub {
        return if $done;
        $done = 1;
        $cb->(@_);
    };

    # Run a piece of provider code; on an exception give up with no tracks.
    my $run = sub {
        my ($code, @args) = @_;
        my $ok = eval { $code->(@args); 1 };
        if (!$ok) {
            $log->error("YANDEX DSTM: provider failed: $@");
            $finish->($client);
        }
    };

    # Wrap an asynchronous API callback in $run.
    my $protect = sub {
        my ($code) = @_;
        return sub { $run->($code, @_) };
    };

    $run->($provider, $client, $finish, $protect);
}

sub myWaveHandler {
    my ($client, $cb) = @_;
    _guarded($client, $cb, \&_myWave);
}

sub playlistWaveHandler {
    my ($client, $cb) = @_;
    _guarded($client, $cb, \&_playlistWave);
}

sub _myWave {
    my ($client, $finish) = @_;

    $client = $client->master;
    my $api = Plugins::yandex::Plugin::getAPIForClient($client);

    if ( !$api || !$api->get_token ) {
        $log->warn("YANDEX DSTM: no authenticated API client for player " . $client->name);
        $finish->($client);
        return;
    }

    $log->info("YANDEX DSTM: queueing My Wave for " . $client->name);
    $finish->($client, [MY_WAVE_URL]);
}

sub _playlistWave {
    my ($client, $finish, $protect) = @_;

    $client = $client->master;
    my $api = Plugins::yandex::Plugin::getAPIForClient($client);

    if ( !$api || !$api->get_token ) {
        $log->warn("YANDEX DSTM: no authenticated API client for player " . $client->name);
        $finish->($client);
        return;
    }

    # Ordered seed candidates: the playing track first, then the queue from
    # its tail (the freshest tracks first). The core's getMixableProperties
    # would shuffle, so the catalog cascade must build its own order.
    my $candidates = _orderedCandidates($client);
    if ( !scalar @$candidates ) {
        $log->info("YANDEX DSTM: no mixable tracks, continuing with My Wave");
        $finish->($client, [MY_WAVE_URL]);
        return;
    }

    # Native Yandex Music tracks are used directly as seeds, in candidate
    # order (playing track first), de-duplicated.
    my (@ids, %seen);
    for my $seed (@$candidates) {
        next unless $seed && ref $seed eq 'HASH';
        my $extid = $seed->{extid} || '';
        if ( $extid =~ m{yandexmusic://(?:track/)?(\d+)} ) {
            push @ids, $1 unless $seen{$1}++;
        }
    }

    if ( scalar @ids ) {
        _finishSeedIds($client, $finish, \@ids);
        return;
    }

    # The queue holds no Yandex tracks (local files etc.): search the catalog,
    # candidate by candidate, and launch a wave on whatever matches.
    _searchCascade($client, $api, $candidates, $finish, $protect);
}

# Finish a provider run with the given Yandex track ids: one id -> track radio,
# several -> a multi-seed vibe wave (at most MAX_SEEDS seeds).
sub _finishSeedIds {
    my ($client, $finish, $ids) = @_;

    splice(@$ids, MAX_SEEDS) if scalar @$ids > MAX_SEEDS;

    if ( scalar @$ids == 1 ) {
        my $url = 'yandexmusic://rotor_session/track:' . $ids->[0] . '?dstm=1';
        $log->info("YANDEX DSTM: single seed, starting track radio: $url");
        $finish->($client, [$url]);
        return;
    }

    my $seeds_param = join(',', map { "track:$_" } @$ids);
    my $url = 'yandexmusic://rotor_session/_vibe_?seeds=' . uri_escape_utf8($seeds_param) . '&dstm=1';
    $log->info("YANDEX DSTM: multi-seed vibe wave: $url");
    $finish->($client, [$url]);
}

# Ordered seed candidates for the catalog cascade: the playing track first,
# then the queue from its tail (the freshest tracks first), at most
# CANDIDATE_CAP entries. Each candidate is a hash { artist, title, extid };
# entries without usable metadata are skipped.
sub _orderedCandidates {
    my ($client) = @_;
    my $core = 'Slim::Plugin::DontStopTheMusic::Plugin';

    my (@candidates, %seen);
    my $push = sub {
        my ($track, $url) = @_;
        return unless defined $url && length $url && !$seen{$url}++;
        my ($artist, $title, undef, undef, undef, undef, $extid) =
            $core->getMixablePropertiesFromTrack($client, $track);
        $extid ||= '';
        # A candidate needs metadata for the catalog search, but a native
        # Yandex Music track is usable as a seed even without it.
        return unless $extid =~ m{yandexmusic://(?:track/)?(\d+)}
            || (defined $artist && defined $title && $artist ne '' && $title ne '');
        push @candidates, { artist => $artist, title => $title, extid => $extid };
    };

    my $song = $client->playingSong();
    if ( $song && $song->track ) {
        my $track = $song->track;
        $push->($track, blessed($track) ? $track->url : $track);
    }

    my $playlist = Slim::Player::Playlist::playList($client);
    if ( $playlist && ref $playlist eq 'ARRAY' ) {
        for my $entry ( reverse @$playlist ) {
            last if @candidates >= CANDIDATE_CAP;
            my $url = blessed($entry) ? $entry->url : $entry;
            $push->($entry, $url);
        }
    }

    return \@candidates;
}

# Sequential catalog cascade: search "artist title" for each candidate in
# order (the playing track first), collect up to MAX_SEEDS catalog ids, then
# launch a wave over everything that matched. Nothing matched -> artist
# fallback. The callback is issued one search at a time: the next candidate is
# only queried after the previous answer (or error) arrives.
sub _searchCascade {
    my ($client, $api, $candidates, $finish, $protect) = @_;

    my @matched;
    my $i = 0;

    my $done;
    my $next;
    $next = sub {
        # Skip candidates without metadata and stop at the cap or the end.
        while ( $i < scalar @$candidates && scalar @matched < MAX_SEEDS ) {
            my $cand = $candidates->[ $i++ ];
            next unless $cand && defined $cand->{artist} && $cand->{artist} ne ''
                     && defined $cand->{title}  && $cand->{title} ne '';

            my $query = $cand->{artist} . ' ' . $cand->{title};
            $log->info("YANDEX DSTM: searching catalog for seed track '$query'");

            $api->search(
                $query,
                'track',
                $protect->(sub {
                    my $result = shift;
                    my $id = _firstResultId($result, 'tracks');
                    if ( defined $id && !grep { $_ eq $id } @matched ) {
                        push @matched, $id;
                        $log->info("YANDEX DSTM: matched catalog track $id (" . scalar(@matched) . " of " . MAX_SEEDS . " seeds)");
                    }
                    $next->();
                }),
                $protect->(sub {
                    my $error = shift;
                    $log->warn("YANDEX DSTM: track search failed ($error), trying the next candidate");
                    $next->();
                }),
            );
            return;
        }
        $done->();
    };

    $done = sub {
        if ( scalar @matched ) {
            _finishSeedIds($client, $finish, \@matched);
            return;
        }
        _artistFallback($client, $api, $candidates, $finish, $protect);
    };

    $next->();
}

sub _artistFallback {
    my ($client, $api, $seeds, $finish, $protect) = @_;

    my $top_artist = _topArtist($seeds);

    if ( defined $top_artist ) {
        $log->info("YANDEX DSTM: searching catalog for artist '$top_artist'");

        $api->search(
            $top_artist,
            'artist',
            $protect->(sub {
                my $result = shift;
                my $id = _firstResultId($result, 'artists');
                if ( defined $id ) {
                    my $url = 'yandexmusic://rotor_session/artist:' . $id . '?dstm=1';
                    $log->info("YANDEX DSTM: matched artist, starting artist radio: $url");
                    $finish->($client, [$url]);
                    return;
                }
                $log->info("YANDEX DSTM: artist not found, continuing with My Wave");
                $finish->($client, [MY_WAVE_URL]);
            }),
            $protect->(sub {
                my $error = shift;
                $log->warn("YANDEX DSTM: artist search failed ($error), continuing with My Wave");
                $finish->($client, [MY_WAVE_URL]);
            }),
        );
        return;
    }

    $log->info("YANDEX DSTM: no artist seeds found, continuing with My Wave");
    $finish->($client, [MY_WAVE_URL]);
}

# Most frequent artist among the candidates; ties are won by the artist seen
# first (the freshest track), so the pick is deterministic.
sub _topArtist {
    my ($seeds) = @_;

    my (%count, @order);
    for my $seed (@$seeds) {
        next unless ref $seed eq 'HASH';
        my $artist = $seed->{artist};
        next unless defined $artist && $artist ne '';
        if ( !exists $count{$artist} ) {
            $count{$artist} = 0;
            push @order, $artist;
        }
        $count{$artist}++;
    }

    my ($top, $best) = (undef, 0);
    for my $artist (@order) {
        if ( $count{$artist} > $best ) {
            ($top, $best) = ($artist, $count{$artist});
        }
    }
    return $top;
}

# First id from a search result of the given type ('tracks' / 'artists'),
# reading one level at a time so nothing is autovivified into the (possibly
# cached) decoded result structure:
#   { tracks => { results => [ { id => ... }, ... ] } }
sub _firstResultId {
    my ($result, $type) = @_;

    return undef unless $result && ref $result eq 'HASH';
    my $by_type = $result->{$type};
    return undef unless $by_type && ref $by_type eq 'HASH';
    my $results = $by_type->{results};
    return undef unless $results && ref $results eq 'ARRAY' && scalar @$results;
    my $first = $results->[0];
    return undef unless $first && ref $first eq 'HASH';
    return $first->{id};
}

# Returns 1 when a Rotor radio session owns the player's queue, else 0:
# - the playing song is a rotor track (yandexmusic://<id>?rotor_session=...),
# - or the last queue entry is a rotor track.
#
# yandex_curr_radio_session is deliberately not consulted: Plugin.pm "clears" it
# by passing undef, which Slim::Player::Client::pluginData ignores, so it keeps
# the last rotor track's session id for the lifetime of the player object and
# would park Don't Stop The Music for good.
sub isRotorActive {
    my ($class, $client) = @_;

    return 0 unless $client;
    $client = $client->master;

    if ( my $song = $client->playingSong() ) {
        my $track = $song->track;
        my $url = !defined $track ? undef : blessed($track) ? $track->url : $track;
        if ( defined $url && $url =~ ROTOR_URL_RE ) {
            return 1;
        }
    }

    my $playlist = Slim::Player::Playlist::playList($client);
    if ( $playlist && ref $playlist eq 'ARRAY' && scalar @$playlist ) {
        my $last = $playlist->[-1];
        my $url = !defined $last ? undef : blessed($last) ? $last->url : $last;
        if ( defined $url && $url =~ ROTOR_URL_RE ) {
            return 1;
        }
    }

    return 0;
}

1;

=head1 SEE ALSO

L<Plugins::yandex::Plugin>, L<Plugins::yandex::ProtocolHandler>

=cut
