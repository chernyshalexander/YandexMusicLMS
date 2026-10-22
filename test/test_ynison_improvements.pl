#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib '/usr/share/squeezeboxserver/CPAN';
use Test::More tests => 18;

# Mock Slim framework and environment cleanly
BEGIN {
    for my $c (qw(SCANNER PERFMON DEBUGLOG INFOLOG STATISTICS ISWINDOWS ISMAC RESIZER WEBUI NOMYSB TRANSCODING SB1SLIMP3SYNC LOCALFILE NOBROWSECACHE SLIM_SERVICE NOUPNP ISACTIVEPERL HAS_AIO)) {
        no strict "refs"; *{"main::$c"} = sub () { 0 };
    }
    
    # Mock Log
    $INC{"Slim/Utils/Log.pm"} = 1;
    {
        package MockLog;
        sub info {} sub error {} sub warn {} sub debug {} sub is_debug { 0 }
        package Slim::Utils::Log;
        sub logger { bless {}, 'MockLog' }
        sub import {
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::logger"} = \&logger;
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
    }

    # Mock other Slim modules used by Plugin / Ynison
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
        sub get { 0 } sub set {} sub init {}
    }

    $INC{"Slim/Player/Source.pm"} = 1;
    {
        package Slim::Player::Source;
        sub songTime { 0 }
    }

    $INC{"Slim/Control/Request.pm"} = 1;
    {
        package Slim::Control::Request;
        sub subscribe {}
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
        package Slim::Utils::Cache; sub new { bless {}, shift } sub get { undef } sub set {}
        package Slim::Utils::DbCache; sub new { bless {}, shift } sub db { bless {}, shift } sub prepare { bless {}, shift } sub execute {} sub fetchrow_array {} sub selectrow_array {}
    }
    $INC{"Slim/Plugin/OPMLBased.pm"} = 1;
    { package Slim::Plugin::OPMLBased; our $VERSION = '1.0'; }
    $INC{"Slim/Utils/PluginManager.pm"} = 1;
    { package Slim::Utils::PluginManager; sub isEnabled { 0 } }
    unshift @INC, sub {
        my ($self, $file) = @_;
        if ($file =~ s{^Plugins/yandex/}{}) {
            if (-f "/home/chernysh/Projects/yandex/$file") {
                open my $fh, "<", "/home/chernysh/Projects/yandex/$file" or return undef;
                return $fh;
            }
        }
        return undef;
    };
}

# Load Ynison module
require Plugins::yandex::Ynison;

# Mock client for Ynison
package MockClient;
sub new { bless { id => 'player_001', name => 'Boom', vol => 75 }, shift }
sub id { shift->{id} }
sub name { shift->{name} }
sub volume { shift->{vol} }
sub string { return $_[1] }

package main;

my $client = MockClient->new();
my $ynison = bless {
    client => $client,
    device_id => 'test_device_123',
    reconnect_scheduled => undef,
    reconnect_reason => undef,
    reconnect_delay => 0,
    state => Plugins::yandex::Ynison::STATE_ACTIVE(),
    sent_commands => [],
}, 'Plugins::yandex::Ynison';

# Mock send_command
{
    no warnings 'redefine';
    *Plugins::yandex::Ynison::send_command = sub {
        my ($self, $cmd) = @_;
        push @{ $self->{sent_commands} }, $cmd;
    };
    *Plugins::yandex::Ynison::is_connected = sub { 1 };
}

# ---------------------------------------------------------------------------
# Test 1-4: Dynamic Progress Interpolation (get_current_progress_ms)
# ---------------------------------------------------------------------------
{
    # 1. Paused status does not advance
    my $st_paused = {
        progress_ms => "30000",
        duration_ms => "180000",
        paused => 1,
        version => { timestamp_ms => "1000000" }
    };
    my $prog = $ynison->get_current_progress_ms($st_paused, 1010000);
    is($prog, 30000, "Progress when paused stays fixed at progress_ms");

    # 2. Playing status interpolates elapsed time
    my $st_playing = {
        progress_ms => "30000",
        duration_ms => "180000",
        paused => 0,
        playback_speed => 1.0,
        version => { timestamp_ms => "1000000" }
    };
    $prog = $ynison->get_current_progress_ms($st_playing, 1010000); # +10s
    is($prog, 40000, "Progress when playing adds elapsed time (30s + 10s = 40s)");

    # 3. Playing status with speed 1.5
    my $st_speed = {
        progress_ms => "30000",
        duration_ms => "180000",
        paused => 0,
        playback_speed => 1.5,
        version => { timestamp_ms => "1000000" }
    };
    $prog = $ynison->get_current_progress_ms($st_speed, 1010000); # +10s * 1.5 = +15s
    is($prog, 45000, "Progress with playback_speed 1.5 scales correctly (30s + 15s = 45s)");

    # 4. Progress clamping to duration
    my $st_overflow = {
        progress_ms => "170000",
        duration_ms => "180000",
        paused => 0,
        playback_speed => 1.0,
        version => { timestamp_ms => "1000000" }
    };
    $prog = $ynison->get_current_progress_ms($st_overflow, 1030000); # +30s -> 200s, max 180s
    is($prog, 180000, "Progress is clamped to duration_ms");
}

# ---------------------------------------------------------------------------
# Test 5-8: Volume request builder & debounced send (build_set_volume_request)
# ---------------------------------------------------------------------------
{
    my $vol_cmd = $ynison->build_set_volume_request(0.65);
    ok(exists $vol_cmd->{update_volume_info}, "build_set_volume_request generates update_volume_info");
    is($vol_cmd->{update_volume_info}{device_id}, 'test_device_123', "target device_id matches self");
    is($vol_cmd->{update_volume_info}{volume_info}{volume}, 0.65, "volume float value is 0.65");

    my $clamped_low = $ynison->build_set_volume_request(-0.5);
    is($clamped_low->{update_volume_info}{volume_info}{volume}, 0.0, "volume < 0.0 clamped to 0.0");

    my $clamped_high = $ynison->build_set_volume_request(1.5);
    is($clamped_high->{update_volume_info}{volume_info}{volume}, 1.0, "volume > 1.0 clamped to 1.0");

    # Test debounced volume trigger
    $ynison->send_volume_update();
    ok(@Slim::Utils::Timers::timers > 0, "send_volume_update scheduled timer");
    my $timer = pop @Slim::Utils::Timers::timers;
    is($timer->{tag}, 'volume', "Timer tag is 'volume'");
    $timer->{cb}->($ynison); # Execute timer callback
    my $sent = pop @{ $ynison->{sent_commands} };
    is($sent->{update_volume_info}{volume_info}{volume}, 0.75, "Sent volume matches client volume (75/100 = 0.75)");
}

# ---------------------------------------------------------------------------
# Test 9-11: Queue Boundary Check in build_change_track_request
# ---------------------------------------------------------------------------
{
    my $state = {
        player_queue => {
            current_playable_index => 2,
            playable_list => [
                { playable_id => '1' },
                { playable_id => '2' },
                { playable_id => '3' }
            ]
        },
        status => { paused => 0 }
    };

    # Next track when at the end of queue (index 2 of 3)
    my $req_next = $ynison->build_change_track_request($state, 1);
    is($req_next, undef, "Next track at end of queue returns undef (no out-of-bounds request sent)");

    # Prev track when at the start of queue (index 0 of 3)
    $state->{player_queue}{current_playable_index} = 0;
    my $req_prev = $ynison->build_change_track_request($state, -1);
    is($req_prev, undef, "Prev track at start of queue returns undef (no out-of-bounds request sent)");

    # Valid step
    my $req_valid = $ynison->build_change_track_request($state, 1);
    ok(defined $req_valid, "Valid track change step within queue returns request");
    is($req_valid->{update_player_state}{player_state}{player_queue}{current_playable_index}, 1, "New index is 1");
}

# ---------------------------------------------------------------------------
# Test 12-14: Server Error Handling in _handle_state_message
# ---------------------------------------------------------------------------
{
    no warnings 'redefine';
    my $reconnected = 0;
    my $reconnect_reason = '';
    local *Plugins::yandex::Ynison::_schedule_reconnect = sub {
        my ($self, $reason) = @_;
        $reconnected++;
        $reconnect_reason = $reason;
    };

    # Error 400030002 (Queue boundary reached): must be ignored, NO reconnect
    $reconnected = 0;
    $ynison->_on_message_received({
        error => {
            message => 'Bad request: index out of range',
            details => { 'ynison-error-code' => '400030002' }
        }
    });
    is($reconnected, 0, "Server error 400030002 (Queue boundary) is gracefully ignored without reconnect");

    # Error 400090001 (Device displaced): must schedule reconnect with reason 'displaced'
    $reconnected = 0;
    $ynison->_on_message_received({
        error => {
            message => 'Device displaced',
            details => { 'ynison-error-code' => '400090001' }
        }
    });
    is($reconnect_reason, 'displaced', "Server error 400090001 triggers reconnect with reason 'displaced'");
}
