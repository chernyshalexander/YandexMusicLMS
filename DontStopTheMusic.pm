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
vibe wave for several). Otherwise the catalog is searched: first for the
best seed track ("<artist> <title>"), falling back to the most frequent
seed artist, and finally to My Wave.

=back

=cut

use strict;
use warnings;
use utf8;

use Scalar::Util qw(blessed);
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log;

use constant MY_WAVE_URL  => 'yandexmusic://rotor_session/user:onyourwave';
use constant SEED_TRACKS  => 20;
use constant MAX_SEEDS    => 3;
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

    my $seeds = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, SEED_TRACKS);
    if ( !$seeds || ref $seeds ne 'ARRAY' || !scalar @$seeds ) {
        $log->info("YANDEX DSTM: no mixable tracks, continuing with My Wave");
        $finish->($client, [MY_WAVE_URL]);
        return;
    }

    # Native Yandex Music tracks are used directly as seeds. The seed list
    # is shuffled by the core, so keep first-seen order when de-duplicating.
    my (@ids, %seen);
    for my $seed (@$seeds) {
        next unless $seed && ref $seed eq 'HASH';
        my $extid = $seed->{extid} || '';
        if ( $extid =~ m{yandexmusic://(?:track/)?(\d+)} ) {
            push @ids, $1 unless $seen{$1}++;
        }
    }

    if ( scalar @ids == 1 ) {
        my $url = 'yandexmusic://rotor_session/track:' . $ids[0];
        $log->info("YANDEX DSTM: single native seed, starting track radio: $url");
        $finish->($client, [$url]);
        return;
    }

    if ( scalar @ids > 1 ) {
        splice(@ids, MAX_SEEDS) if scalar @ids > MAX_SEEDS;
        my $seeds_param = join(',', map { "track:$_" } @ids);
        my $url = 'yandexmusic://rotor_session/_vibe_?seeds=' . uri_escape_utf8($seeds_param);
        $log->info("YANDEX DSTM: multiple native seeds, starting vibe wave: $url");
        $finish->($client, [$url]);
        return;
    }

    # The queue holds no Yandex tracks (local files etc.): search the catalog.
    _searchCascade($client, $api, $seeds, $finish, $protect);
}

sub _searchCascade {
    my ($client, $api, $seeds, $finish, $protect) = @_;

    # a) First seed (in the given order) that has both artist and title.
    my ($candidate) = grep { ref $_ eq 'HASH' && $_->{artist} && $_->{title} } @$seeds;

    if ($candidate) {
        my $query = $candidate->{artist} . ' ' . $candidate->{title};
        $log->info("YANDEX DSTM: searching catalog for seed track '$query'");

        $api->search(
            $query,
            'track',
            $protect->(sub {
                my $result = shift;
                my $id = _firstResultId($result, 'tracks');
                if ( defined $id ) {
                    my $url = 'yandexmusic://rotor_session/track:' . $id;
                    $log->info("YANDEX DSTM: matched catalog track, starting track radio: $url");
                    $finish->($client, [$url]);
                    return;
                }
                _artistFallback($client, $api, $seeds, $finish, $protect);
            }),
            $protect->(sub {
                my $error = shift;
                $log->warn("YANDEX DSTM: track search failed ($error), falling back to artist radio");
                _artistFallback($client, $api, $seeds, $finish, $protect);
            }),
        );
        return;
    }

    _artistFallback($client, $api, $seeds, $finish, $protect);
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
                    my $url = 'yandexmusic://rotor_session/artist:' . $id;
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

# Most frequent artist among the seeds; ties are won by the artist seen
# first in the seed list, so the pick is deterministic even though the
# core shuffles the seed order.
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
# - or the player carries an active yandex radio session in pluginData,
# - or the last queue entry is a rotor track.
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

    if ( $client->pluginData('yandex_curr_radio_session') ) {
        return 1;
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
