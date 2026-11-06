#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib '/usr/share/squeezeboxserver/CPAN';
use Test::More 'no_plan';

# Mock Slim framework and environment cleanly
BEGIN {
    for my $c (qw(SCANNER PERFMON DEBUGLOG INFOLOG STATISTICS ISWINDOWS ISMAC RESIZER WEBUI NOMYSB TRANSCODING SB1SLIMP3SYNC LOCALFILE NOBROWSECACHE SLIM_SERVICE NOUPNP ISACTIVEPERL HAS_AIO)) {
        no strict "refs"; *{"main::$c"} = sub () { 0 };
    }

    # Mock Log
    $INC{"Slim/Utils/Log.pm"} = 1;
    {
        package MockLog;
        sub info {} sub error {} sub warn {} sub debug {} sub is_debug { 0 } sub is_info { 0 }
        package Slim::Utils::Log;
        sub logger { bless {}, 'MockLog' }
        sub addLogCategory { bless {}, 'MockLog' }
        sub import {
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::logger"} = \&logger;
        }
    }

    # Mock OSDetect
    $INC{"Slim/Utils/OSDetect.pm"} = 1;
    {
        package MockOS;
        sub name { 'Linux' }
        sub get { 'Linux' }
        sub canAutoUpdate { 0 }
        sub dirsFor { () }
        sub initDetails {}
        sub localeDetails { return ('utf8', 'utf8'); }
        sub ignoredItems { return (); }
        package Slim::Utils::OSDetect;
        our $os = bless {}, 'MockOS';
        sub getOS { $os }
        sub OS { 'Linux' }
        sub isLinux { 1 }
        sub isWindows { 0 }
        sub isMac { 0 }
        sub init {}
    }

    $INC{"Slim/Player/Playlist.pm"} = 1;
    {
        package Slim::Player::Playlist;
        sub count { 0 }
        sub refreshPlaylist {}
        sub shuffle { 0 }
        sub repeat { 0 }
    }

    $INC{"Slim/Music/Import.pm"} = 1;
    {
        package Slim::Music::Import;
        sub addImporter {}
        sub useImporter {}
    }

    $INC{"Slim/Buttons/Common.pm"} = 1;
    {
        package Slim::Buttons::Common;
        sub mode {
            my $client = shift;
            return undef unless $client && ref $client && $client->can('modeStack');
            my $stack = $client->modeStack;
            return ($stack && @$stack) ? $stack->[-1] : undef;
        }
        sub popMode {
            my $client = shift;
            return undef unless $client && ref $client && $client->can('modeStack');
            my $stack = $client->modeStack;
            pop @$stack if ($stack && @$stack);
            return ($stack && @$stack) ? $stack->[-1] : undef;
        }
        sub pushModeLeft {
            my ($client, $mode) = @_;
            return unless $client && ref $client && $client->can('modeStack');
            my $stack = $client->modeStack;
            push @$stack, $mode;
        }
    }

    # Mock JSON::XS::VersionOneAndTwo with JSON::PP
    $INC{"JSON/XS/VersionOneAndTwo.pm"} = 1;
    require JSON::PP;
    {
        no strict 'refs';
        *{"JSON::XS::VersionOneAndTwo::decode_json"} = \&JSON::PP::decode_json;
        *{"JSON::XS::VersionOneAndTwo::encode_json"} = \&JSON::PP::encode_json;
        *{"JSON::XS::VersionOneAndTwo::to_json"}     = \&JSON::PP::encode_json;
        *{"JSON::XS::VersionOneAndTwo::from_json"}   = \&JSON::PP::decode_json;
    }

    # Mock Digest::SHA1 using standard Digest::SHA
    $INC{"Digest/SHA1.pm"} = 1;
    require Digest::SHA;
    {
        no strict 'refs';
        *{"Digest::SHA1::sha1"}        = \&Digest::SHA::sha1;
        *{"Digest::SHA1::sha1_hex"}    = \&Digest::SHA::sha1_hex;
        *{"Digest::SHA1::sha1_base64"} = \&Digest::SHA::sha1_base64;
    }

    # Mock Timers and IO
    $INC{"Slim/Utils/Timers.pm"} = 1;
    {
        package Slim::Utils::Timers;
        our @timers;
        sub setTimer {
            my ($obj, $cb, $delay, $tag) = @_;
            push @timers, { obj => $obj, cb => $cb, delay => $delay, tag => $tag };
        }
        sub killTimers {
            my ($obj, $cb) = @_;
            @timers = grep { $_->{cb} ne $cb } @timers;
        }
    }

    $INC{"Slim/Networking/IO/Select.pm"} = 1;
    {
        package Slim::Networking::IO::Select;
        sub addRead {}
        sub removeRead {}
        sub addWrite {}
        sub removeWrite {}
    }

    $INC{"Slim/Networking/Async.pm"} = 1;
    {
        package Slim::Networking::Async;
        sub new { bless {}, shift }
        sub open {}
        sub close {}
        sub mk_accessor {
            my ($class, $type, @fields) = @_;
            for my $f (@fields) {
                no strict 'refs';
                *{"${class}::$f"} = sub {
                    my $self = shift;
                    if (@_) { $self->{$f} = shift; }
                    return $self->{$f};
                };
            }
        }
    }

    # Mock Prefs
    $INC{"Slim/Utils/Prefs.pm"} = 1;
    {
        package Slim::Utils::Prefs;
        sub preferences { bless {}, 'MockPrefs' }
        sub import {
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::preferences"} = \&preferences;
        }
        package MockPrefs;
        our %PREFS = (
            show_history           => 1,
            show_resume_quick_item => 1,
            progress_save_interval => 30,
        );
        sub get { my ($s, $k) = @_; return $PREFS{$k}; }
        sub set { my ($s, $k, $v) = @_; $PREFS{$k} = $v; }
        sub remove { my ($s, $k) = @_; delete $PREFS{$k}; }
        sub all { return \%PREFS; }
        sub init { my ($s, $defaults) = @_; %PREFS = (%$defaults, %PREFS); }
        sub setChange {}
        sub client { shift }
    }

    # Mock Source
    $INC{"Slim/Player/Source.pm"} = 1;
    {
        package Slim::Player::Source;
        our $SONG_TIME = 0;
        sub songTime { $SONG_TIME }
    }

    # Mock Control Request
    $INC{"Slim/Control/Request.pm"} = 1;
    {
        package Slim::Control::Request;
        sub subscribe {}
        sub unsubscribe {}
    }

    $INC{"Slim/Menu/TrackInfo.pm"} = 1;
    { package Slim::Menu::TrackInfo; sub registerInfoProvider {} }
    $INC{"Slim/Menu/AlbumInfo.pm"} = 1;
    { package Slim::Menu::AlbumInfo; sub registerInfoProvider {} }
    $INC{"Slim/Menu/ArtistInfo.pm"} = 1;
    { package Slim::Menu::ArtistInfo; sub registerInfoProvider {} }
    $INC{"Slim/Menu/GlobalSearch.pm"} = 1;
    { package Slim::Menu::GlobalSearch; sub registerInfoProvider {} }

    $INC{"Slim/Utils/Cache.pm"} = 1; $INC{"Slim/Utils/DbCache.pm"} = 1;
    {
        package Slim::Utils::Cache;
        our %DATA;
        sub new { bless {}, shift }
        sub get { my ($s, $k) = @_; return $DATA{$k} }
        sub set { my ($s, $k, $v) = @_; $DATA{$k} = $v }
        sub remove { my ($s, $k) = @_; delete $DATA{$k} }
        package Slim::Utils::DbCache;
        sub new { bless {}, shift } sub db { bless {}, shift } sub prepare { bless {}, shift } sub execute {} sub fetchrow_array {} sub selectrow_array {}
    }

    $INC{"Audio/Scan.pm"} = 1;
    $INC{"Slim/Formats.pm"} = 1;
    $INC{"Slim/Utils/Strings.pm"} = 1;
    {
        package Slim::Utils::Strings;
        use Exporter 'import';
        our @EXPORT_OK = qw(cstring string);
        sub cstring {
            my ($client, $token) = @_;
            return $client->string($token) if $client && eval { $client->can('string') };
            return $token;
        }
        sub string { my ($token) = @_; return $token; }
    }

    $INC{"Slim/Plugin/OPMLBased.pm"} = 1;
    { package Slim::Plugin::OPMLBased; our $VERSION = '1.0'; sub initPlugin {} }
    $INC{"Slim/Plugin/Base.pm"} = 1;
    { package Slim::Plugin::Base; our $VERSION = '1.0'; }
    $INC{"Slim/Utils/PluginManager.pm"} = 1;
    { package Slim::Utils::PluginManager; sub isEnabled { 0 } }
    $INC{"Slim/Player/ProtocolHandlers.pm"} = 1;
    { package Slim::Player::ProtocolHandlers; sub registerHandler {} }
    $INC{"Slim/Player/Protocols/HTTPS.pm"} = 1;
    { package Slim::Player::Protocols::HTTPS; sub canSeek { 1 } sub requestString { 'MOCK_REQUEST' } }
    $INC{"Slim/Player/Sync.pm"} = 1;
    { package Slim::Player::Sync; our $IS_MASTER = 1; sub isMaster { $IS_MASTER } }
    $INC{"Slim/Schema.pm"} = 1;
    { package Slim::Schema; sub schema { bless {}, shift } }

    use FindBin;
    my $repo_dir = $FindBin::Bin . '/..';
    unshift @INC, sub {
        my ($self, $file) = @_;
        if ($file =~ s{^Plugins/yandex/}{}) {
            for my $dir ($repo_dir, '/home/chernysh/Projects/yandex') {
                if (-f "$dir/$file") {
                    open my $fh, "<", "$dir/$file" or return undef;
                    return $fh;
                }
            }
        }
        return undef;
    };
}

use Plugins::yandex::API::Common;
use Plugins::yandex::Plugin;
use Plugins::yandex::API::Async;

# Mocks for testing player and track structures
package MockTrack;
sub new {
    my ($class, $url, $duration) = @_;
    bless { url => $url, duration => $duration }, $class;
}
sub url { shift->{url} }
sub duration { shift->{duration} }

package MockSong;
sub new {
    my ($class, $track, $duration) = @_;
    bless { track => $track, duration => $duration }, $class;
}
sub track { shift->{track} }
sub duration { shift->{duration} }

package MockClient;
sub new {
    my ($class) = @_;
    bless {
        id => '00:04:20:11:22:33',
        power => 1,
        is_playing => 1,
        is_paused => 0,
        plugin_data => {},
        playing_song => undef,
    }, $class;
}
sub id { shift->{id} }
sub power { my $s = shift; if (@_) { $s->{power} = $_[0] } return $s->{power}; }
sub isPlaying { shift->{is_playing} }
sub isPaused { shift->{is_paused} }
sub isSynced { my $s = shift; if (@_) { $s->{is_synced} = $_[0] } return $s->{is_synced} || 0; }
sub pluginData {
    my $s = shift;
    my $k = shift;
    if (@_) { $s->{plugin_data}{$k} = $_[0] }
    return $s->{plugin_data}{$k};
}
sub playingSong { shift->{playing_song} }

package MockLMSRequest;
sub new {
    my ($class, $client, $req_array) = @_;
    bless { client => $client, req => $req_array }, $class;
}
sub client { shift->{client} }
sub getRequest {
    my ($self, $idx) = @_;
    return $self->{req}[$idx];
}

package MockRotorAPI;
sub send_play {}

package main;

# --------------------------------------------------------------------------
# Test 1: Verify Plugins::yandex::API::Common::get_iso_timestamp()
# --------------------------------------------------------------------------
{
    # 1a: Default call generates valid ISO 8601 UTC timestamp with milliseconds
    my $ts_now = Plugins::yandex::API::Common::get_iso_timestamp();
    ok(defined $ts_now, 'get_iso_timestamp() returns defined value');
    like($ts_now, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'Timestamp matches ISO 8601 UTC format (YYYY-MM-DDTHH:MM:SS.mmmZ)');

    # 1b: Explicit epoch seconds produces correct UTC time
    # 1700000000 = 2023-11-14T22:13:20Z
    my $ts_fixed = Plugins::yandex::API::Common::get_iso_timestamp(1700000000);
    is($ts_fixed, '2023-11-14T22:13:20.000Z', 'get_iso_timestamp(1700000000) produces exact UTC representation');

    # 1c: Explicit epoch seconds with milliseconds fraction
    my $ts_millis = Plugins::yandex::API::Common::get_iso_timestamp(1700000000.789);
    is($ts_millis, '2023-11-14T22:13:20.789Z', 'get_iso_timestamp with fractional seconds preserves milliseconds');
}

# --------------------------------------------------------------------------
# Test 2: Verify ProtocolHandler does NOT contain _get_current_timestamp
#         and Plugin.pm does NOT call it
# --------------------------------------------------------------------------
{
    ok(!Plugins::yandex::ProtocolHandler->can('_get_current_timestamp'), 'ProtocolHandler does not define _get_current_timestamp (preventing undefined sub calls)');
}

# --------------------------------------------------------------------------
# Test 3: _handleRotorFeedback trackStarted
# --------------------------------------------------------------------------
{
    my $client = MockClient->new();
    my @feedback_calls;

    my $mock_api = bless {}, 'MockRotorAPI';
    no warnings 'redefine';
    local *MockRotorAPI::rotor_session_feedback = sub {
        my ($self, $session_id, $batch_id, $event_type, $track_id, $total_played, $timestamp, $cb, $err_cb) = @_;
        push @feedback_calls, {
            session_id   => $session_id,
            batch_id     => $batch_id,
            event_type   => $event_type,
            track_id     => $track_id,
            total_played => $total_played,
            timestamp    => $timestamp,
        };
    };
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $mock_api; };

    # 3a: Track started with batch_id
    my $track_url = 'yandexmusic://track/100200?rotor_session=test_session_123&batch_id=batch_abc';
    my $mock_track = MockTrack->new($track_url, 180);
    my $mock_song = MockSong->new($mock_track, 180);
    $client->{playing_song} = $mock_song;

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'trackStarted');

    is(scalar(@feedback_calls), 1, 'rotor_session_feedback called once on trackStarted');
    is($feedback_calls[0]->{session_id}, 'test_session_123', 'radio session ID correctly extracted and unescaped');
    is($feedback_calls[0]->{batch_id}, 'batch_abc', 'batch ID correctly extracted and unescaped');
    is($feedback_calls[0]->{event_type}, 'trackStarted', 'event type is trackStarted');
    is($feedback_calls[0]->{track_id}, 100200, 'track ID is 100200');
    is($feedback_calls[0]->{total_played}, 0, 'total played seconds is 0 for trackStarted');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'trackStarted timestamp is valid ISO 8601 UTC');

    # 3b: Track started without batch_id
    @feedback_calls = ();
    my $track_url_nobatch = 'yandexmusic://555666?rotor_session=session_nobatch';
    $client->{playing_song} = MockSong->new(MockTrack->new($track_url_nobatch, 200), 200);

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'trackStarted');

    is(scalar(@feedback_calls), 1, 'rotor_session_feedback called when batch_id is absent');
    is($feedback_calls[0]->{session_id}, 'session_nobatch', 'radio session ID is session_nobatch');
    is($feedback_calls[0]->{batch_id}, undef, 'batch ID is undef when absent from URL');
    is($feedback_calls[0]->{track_id}, 555666, 'track ID is 555666');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'timestamp is valid ISO 8601 UTC');

    # 3c: URI-encoded rotor_session and batch_id
    @feedback_calls = ();
    my $track_url_encoded = 'yandexmusic://777888?rotor_session=sess%2Fsub%3A1&batch_id=batch%20special%2B1';
    $client->{playing_song} = MockSong->new(MockTrack->new($track_url_encoded, 150), 150);

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'trackStarted');

    is(scalar(@feedback_calls), 1, 'rotor_session_feedback called with encoded parameters');
    is($feedback_calls[0]->{session_id}, 'sess/sub:1', 'session ID properly unescaped');
    is($feedback_calls[0]->{batch_id}, 'batch special+1', 'batch ID properly unescaped');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'timestamp is valid ISO 8601 UTC');
}

# --------------------------------------------------------------------------
# Test 4: _handleRotorFeedback natural_finish
# --------------------------------------------------------------------------
{
    my $client = MockClient->new();
    my @feedback_calls;

    my $mock_api = bless {}, 'MockRotorAPI';
    no warnings 'redefine';
    local *MockRotorAPI::rotor_session_feedback = sub {
        my ($self, $session_id, $batch_id, $event_type, $track_id, $total_played, $timestamp, $cb, $err_cb) = @_;
        push @feedback_calls, {
            session_id   => $session_id,
            batch_id     => $batch_id,
            event_type   => $event_type,
            track_id     => $track_id,
            total_played => $total_played,
            timestamp    => $timestamp,
        };
    };
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $mock_api; };

    # Setup client with active radio track
    $client->pluginData('yandex_track_active', 1);
    $client->pluginData('yandex_radio_url', 'yandexmusic://track/300400?rotor_session=nat_session&batch_id=nat_batch');
    $client->pluginData('yandex_track_duration', 215);

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'natural_finish');

    is(scalar(@feedback_calls), 1, 'rotor_session_feedback called once on natural_finish');
    is($feedback_calls[0]->{session_id}, 'nat_session', 'session ID is nat_session');
    is($feedback_calls[0]->{batch_id}, 'nat_batch', 'batch ID is nat_batch');
    is($feedback_calls[0]->{event_type}, 'trackFinished', 'event type is trackFinished');
    is($feedback_calls[0]->{track_id}, 300400, 'track ID is 300400');
    is($feedback_calls[0]->{total_played}, 215, 'total played seconds equals track duration on natural finish');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'natural_finish timestamp is valid ISO 8601 UTC');
    is($client->pluginData('yandex_track_active'), 0, 'yandex_track_active reset to 0 after feedback');

    # Subsequent call when yandex_track_active is 0 must NOT send feedback
    @feedback_calls = ();
    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'natural_finish');
    is(scalar(@feedback_calls), 0, 'no feedback sent when yandex_track_active is 0');
}

# --------------------------------------------------------------------------
# Test 5: _handleRotorFeedback manual_skip_or_stop (skip vs finish threshold)
# --------------------------------------------------------------------------
{
    my $client = MockClient->new();
    my @feedback_calls;

    my $mock_api = bless {}, 'MockRotorAPI';
    no warnings 'redefine';
    local *MockRotorAPI::rotor_session_feedback = sub {
        my ($self, $session_id, $batch_id, $event_type, $track_id, $total_played, $timestamp, $cb, $err_cb) = @_;
        push @feedback_calls, {
            session_id   => $session_id,
            batch_id     => $batch_id,
            event_type   => $event_type,
            track_id     => $track_id,
            total_played => $total_played,
            timestamp    => $timestamp,
        };
    };
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $mock_api; };

    # 5a: Skip (> 2s and < 90% duration)
    $client->pluginData('yandex_track_active', 1);
    $client->pluginData('yandex_radio_url', 'yandexmusic://track/500600?rotor_session=skip_sess&batch_id=skip_batch');
    $client->pluginData('yandex_track_duration', 100);
    $Slim::Player::Source::SONG_TIME = 45; # 45s < 90s threshold

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'manual_skip_or_stop');

    is(scalar(@feedback_calls), 1, 'rotor_session_feedback called once on manual skip');
    is($feedback_calls[0]->{session_id}, 'skip_sess', 'session ID matches');
    is($feedback_calls[0]->{event_type}, 'skip', 'event type is skip');
    is($feedback_calls[0]->{track_id}, 500600, 'track ID is 500600');
    is($feedback_calls[0]->{total_played}, 45, 'total played seconds is 45');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'skip timestamp is valid ISO 8601 UTC');
    is($client->pluginData('yandex_track_active'), 0, 'yandex_track_active reset to 0');

    # 5b: Skip threshold reached (>= 90% duration) -> treated as trackFinished
    @feedback_calls = ();
    $client->pluginData('yandex_track_active', 1);
    $client->pluginData('yandex_radio_url', 'yandexmusic://track/500600?rotor_session=skip_sess&batch_id=skip_batch');
    $client->pluginData('yandex_track_duration', 100);
    $Slim::Player::Source::SONG_TIME = 92; # 92s >= 90s threshold

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'manual_skip_or_stop');

    is(scalar(@feedback_calls), 1, 'rotor_session_feedback called when >= 90% duration');
    is($feedback_calls[0]->{event_type}, 'trackFinished', 'type is trackFinished when >= 90% played');
    is($feedback_calls[0]->{total_played}, 92, 'total played seconds is 92');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'timestamp is valid ISO 8601 UTC');
    is($client->pluginData('yandex_track_active'), 0, 'yandex_track_active reset to 0');

    # 5c: Skip under 2 seconds -> ignored, no feedback sent
    @feedback_calls = ();
    $client->pluginData('yandex_track_active', 1);
    $client->pluginData('yandex_radio_url', 'yandexmusic://track/500600?rotor_session=skip_sess&batch_id=skip_batch');
    $client->pluginData('yandex_track_duration', 100);
    $Slim::Player::Source::SONG_TIME = 1; # 1s < 2s

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'manual_skip_or_stop');

    is(scalar(@feedback_calls), 0, 'no feedback sent when skip happens under 2 seconds');
    is($client->pluginData('yandex_track_active'), 0, 'yandex_track_active reset to 0 even if skip ignored');

    # 5d: Fallback to yandex_track_start_time when songTime is 0
    @feedback_calls = ();
    $client->pluginData('yandex_track_active', 1);
    $client->pluginData('yandex_radio_url', 'yandexmusic://track/500600?rotor_session=skip_sess&batch_id=skip_batch');
    $client->pluginData('yandex_track_duration', 100);
    $client->pluginData('yandex_track_start_time', time() - 25);
    $Slim::Player::Source::SONG_TIME = 0;

    Plugins::yandex::Plugin::_handleRotorFeedback($client, 'manual_skip_or_stop');

    is(scalar(@feedback_calls), 1, 'rotor_session_feedback called using start_time fallback');
    is($feedback_calls[0]->{event_type}, 'skip', 'event type is skip');
    ok($feedback_calls[0]->{total_played} >= 24 && $feedback_calls[0]->{total_played} <= 26, 'played seconds calculated from start_time (~25s)');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'timestamp is valid ISO 8601 UTC');
}

# --------------------------------------------------------------------------
# Test 6: Full LMS playerEventCallback integration (newsong -> jump -> newsong)
# --------------------------------------------------------------------------
{
    my $client = MockClient->new();
    my @feedback_calls;

    my $mock_api = bless {}, 'MockRotorAPI';
    no warnings 'redefine';
    local *MockRotorAPI::rotor_session_feedback = sub {
        my ($self, $session_id, $batch_id, $event_type, $track_id, $total_played, $timestamp, $cb, $err_cb) = @_;
        push @feedback_calls, {
            session_id   => $session_id,
            batch_id     => $batch_id,
            event_type   => $event_type,
            track_id     => $track_id,
            total_played => $total_played,
            timestamp    => $timestamp,
        };
    };
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $mock_api; };

    # 6a: newsong arrives with radio track URL
    my $radio_url_1 = 'yandexmusic://track/700100?rotor_session=flow_session&batch_id=flow_batch_1';
    my $song1 = MockSong->new(MockTrack->new($radio_url_1, 240), 240);
    $client->{playing_song} = $song1;

    my $req_newsong1 = MockLMSRequest->new($client, ['playlist', 'newsong']);
    Plugins::yandex::Plugin::playerEventCallback($req_newsong1);

    is(scalar(@feedback_calls), 1, 'playerEventCallback newsong triggered trackStarted feedback');
    is($feedback_calls[0]->{event_type}, 'trackStarted', 'event is trackStarted');
    is($feedback_calls[0]->{track_id}, 700100, 'track ID is 700100');
    is($feedback_calls[0]->{session_id}, 'flow_session', 'session ID is flow_session');
    is($feedback_calls[0]->{batch_id}, 'flow_batch_1', 'batch ID is flow_batch_1');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'timestamp is valid ISO 8601 UTC');
    is($client->pluginData('yandex_track_active'), 1, 'client track active flag set to 1');

    # 6b: User jumps / skips to next track: playerEventCallback(['playlist', 'jump'])
    @feedback_calls = ();
    $Slim::Player::Source::SONG_TIME = 60; # Played 60s of 240s
    my $req_jump = MockLMSRequest->new($client, ['playlist', 'jump']);
    Plugins::yandex::Plugin::playerEventCallback($req_jump);

    is(scalar(@feedback_calls), 1, 'playerEventCallback jump triggered skip feedback');
    is($feedback_calls[0]->{event_type}, 'skip', 'event is skip');
    is($feedback_calls[0]->{track_id}, 700100, 'track ID is 700100');
    is($feedback_calls[0]->{total_played}, 60, 'total played is 60s');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'jump timestamp is valid ISO 8601 UTC');
    is($client->pluginData('yandex_track_active'), 0, 'client track active flag reset to 0');

    # 6c: Next track starts (natural finish for track 2 later)
    @feedback_calls = ();
    my $radio_url_2 = 'yandexmusic://track/700200?rotor_session=flow_session&batch_id=flow_batch_2';
    my $song2 = MockSong->new(MockTrack->new($radio_url_2, 180), 180);
    $client->{playing_song} = $song2;
    $Slim::Player::Source::SONG_TIME = 0;

    my $req_newsong2 = MockLMSRequest->new($client, ['playlist', 'newsong']);
    Plugins::yandex::Plugin::playerEventCallback($req_newsong2);

    is(scalar(@feedback_calls), 1, 'second track newsong triggered trackStarted');
    is($feedback_calls[0]->{event_type}, 'trackStarted', 'event is trackStarted');
    is($feedback_calls[0]->{track_id}, 700200, 'track ID is 700200');

    # 6d: Third track arrives naturally (newsong) -> should trigger natural_finish for track 2 then trackStarted for track 3
    @feedback_calls = ();
    my $radio_url_3 = 'yandexmusic://track/700300?rotor_session=flow_session&batch_id=flow_batch_3';
    my $song3 = MockSong->new(MockTrack->new($radio_url_3, 200), 200);
    $client->{playing_song} = $song3;

    my $req_newsong3 = MockLMSRequest->new($client, ['playlist', 'newsong']);
    Plugins::yandex::Plugin::playerEventCallback($req_newsong3);

    is(scalar(@feedback_calls), 2, 'natural transition newsong triggered both trackFinished and trackStarted');
    is($feedback_calls[0]->{event_type}, 'trackFinished', 'first call was trackFinished for previous track');
    is($feedback_calls[0]->{track_id}, 700200, 'trackFinished was for track 700200');
    is($feedback_calls[0]->{total_played}, 180, 'total played was full duration (180s)');
    like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'trackFinished timestamp is valid ISO 8601 UTC');

    is($feedback_calls[1]->{event_type}, 'trackStarted', 'second call was trackStarted for new track');
    is($feedback_calls[1]->{track_id}, 700300, 'trackStarted was for track 700300');
    like($feedback_calls[1]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'trackStarted timestamp is valid ISO 8601 UTC');
}

# --------------------------------------------------------------------------
# Test 7: API/Async rotor_session_feedback parameter handling and fallback
# --------------------------------------------------------------------------
{
    my $async_api = Plugins::yandex::API::Async->new('fake_token');
    my @sent_requests;

    no warnings 'redefine';
    local *Plugins::yandex::API::Async::post = sub {
        my ($self, $url, $data, $cb, $err_cb) = @_;
        push @sent_requests, {
            url  => $url,
            body => $data,
        };
    };

    # 7a: rotor_session_feedback with explicit timestamp
    $async_api->rotor_session_feedback('session_api_1', 'batch_1', 'trackStarted', '999111', 0, '2026-11-06T12:00:00.000Z', sub {}, sub {});

    is(scalar(@sent_requests), 1, 'rotor_session_feedback posted request');
    like($sent_requests[0]->{url}, qr{/rotor/session/session_api_1/feedback$}, 'POST target URL matches rotor session endpoint');
    is($sent_requests[0]->{body}{event}{type}, 'trackStarted', 'event type in JSON matches');
    is($sent_requests[0]->{body}{event}{trackId}, '999111', 'trackId in JSON matches');
    is($sent_requests[0]->{body}{event}{timestamp}, '2026-11-06T12:00:00.000Z', 'explicit timestamp passed untouched');

    # 7b: rotor_session_feedback with undef timestamp (automatic fallback)
    @sent_requests = ();
    $async_api->rotor_session_feedback('session_api_2', 'batch_2', 'skip', '999222', 42, undef, sub {}, sub {});

    is(scalar(@sent_requests), 1, 'rotor_session_feedback posted request with fallback timestamp');
    is($sent_requests[0]->{body}{event}{type}, 'skip', 'event type is skip');
    is($sent_requests[0]->{body}{event}{trackId}, '999222', 'trackId is 999222');
    is($sent_requests[0]->{body}{event}{totalPlayedSeconds}, 42, 'totalPlayedSeconds is 42');
    like($sent_requests[0]->{body}{event}{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'fallback generated valid ISO 8601 UTC timestamp');
}

# --------------------------------------------------------------------------
# Test 8: Robustness & edge cases: safe dereferences and unauthenticated client
# --------------------------------------------------------------------------
{
    my $client = MockClient->new();
    my @feedback_calls;
    my $mock_api = bless {}, 'MockRotorAPI';
    no warnings 'redefine';
    local *MockRotorAPI::rotor_session_feedback = sub {
        my ($self, @args) = @_;
        push @feedback_calls, \@args;
    };

    # 8a: When getAPIForClient returns undef (e.g. unauthenticated or uninitialized),
    # _handleRotorFeedback must safely return without dying.
    {
        local *Plugins::yandex::Plugin::getAPIForClient = sub { return undef; };
        eval {
            Plugins::yandex::Plugin::_handleRotorFeedback($client, 'trackStarted');
            Plugins::yandex::Plugin::_handleRotorFeedback($client, 'natural_finish');
            Plugins::yandex::Plugin::_handleRotorFeedback($client, 'manual_skip_or_stop');
        };
        is($@, '', '_handleRotorFeedback handles undef API client gracefully without die');
        is(scalar(@feedback_calls), 0, 'No feedback sent when API client is undef');
    }

    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $mock_api; };

    # 8b: $song is defined, but $song->track() is undef.
    # Must not crash with "Can't call method 'url' on an undefined value".
    {
        @feedback_calls = ();
        $client->{playing_song} = MockSong->new(undef, 180);
        eval {
            Plugins::yandex::Plugin::_handleRotorFeedback($client, 'trackStarted');
        };
        is($@, '', '_handleRotorFeedback handles undefined song->track() safely without die');
        is(scalar(@feedback_calls), 0, 'No feedback sent when song->track() is undefined');
    }

    # 8c: URL does not contain track ID (e.g. malformed rotor URL)
    {
        @feedback_calls = ();
        my $bad_url = 'yandexmusic://invalid_no_track?rotor_session=sess_bad';
        $client->{playing_song} = MockSong->new(MockTrack->new($bad_url, 180), 180);
        eval {
            Plugins::yandex::Plugin::_handleRotorFeedback($client, 'trackStarted');
        };
        is($@, '', '_handleRotorFeedback handles URL without trackId safely');
        is(scalar(@feedback_calls), 0, 'No feedback sent when trackId cannot be parsed');
    }
}

# --------------------------------------------------------------------------
# Test 9: LMS playerEventCallback commands: stop, clear, and sync-slave checks
# --------------------------------------------------------------------------
{
    my $client = MockClient->new();
    my @feedback_calls;
    my $mock_api = bless {}, 'MockRotorAPI';
    no warnings 'redefine';
    local *MockRotorAPI::rotor_session_feedback = sub {
        my ($self, $session_id, $batch_id, $event_type, $track_id, $total_played, $timestamp, $cb, $err_cb) = @_;
        push @feedback_calls, {
            session_id   => $session_id,
            batch_id     => $batch_id,
            event_type   => $event_type,
            track_id     => $track_id,
            total_played => $total_played,
            timestamp    => $timestamp,
        };
    };
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $mock_api; };

    # 9a: 'stop' command triggers manual_skip_or_stop feedback
    {
        @feedback_calls = ();
        $client->pluginData('yandex_track_active', 1);
        $client->pluginData('yandex_radio_url', 'yandexmusic://track/888111?rotor_session=stop_sess&batch_id=stop_batch');
        $client->pluginData('yandex_track_duration', 120);
        $Slim::Player::Source::SONG_TIME = 50;

        my $req_stop = MockLMSRequest->new($client, ['stop']);
        Plugins::yandex::Plugin::playerEventCallback($req_stop);

        is(scalar(@feedback_calls), 1, 'stop command triggered rotor feedback');
        is($feedback_calls[0]->{event_type}, 'skip', 'event type is skip');
        is($feedback_calls[0]->{track_id}, 888111, 'track ID is 888111');
        is($feedback_calls[0]->{total_played}, 50, 'played seconds recorded');
        like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'stop timestamp is valid ISO 8601 UTC');
        is($client->pluginData('yandex_track_active'), 0, 'yandex_track_active reset');
    }

    # 9b: 'clear' command triggers manual_skip_or_stop feedback
    {
        @feedback_calls = ();
        $client->pluginData('yandex_track_active', 1);
        $client->pluginData('yandex_radio_url', 'yandexmusic://track/888222?rotor_session=clear_sess&batch_id=clear_batch');
        $client->pluginData('yandex_track_duration', 200);
        $Slim::Player::Source::SONG_TIME = 195; # >= 90% -> trackFinished

        my $req_clear = MockLMSRequest->new($client, ['playlist', 'clear']);
        Plugins::yandex::Plugin::playerEventCallback($req_clear);

        is(scalar(@feedback_calls), 1, 'clear command triggered rotor feedback');
        is($feedback_calls[0]->{event_type}, 'trackFinished', 'type is trackFinished when >= 90%');
        is($feedback_calls[0]->{track_id}, 888222, 'track ID is 888222');
        is($feedback_calls[0]->{total_played}, 195, 'total played is 195s');
        like($feedback_calls[0]->{timestamp}, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$}, 'clear timestamp is valid ISO 8601 UTC');
    }

    # 9c: Synced slave client: must NOT process newsong or send feedback
    {
        @feedback_calls = ();
        $client->isSynced(1);
        $Slim::Player::Sync::IS_MASTER = 0; # Slave player

        my $song_slave = MockSong->new(MockTrack->new('yandexmusic://track/888333?rotor_session=slave_sess', 180), 180);
        $client->{playing_song} = $song_slave;

        my $req_slave = MockLMSRequest->new($client, ['playlist', 'newsong']);
        Plugins::yandex::Plugin::playerEventCallback($req_slave);

        is(scalar(@feedback_calls), 0, 'Synced slave player ignored newsong; no feedback sent');

        # Restore sync state
        $client->isSynced(0);
        $Slim::Player::Sync::IS_MASTER = 1;
    }

    # 9d: Non-rotor track newsong: must NOT trigger rotor feedback
    {
        @feedback_calls = ();
        $client->pluginData('yandex_track_active', 0);
        my $song_non_rotor = MockSong->new(MockTrack->new('yandexmusic://album/555/track/999', 180), 180);
        $client->{playing_song} = $song_non_rotor;

        my $req_non_rotor = MockLMSRequest->new($client, ['playlist', 'newsong']);
        Plugins::yandex::Plugin::playerEventCallback($req_non_rotor);

        is(scalar(@feedback_calls), 0, 'Non-rotor track newsong does not send rotor feedback');
        is($client->pluginData('yandex_track_active'), 0, 'track active remains 0');
    }
}
