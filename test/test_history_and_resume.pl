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
    { package Slim::Player::Sync; sub isMaster { 1 } }
    $INC{"Slim/Schema.pm"} = 1;
    { package Slim::Schema; sub schema { bless {}, shift } }

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

use Plugins::yandex::Plugin;
use Plugins::yandex::Browse::History;
use Plugins::yandex::ProtocolHandler;

# --------------------------------------------------------------------------
# Test 1: _format_seconds helper in Browse::History
# --------------------------------------------------------------------------
{
    is(Plugins::yandex::Browse::History::_format_seconds(0), '0:00', 'format 0s -> 0:00');
    is(Plugins::yandex::Browse::History::_format_seconds(45), '0:45', 'format 45s -> 0:45');
    is(Plugins::yandex::Browse::History::_format_seconds(75), '1:15', 'format 75s -> 1:15');
    is(Plugins::yandex::Browse::History::_format_seconds(3600), '1:00:00', 'format 3600s -> 1:00:00');
    is(Plugins::yandex::Browse::History::_format_seconds(3675), '1:01:15', 'format 3675s -> 1:01:15');
}

# --------------------------------------------------------------------------
# Test 2: _flatten_album_tracks helper in Browse::History
# --------------------------------------------------------------------------
{
    my $album_volumes = {
        volumes => [
            [ { id => 101, title => 'Ch1' }, { id => 102, title => 'Ch2' } ],
            [ { id => 103, title => 'Ch3' } ]
        ]
    };
    my @flattened = Plugins::yandex::Browse::History::_flatten_album_tracks($album_volumes);
    is(scalar(@flattened), 3, 'Flattened 3 tracks across 2 volumes');
    is($flattened[0]->{id}, 101, 'First track is 101');
    is($flattened[2]->{id}, 103, 'Third track is 103');

    my $album_single = {
        tracks => [ { id => 201, title => 'Part1' }, { id => 202, title => 'Part2' } ]
    };
    my @flattened2 = Plugins::yandex::Browse::History::_flatten_album_tracks($album_single);
    is(scalar(@flattened2), 2, 'Flattened single volume tracks');
}

# --------------------------------------------------------------------------
# Test 3: _calculate_resume_point (0-based, 1-based, missing position, finished)
# --------------------------------------------------------------------------
{
    # Album duration 1000s, durationLeft 400s -> elapsed 600s.
    # Track 0: durationMs 200_000 (200s)
    # Track 1: durationMs 300_000 (300s) -> total preceding 500s
    # Track 2: durationMs 500_000 (500s) -> elapsed in track 2 = 600 - 500 = 100s
    my @tracks = (
        { id => 1, durationMs => 200_000 },
        { id => 2, durationMs => 300_000 },
        { id => 3, durationMs => 500_000 },
    );

    # 3a: 0-based trackPosition { volume => 0, index => 2 }
    my $album_0based = {
        durationSec   => 1000,
        durationLeft  => 400,
        trackPosition => { index => 2, volume => 0 },
        volumes       => [ \@tracks ],
    };
    my ($idx, $offset) = Plugins::yandex::Browse::History::_calculate_resume_point($album_0based, \@tracks);
    is($idx, 2, '0-based: Calculated target index 2');
    is($offset, 100, '0-based: Calculated offset 100s into chapter 2');

    # 3b: 1-based trackPosition { volume => 1, index => 3 } (real Yandex API format)
    my $album_1based = {
        durationSec   => 1000,
        durationLeft  => 400,
        trackPosition => { index => 3, volume => 1 },
        volumes       => [ \@tracks ],
    };
    my ($idx1, $offset1) = Plugins::yandex::Browse::History::_calculate_resume_point($album_1based, \@tracks);
    is($idx1, 2, '1-based: Calculated target index 2');
    is($offset1, 100, '1-based: Calculated offset 100s into chapter 2');

    # 3c: Missing trackPosition fallback to cumulative duration
    my $album_nopos = {
        durationSec  => 1000,
        durationLeft => 400,
        volumes      => [ \@tracks ],
    };
    my ($idx_nopos, $offset_nopos) = Plugins::yandex::Browse::History::_calculate_resume_point($album_nopos, \@tracks);
    is($idx_nopos, 2, 'Missing trackPosition: Correctly derived target index 2 from elapsed duration');
    is($offset_nopos, 100, 'Missing trackPosition: Correctly derived offset 100s');

    # 3d: Multi-volume 1-based indexing
    # Volume 1: Track 10 (150s), Track 20 (150s)
    # Volume 2: Track 30 (300s) -> total preceding 300s, target in Volume 2 is Track 30
    my @vol1 = ({ id => 10, durationMs => 150_000 }, { id => 20, durationMs => 150_000 });
    my @vol2 = ({ id => 30, durationMs => 300_000 });
    my @all_multi = (@vol1, @vol2);
    my $album_multi = {
        durationSec   => 600,
        durationLeft  => 250, # elapsed 350s -> 50s into Vol 2 Track 1
        trackPosition => { volume => 2, index => 1 },
        volumes       => [ \@vol1, \@vol2 ],
    };
    my ($idx_m, $offset_m) = Plugins::yandex::Browse::History::_calculate_resume_point($album_multi, \@all_multi);
    is($idx_m, 2, 'Multi-volume 1-based: target index in flattened array is 2');
    is($offset_m, 50, 'Multi-volume 1-based: offset is 50s into volume 2 track 1');

    # 3e: When listening is finished
    $album_0based->{listeningFinished} = 1;
    my ($idx_fin, $offset_fin) = Plugins::yandex::Browse::History::_calculate_resume_point($album_0based, \@tracks);
    is($idx_fin, 0, 'Finished album resets target index to 0');
    is($offset_fin, 0, 'Finished album resets offset to 0');

    # 3f: Track streamProgress fallback (e.g. Orwell album without root trackPosition/durationLeft)
    my @tracks_with_sp = (
        { id => 101, durationMs => 200_000, streamProgress => { everFinished => 1, endPositionSec => 200 } },
        { id => 102, durationMs => 300_000, streamProgress => { everFinished => 0, endPositionSec => 75 } },
        { id => 103, durationMs => 500_000 },
    );
    my $album_sp_fallback = {
        volumes => [ \@tracks_with_sp ],
    };
    my ($idx_sp, $offset_sp) = Plugins::yandex::Browse::History::_calculate_resume_point($album_sp_fallback, \@tracks_with_sp);
    is($idx_sp, 1, 'Track streamProgress fallback: Target index 1');
    is($offset_sp, 75, 'Track streamProgress fallback: Offset 75s');
}

# --------------------------------------------------------------------------
# Test 4: ProtocolHandler canSeek, getSeekData, and bitrate recalculation
# --------------------------------------------------------------------------
{
    package MockSong;
    sub new { bless { bitrate => $_[1], duration => $_[2], seekdata => {}, startOffset => 0, pluginData => {}, initialAudioBlock => undef }, shift }
    sub bitrate { $_[0]->{bitrate} }
    sub duration { $_[0]->{duration} }
    sub seekdata { my $s = shift; if (@_) { $s->{seekdata} = $_[0] } return $s->{seekdata}; }
    sub startOffset { my $s = shift; if (@_) { $s->{startOffset} = $_[0] } return $s->{startOffset}; }
    sub initialAudioBlock { my $s = shift; if (@_) { $s->{initialAudioBlock} = $_[0] } return $s->{initialAudioBlock}; }
    sub pluginData { my $s = shift; if (@_ > 1) { $s->{pluginData}{$_[0]} = $_[1] } return $s->{pluginData}{$_[0]}; }
    sub master { undef }
    sub currentTrack { $_[0]->{currentTrack} }
    sub track { $_[0]->{currentTrack} || $_[0]->{track} }

    package MockTrack;
    sub new { bless { url => $_[1], duration => $_[2] }, shift }
    sub url { $_[0]->{url} }
    sub duration { $_[0]->{duration} }

    package main;

    my $song = MockSong->new(320000, 180);
    ok(Plugins::yandex::ProtocolHandler->canSeek(undef, $song), 'ProtocolHandler canSeek is true when duration is known');

    my $seek = Plugins::yandex::ProtocolHandler->getSeekData(undef, $song, 60);
    ok(defined $seek, 'getSeekData returned hash');
    is($seek->{timeOffset}, 60, 'timeOffset is 60');
    # 320000 / 8 * 60 = 2400000 bytes
    is($seek->{sourceStreamOffset}, 2400000, 'sourceStreamOffset is 2400000 bytes');
    is($seek->{sourceStreamOffset} % 16, 0, 'sourceStreamOffset is aligned to 16 bytes');

    # FLAC bitrate fallback (900000 bps)
    my $flac_song = MockSong->new(0, 300);
    my $flac_seek = Plugins::yandex::ProtocolHandler->getSeekData(undef, $flac_song, 10);
    # 900000 / 8 * 10 = 1125000; 1125000 % 16 = 8; 1125000 - 8 = 1124992
    is($flac_seek->{sourceStreamOffset}, 1124992, 'FLAC fallback offset calculated and 16-byte aligned');

    # canSeek duration fallback from track
    my $song_dur_fallback = MockSong->new(0, 0);
    $song_dur_fallback->{currentTrack} = MockTrack->new('yandexmusic://999', 240);
    ok(Plugins::yandex::ProtocolHandler->canSeek(undef, $song_dur_fallback), 'canSeek succeeds using track duration fallback');
}

# --------------------------------------------------------------------------
# Test 5: ProtocolHandler getNextTrack URL offset parsing & bitrate refresh
# --------------------------------------------------------------------------
{
    my $track = MockTrack->new('yandexmusic://123456?album_id=789&offset=150', 300);
    my $song = MockSong->new(0, 300);
    $song->{currentTrack} = $track;

    # Mock _resolveStreamUrl to simulate stream resolution providing 192kbps MP3
    no warnings 'redefine';
    local *Plugins::yandex::ProtocolHandler::_resolveStreamUrl = sub {
        my ($class, $s, $cb, $err_cb) = @_;
        # Cache resolved metadata for track 123456
        Slim::Utils::Cache->new()->set('yandex_meta_123456', { bitrate => 192000, codec => 'mp3' });
        $cb->();
    };

    Plugins::yandex::ProtocolHandler->getNextTrack($song, sub {}, sub {});

    is($song->startOffset(), 150, 'startOffset set to 150 from URL');
    is($song->seekdata()->{timeOffset}, 150, 'seekdata timeOffset set to 150');
    # 192000 / 8 * 150 = 3600000 bytes (aligned to 16)
    is($song->seekdata()->{sourceStreamOffset}, 3600000, 'sourceStreamOffset was refreshed with resolved 192kbps MP3 bitrate');
    is($song->initialAudioBlock(), '', 'initialAudioBlock set to empty string to prevent MP3.pm undef crash');
}

# --------------------------------------------------------------------------
# Test 6: Browse::History handleBookMenu menu generation (unfinished vs finished)
# --------------------------------------------------------------------------
{
    my $mock_album = {
        id           => 999,
        title        => 'Test Audiobook',
        durationSec  => 600,
        durationLeft => 300, # halfway through (300s elapsed)
        trackPosition => { index => 1, volume => 0 },
        volumes => [
            [
                { id => 10, title => 'Intro', durationMs => 100_000 },
                { id => 20, title => 'Chapter 1', durationMs => 300_000 },
                { id => 30, title => 'Chapter 2', durationMs => 200_000 },
            ]
        ]
    };

    package MockAPI;
    sub new { bless { album => $_[1], checks => $_[2] }, shift }
    sub get_album_with_tracks {
        my ($self, $album_id, $cb, $err_cb, $params) = @_;
        if ($self->{checks}) {
            $self->{checks}->($album_id, $params);
        }
        $cb->($self->{album});
    }
    package MockClient;
    sub new { my ($cls, %args) = @_; bless { id => '00:04:20:11:22:33', name => 'TestClient', executed => [], %args }, $cls }
    sub id { shift->{id} }
    sub name { shift->{name} }
    sub model { shift->{model} }
    sub string {
        my ($self, $token) = @_;
        my %dict = (
            'PLUGIN_YANDEX_RESUME_CHAPTER_AT'  => 'Продолжить: Глава %s (с %s)',
            'PLUGIN_YANDEX_PLAY_FROM_START'    => 'Слушать с начала (Глава 1)',
            'PLUGIN_YANDEX_TABLE_OF_CONTENTS'  => 'Оглавление (Список глав)',
            'PLUGIN_YANDEX_MARK_FINISHED'      => 'Отметить как прочитанное',
            'PLUGIN_YANDEX_QUICK_RESUME'       => '[▶] Продолжить: %s',
            'PLUGIN_YANDEX_QUICK_RESUME_BASIC' => '[>] Продолжить: %s',
            'PLUGIN_YANDEX_ALBUM'              => 'Альбом',
            'PLUGIN_YANDEX_ARTIST'             => 'Артист',
            'PLUGIN_YANDEX_PLAYLIST'           => 'Плейлист',
            'PLUGIN_YANDEX_RADIO'              => 'Радио',
        );
        return $dict{$token} // $token;
    }
    package main;

    my $mock_api = MockAPI->new($mock_album, sub {
        my ($album_id, $params) = @_;
        is($album_id, 999, 'Requested correct album ID');
        is($params->{resumeStream}, 'true', 'resumeStream parameter is true');
    });

    my $client = MockClient->new();
    my $result_menu;
    Plugins::yandex::Browse::History::handleBookMenu(
        $client,
        sub { $result_menu = shift; },
        {},
        $mock_api,
        999
    );

    ok(defined $result_menu, 'handleBookMenu returned menu for unfinished book');
    is($result_menu->{title}, 'Test Audiobook', 'Menu title is book title');
    is(scalar(@{$result_menu->{items}}), 4, 'Unfinished book contains 4 items');
    like($result_menu->{items}[0]->{name}, qr/Глава 2|Chapter 2/, 'First item is Resume Chapter 2');
    like($result_menu->{items}[0]->{name}, qr/3:20/, 'First item contains offset 3:20 (200s)');
    is($result_menu->{items}[0]->{nextWindow}, 'nowPlaying', 'Resume action has nextWindow nowPlaying');
    like($result_menu->{items}[1]->{name}, qr/Глава 1|Chapter 1|start/i, 'Second item is Listen from start');
    like($result_menu->{items}[2]->{name}, qr/Оглавление|Table of contents/i, 'Third item is Table of contents');
    like($result_menu->{items}[3]->{name}, qr/Отметить|Mark as finished/i, 'Fourth item is Mark finished');

    # 6b: Finished book menu: should have 3 items (NO duplicate "Listen from beginning")
    $mock_album->{listeningFinished} = 1;
    my $result_menu_fin;
    Plugins::yandex::Browse::History::handleBookMenu(
        $client,
        sub { $result_menu_fin = shift; },
        {},
        $mock_api,
        999
    );
    is(scalar(@{$result_menu_fin->{items}}), 3, 'Finished book contains 3 items (no duplicate item)');
    like($result_menu_fin->{items}[0]->{name}, qr/Глава 1|Chapter 1|start/i, 'First item is Listen from start');
}

# --------------------------------------------------------------------------
# Test 7: Browse::History handleResumeBookAction queuing and jumping
# --------------------------------------------------------------------------
{
    my @executed_commands;
    package MockClient2;
    sub new { bless {}, shift }
    sub id { '00:04:20:11:22:33' }
    sub name { 'TestClient2' }
    sub string { return $_[1] }
    sub execute {
        my ($self, $cmd) = @_;
        push @executed_commands, $cmd;
    }
    package main;

    my $mock_album = {
        id      => 888,
        title   => 'Queued Book',
        volumes => [
            [
                { id => 101, title => 'Ch 1' },
                { id => 102, title => 'Ch 2' },
                { id => 103, title => 'Ch 3' },
            ]
        ]
    };
    my $mock_api = MockAPI->new($mock_album);

    my $client = MockClient2->new();
    @executed_commands = ();
    my $resume_cb_res;

    Plugins::yandex::Browse::History::handleResumeBookAction(
        $client,
        sub { $resume_cb_res = shift; },
        {},
        $mock_api,
        888,
        1,   # start at chapter index 1 (Ch 2)
        75   # offset 75s
    );

    is($executed_commands[0]->[0], 'playlist', 'First command is playlist');
    is($executed_commands[0]->[1], 'clear', 'First command clears playlist');

    # 3 playlist adds
    is($executed_commands[1]->[1], 'add', 'Second command adds track 1');
    is($executed_commands[1]->[2], 'yandexmusic://101?album_id=888&type=audiobook', 'Track 1 url without offset');

    is($executed_commands[2]->[1], 'add', 'Third command adds track 2');
    is($executed_commands[2]->[2], 'yandexmusic://102?album_id=888&type=audiobook&offset=75', 'Target track url includes &offset=75');

    is($executed_commands[3]->[1], 'add', 'Fourth command adds track 3');
    is($executed_commands[3]->[2], 'yandexmusic://103?album_id=888&type=audiobook', 'Track 3 url without offset');

    # Jump command
    is($executed_commands[4]->[1], 'jump', 'Fifth command jumps playlist');
    is($executed_commands[4]->[2], 1, 'Jumped to chapter index 1');
    is($executed_commands[4]->[5]->{timeOffset}, 75, 'Jump passed timeOffset => 75');

    is($resume_cb_res->{nextWindow}, 'nowPlaying', 'Resume action response specifies nextWindow nowPlaying');
}

# --------------------------------------------------------------------------
# Test 7b: Browse::History handleResumeBookAction on classic button clients (Boom, Classic, Transporter)
# --------------------------------------------------------------------------
{
    my @executed_commands;
    package MockClassicClient;
    sub new {
        my ($class, $stack) = @_;
        bless { modeStack => $stack || ['home', 'xmlbrowser', 'block'] }, $class;
    }
    sub id { '00:04:20:99:88:77' }
    sub name { 'TestBoom' }
    sub string { return $_[1] }
    sub modeStack { $_[0]->{modeStack} }
    sub update { $_[0]->{updated} = 1 }
    sub unblock {
        my $self = shift;
        if ($self->{modeStack} && @{$self->{modeStack}} && $self->{modeStack}->[-1] eq 'block') {
            pop @{$self->{modeStack}};
        }
    }
    sub execute {
        my ($self, $cmd) = @_;
        push @executed_commands, $cmd;
    }
    package main;

    my $mock_album = {
        id      => 888,
        title   => 'Queued Book',
        volumes => [
            [
                { id => 101, title => 'Ch 1' },
                { id => 102, title => 'Ch 2' },
                { id => 103, title => 'Ch 3' },
            ]
        ]
    };
    my $mock_api = MockAPI->new($mock_album);

    # 1. Hardware button trigger (isButton => 1) with block mode active during async fetch
    my $client = MockClassicClient->new(['home', 'xmlbrowser', 'block']);
    @executed_commands = ();
    my $resume_cb_res;

    Plugins::yandex::Browse::History::handleResumeBookAction(
        $client,
        sub { $resume_cb_res = shift; },
        { isButton => 1 },
        $mock_api,
        888,
        1,
        75
    );

    is(Slim::Buttons::Common::mode($client), 'playlist', 'Classic player transitions to playlist mode (Now Playing)');
    is_deeply($client->modeStack, ['home', 'playlist'], 'Mode stack has block unblocked, xmlbrowser popped, and playlist pushed');
    is($client->{updated}, 1, 'Client display update called');
    is($resume_cb_res->{nextWindow}, 'nowPlaying', 'Button response specifies nextWindow nowPlaying');
    is($resume_cb_res->{abort}, 1, 'Button response aborts OPML list generation');
    is($resume_cb_res->{command}, 'mode ?', 'Button response specifies safe mode ? command');
    ok(!exists $resume_cb_res->{items}, 'No dummy 1 of 1 items returned for classic players');

    # 2. handleQuickResumeBook with isButton => 1 and block mode active
    my $quick_client = MockClassicClient->new(['home', 'xmlbrowser', 'block']);
    @executed_commands = ();
    my $quick_cb_res;

    Plugins::yandex::Browse::History::handleQuickResumeBook(
        $quick_client,
        sub { $quick_cb_res = shift; },
        { isButton => 1 },
        $mock_api,
        888
    );

    is(Slim::Buttons::Common::mode($quick_client), 'playlist', 'Quick resume transitions classic player to playlist mode');
    is_deeply($quick_client->modeStack, ['home', 'playlist'], 'Quick resume stack has block unblocked, xmlbrowser popped, and playlist pushed');
    is($quick_cb_res->{abort}, 1, 'Quick resume aborts OPML list generation');
    ok(!exists $quick_cb_res->{items}, 'Quick resume has no dummy items');

    # 3. Web UI controlling classic player (isButton => 0):
    # Even if physical player was currently browsing in xmlbrowser mode,
    # physical player transitions to playlist mode, but Web UI strictly gets items array
    my $web_client = MockClassicClient->new(['home', 'xmlbrowser']);
    @executed_commands = ();
    my $web_cb_res;

    Plugins::yandex::Browse::History::handleResumeBookAction(
        $web_client,
        sub { $web_cb_res = shift; },
        {},
        $mock_api,
        888,
        0,
        0
    );

    is(Slim::Buttons::Common::mode($web_client), 'playlist', 'Web UI control transitions physical classic player to playlist mode');
    is_deeply($web_client->modeStack, ['home', 'playlist'], 'Physical player mode stack popped xmlbrowser and pushed playlist');
    is($web_cb_res->{nextWindow}, 'nowPlaying', 'Web response has nextWindow nowPlaying');
    ok(exists $web_cb_res->{items}, 'Web response retains items array for Web UI/Material skin (no crash in _cliQuery_done)');
    is(scalar(@{$web_cb_res->{items}}), 1, 'Web response contains 1 item');

    # 4. SqueezePlay client (isa Slim::Player::SqueezePlay)
    {
        package MockSPClient;
        our @ISA = qw(Slim::Player::SqueezePlay);
        sub new { bless { modeStack => [] }, shift }
        sub id { '00:04:20:11:22:33' }
        sub name { 'TestSP' }
        sub string { return $_[1] }
        sub modeStack { $_[0]->{modeStack} }
        sub execute { }
        package main;

        my $sp_client = MockSPClient->new();
        my $sp_cb_res;
        Plugins::yandex::Browse::History::handleResumeBookAction(
            $sp_client,
            sub { $sp_cb_res = shift; },
            {},
            $mock_api,
            888,
            0,
            0
        );
        is($sp_cb_res->{nextWindow}, 'nowPlaying', 'SqueezePlay gets nextWindow nowPlaying');
        ok(exists $sp_cb_res->{items}, 'SqueezePlay gets items array');
        is_deeply($sp_client->modeStack, [], 'SqueezePlay modeStack remains untouched');
    }
}

# --------------------------------------------------------------------------
# Test 8: Browse::History handleBookChaptersList
# --------------------------------------------------------------------------
{
    my $mock_album = {
        id      => 777,
        title   => 'Chapters Book',
        volumes => [
            [
                { id => 11, title => 'Introduction', durationMs => 120_000 },
                { id => 12, title => 'Chapter 1', durationMs => 360_000 },
            ]
        ]
    };
    my $mock_api = MockAPI->new($mock_album);
    my $client = MockClient->new();
    my $chapters_menu;

    Plugins::yandex::Browse::History::handleBookChaptersList(
        $client,
        sub { $chapters_menu = shift; },
        {},
        $mock_api,
        777
    );

    is(scalar(@{$chapters_menu->{items}}), 2, 'Chapters list has 2 items');
    is($chapters_menu->{items}[0]->{nextWindow}, 'nowPlaying', 'Chapter 1 has nextWindow nowPlaying');
    is($chapters_menu->{items}[1]->{nextWindow}, 'nowPlaying', 'Chapter 2 has nextWindow nowPlaying');
    is($chapters_menu->{items}[0]->{passthrough}[2], 0, 'Chapter 1 passthrough starts at idx 0');
    is($chapters_menu->{items}[1]->{passthrough}[2], 1, 'Chapter 2 passthrough starts at idx 1');
}

# --------------------------------------------------------------------------
# Test 9: Plugin playerEventCallback on jump vs natural finish & power off
# --------------------------------------------------------------------------
{
    package MockPlayerClient;
    sub new {
        bless {
            id => '00:04:20:99:88:77',
            power => 1,
            is_playing => 1,
            is_paused => 0,
            plugin_data => {},
            playing_song => undef,
        }, shift;
    }
    sub id { shift->{id} }
    sub power { my $s = shift; if (@_) { $s->{power} = $_[0] } return $s->{power}; }
    sub isPlaying { shift->{is_playing} }
    sub isPaused { shift->{is_paused} }
    sub isSynced { 0 }
    sub pluginData {
        my $s = shift;
        my $k = shift;
        if (@_) { $s->{plugin_data}{$k} = $_[0] }
        return $s->{plugin_data}{$k};
    }
    sub playingSong { shift->{playing_song} }
    sub string { MockClient::string(@_) }

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

    package main;

    my $player = MockPlayerClient->new();

    # Setup currently playing chapter
    $player->pluginData('yandex_curr_track_id', 5001);
    $player->pluginData('yandex_curr_album_id', 900);
    $player->pluginData('yandex_curr_is_chapter', 1);
    $player->pluginData('yandex_curr_duration', 300);
    $player->pluginData('yandex_curr_start_time', time() - 40);

    my @saved_progress;
    my @marked_finished;

    no warnings 'redefine';
    local *Plugins::yandex::Plugin::_save_current_progress = sub {
        my ($cli, $tid, $pos, $dur, $fin) = @_;
        push @saved_progress, { track_id => $tid, pos => $pos, dur => $dur, finished => $fin };
    };
    local *Plugins::yandex::Plugin::_mark_chapter_finished = sub {
        my ($cli, $tid) = @_;
        push @marked_finished, $tid;
    };

    $Slim::Player::Source::SONG_TIME = 45;

    # 9a: User jumps to another chapter: ['playlist', 'jump']
    my $jump_req = MockLMSRequest->new($player, ['playlist', 'jump']);
    Plugins::yandex::Plugin::playerEventCallback($jump_req);

    is(scalar(@saved_progress), 1, 'Progress saved on jump');
    is($saved_progress[0]->{finished}, 0, 'Progress on jump saved with finished=0');
    is($saved_progress[0]->{pos}, 45, 'Progress on jump saved at current songTime (45s)');
    is($player->pluginData('yandex_curr_track_id'), undef, 'yandex_curr_track_id cleared on jump');

    # 9b: Next track arrives after jump (newsong)
    # yandex_curr_track_id is undef, so newsong MUST NOT mark 5001 as finished!
    @saved_progress = ();
    @marked_finished = ();
    my $next_song_track = MockTrack->new('yandexmusic://5002?album_id=900&type=audiobook', 300);
    my $next_song = MockSong->new(0, 300);
    $next_song->{currentTrack} = $next_song_track;
    $player->{playing_song} = $next_song;

    my $newsong_req = MockLMSRequest->new($player, ['playlist', 'newsong']);
    Plugins::yandex::Plugin::playerEventCallback($newsong_req);

    is(scalar(@marked_finished), 0, 'newsong after jump DID NOT mark previous chapter finished');
    is($player->pluginData('yandex_curr_track_id'), 5002, 'newsong initialized track 5002');

    # 9c: Natural finish: next track arrives without prior jump
    my $third_song_track = MockTrack->new('yandexmusic://5003?album_id=900&type=audiobook', 300);
    my $third_song = MockSong->new(0, 300);
    $third_song->{currentTrack} = $third_song_track;
    $player->{playing_song} = $third_song;

    Plugins::yandex::Plugin::playerEventCallback($newsong_req);
    is(scalar(@marked_finished), 1, 'Natural finish marked chapter 5002 finished');
    is($marked_finished[0], 5002, 'Marked track 5002 finished');
    is(scalar(@saved_progress), 1, 'Natural finish saved progress with finished=1');
    is($saved_progress[0]->{finished}, 1, 'finished flag is 1 on natural finish');

    # 9d: Power off event: ['power', 0]
    @saved_progress = ();
    $player->power(0);
    my $power_req = MockLMSRequest->new($player, ['power', 0]);
    Plugins::yandex::Plugin::playerEventCallback($power_req);

    is(scalar(@saved_progress), 1, 'Power off triggered progress save');
    is($player->pluginData('yandex_curr_track_id'), undef, 'yandex_curr_track_id cleared on power off');
}

# --------------------------------------------------------------------------
# Test 10: API::Async endpoints (send_play, save_progress, bookshelf, history)
# --------------------------------------------------------------------------
{
    require Plugins::yandex::API::Async;
    my $api = Plugins::yandex::API::Async->new('dummy_token');

    my ($last_url, $last_body, $last_params);
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::post = sub {
        my ($self, $url, $body, $cb, $err_cb, $params) = @_;
        $last_url    = $url;
        $last_body   = $body;
        $last_params = $params;
        $cb->({ result => 'ok' }) if $cb;
    };
    local *Plugins::yandex::API::Async::get = sub {
        my ($self, $url, $params, $cb, $err_cb) = @_;
        $last_url    = $url;
        $last_params = $params;
        $cb->({ result => { historyTabs => [] } }) if $cb;
    };

    # 10a: send_play
    $api->send_play({ trackId => '123:456', totalPlayedSeconds => 35, trackLengthSeconds => 200 });
    like($last_url, qr{/plays$}, 'send_play hits /plays');
    is($last_body->{plays}[0]{trackId}, '123:456', 'send_play passed play trackId');
    ok(defined $last_body->{plays}[0]{playId}, 'send_play auto-generated playId UUID');
    is($last_body->{plays}[0]{from}, 'android-app', 'send_play set from android-app');
    is($last_body->{plays}[0]{totalPlayedSeconds}, 35, 'send_play totalPlayedSeconds');
    ok(defined $last_params->{clientNow}, 'send_play passed clientNow');
    ok(defined $last_params->{'client-now'}, 'send_play passed client-now');

    # 10b: save_stream_progress
    $api->save_stream_progress(12345, 120, 300, 0);
    like($last_url, qr{/streams/progress/sync$}, 'save_stream_progress hits sync');
    is($last_body->{trackStreams}[0]{trackId}, '12345', 'save_stream_progress trackId');
    is($last_body->{trackStreams}[0]{positionSec}, 120, 'save_stream_progress positionSec');
    is($last_body->{trackStreams}[0]{trackLengthSec}, 300, 'save_stream_progress trackLengthSec');
    is(${$last_body->{trackStreams}[0]{finished}}, 0, 'save_stream_progress finished is false');
    like($last_body->{lastSyncTimestamp}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/, 'lastSyncTimestamp has .SSSZ format');
    like($last_body->{trackStreams}[0]{timestamp}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/, 'trackStream timestamp has .SSSZ format');

    # 10c: mark_stream_finished
    $api->mark_stream_finished(12345);
    like($last_url, qr{/streams/progress/sync$}, 'mark_stream_finished hits sync');
    is($last_body->{trackStreams}[0]{trackId}, '12345', 'mark_stream_finished trackId');

    # 10d: mark_album_finished
    {
        no warnings 'redefine';
        local *Plugins::yandex::API::Async::get_album_with_tracks = sub {
            my ($s, $aid, $cb) = @_;
            $cb->({ tracks => [{ id => 101, durationMs => 60000 }] });
        };
        $api->mark_album_finished(777);
    }
    like($last_url, qr{/streams/progress/sync$}, 'mark_album_finished hits sync');
    is($last_body->{trackStreams}[0]{trackId}, '101', 'mark_album_finished trackId');

    # 10e: get_bookshelf_recently_played
    $api->get_bookshelf_recently_played(0, 20);
    like($last_url, qr{/non-music/bookshelf/recently-played$}, 'get_bookshelf_recently_played hits recently-played');
    is($last_params->{page}, 0, 'page is 0');
    is($last_params->{pageSize}, 20, 'pageSize is 20');

    # 10f: get_music_history
    $api->get_music_history(50);
    like($last_url, qr{/music-history$}, 'get_music_history hits /music-history');
    is($last_params->{fullModelsCount}, 50, 'fullModelsCount is 50');

    # 10g: post_music_history_items sends shortModels
    $api->post_music_history_items(['item1', 'item2']);
    like($last_url, qr{/music-history/items$}, 'post_music_history_items hits /music-history/items');
    is_deeply($last_body->{shortModels}, ['item1', 'item2'], 'post_music_history_items body includes shortModels');
}

# --------------------------------------------------------------------------
# Test 11: Music history context objects parsing (wave, album, artist, playlist)
# --------------------------------------------------------------------------
{
    require Plugins::yandex::Browse::History;

    my $mock_client = MockClient->new();

    # 11a: Wave context parsing
    my $wave_grp = {
        context => {
            type => 'wave',
            data => {
                fullModel => {
                    wave => { title => 'Моя волна по артисту' },
                },
                itemId => {
                    seeds => ['artist:12345'],
                },
            },
        },
    };
    my $wave_item = Plugins::yandex::Browse::History::_parse_history_context_item($mock_client, undef, $wave_grp);
    ok(defined $wave_item, 'Wave context item parsed');
    is($wave_item->{type}, 'audio', 'Wave item type is audio');
    is($wave_item->{play}, 'yandexmusic://rotor_session/artist:12345', 'Wave play URL matches seed');
    like($wave_item->{name}, qr{⚡}, 'Wave item name contains ⚡ emoji');

    # 11b: Album context parsing
    my $album_grp = {
        context => {
            type => 'album',
            data => {
                fullModel => {
                    album => {
                        id => 999,
                        title => 'Abbey Road',
                        artists => [{ name => 'The Beatles' }],
                        coverUri => 'avatars.yandex.net/get-music-content/123/%%',
                    },
                },
                itemId => { id => 999 },
            },
        },
    };
    my $album_item = Plugins::yandex::Browse::History::_parse_history_context_item($mock_client, undef, $album_grp);
    ok(defined $album_item, 'Album context item parsed');
    is($album_item->{type}, 'playlist', 'Album item type is playlist');
    is($album_item->{play}, 'yandexmusic://album/999', 'Album play URL matches album ID');
    like($album_item->{name}, qr{💿.*Abbey Road}, 'Album item name contains 💿 and title');

    # 11c: Artist context parsing
    my $artist_grp = {
        context => {
            type => 'artist',
            data => {
                fullModel => {
                    artist => {
                        id => 888,
                        name => 'Queen',
                        cover => { uri => 'avatars.yandex.net/get-music-content/456/%%' },
                    },
                },
                itemId => { id => 888 },
            },
        },
    };
    my $artist_item = Plugins::yandex::Browse::History::_parse_history_context_item($mock_client, undef, $artist_grp);
    ok(defined $artist_item, 'Artist context item parsed');
    is($artist_item->{type}, 'link', 'Artist item type is link');
    like($artist_item->{name}, qr{👤.*Queen}, 'Artist item name contains 👤 and name');

    # 11d: Playlist context parsing
    my $playlist_grp = {
        context => {
            type => 'playlist',
            data => {
                fullModel => {
                    playlist => {
                        uid => 111,
                        kind => 222,
                        title => 'Top Hits',
                        owner => { name => 'Yandex Music' },
                    },
                },
                itemId => { uid => 111, kind => 222 },
            },
        },
    };
    my $playlist_item = Plugins::yandex::Browse::History::_parse_history_context_item($mock_client, undef, $playlist_grp);
    ok(defined $playlist_item, 'Playlist context item parsed');
    is($playlist_item->{type}, 'playlist', 'Playlist item type is playlist');
    is($playlist_item->{play}, 'yandexmusic://playlist/111/222', 'Playlist play URL matches uid/kind');
    like($playlist_item->{name}, qr{📜.*Top Hits}, 'Playlist item name contains 📜 and title');

    # 11e: handleMusicHistoryDayTracks renders structured context items and tracks
    my $multi_context_tab = {
        date => '2026-10-29',
        items => [
            {
                context => {
                    type => 'wave',
                    data => {
                        fullModel => { wave => { title => 'Моя волна' } },
                        itemId => { seeds => ['user:onyourwave'] },
                    },
                },
                tracks => [
                    {
                        type => 'track',
                        data => {
                            fullModel => {
                                id => 7001,
                                title => 'Bohemian Rhapsody',
                                artists => [{ name => 'Queen' }],
                                durationMs => 354000,
                            },
                        },
                    },
                ],
            },
            {
                context => {
                    type => 'album',
                    data => {
                        fullModel => {
                            album => {
                                id => 7002,
                                title => 'Abbey Road',
                                artists => [{ name => 'The Beatles' }],
                            },
                        },
                    },
                },
                tracks => [
                    {
                        type => 'track',
                        data => {
                            fullModel => {
                                id => 7003,
                                title => 'Come Together',
                                artists => [{ name => 'The Beatles' }],
                                durationMs => 259000,
                            },
                        },
                    },
                ],
            },
        ],
    };

    my $day_result;
    Plugins::yandex::Browse::History::handleMusicHistoryDayTracks(
        $mock_client,
        sub { $day_result = shift; },
        {},
        undef,
        $multi_context_tab
    );

    ok(defined $day_result && $day_result->{items}, 'Day tracks callback received items');
    is(scalar(@{$day_result->{items}}), 4, 'Day list contains 4 items: 2 context headers + 2 tracks');
    like($day_result->{items}[0]{name}, qr{⚡.*Моя волна}, 'First item is Wave context header');
    like($day_result->{items}[1]{name}, qr{Bohemian Rhapsody}, 'Second item is Queen track');
    like($day_result->{items}[2]{name}, qr{💿.*Abbey Road}, 'Third item is Album context header');
    like($day_result->{items}[3]{name}, qr{Come Together}, 'Fourth item is Beatles track');
}

# --------------------------------------------------------------------------
# Test 12: handleAudiobooksHistory parsing 'entities' with track streamProgress
# --------------------------------------------------------------------------
{
    my $mock_client = MockClient2->new();
    my $api_client = Plugins::yandex::API::Async->new('dummy_token');

    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb) = @_;
        $cb->({
            entities => [
                {
                    type => 'album',
                    album => {
                        id => 32792140,
                        title => 'Джордж Оруэлл. «Фунты лиха в Париже и Лондоне»',
                        artists => [{ name => 'Джордж Оруэлл' }],
                    },
                    track => {
                        id => '129893157',
                        title => 'Часть 38',
                        streamProgress => { endPositionSec => 75, everFinished => 0 },
                    },
                },
            ],
        });
    };

    my $bookshelf_result;
    Plugins::yandex::Browse::History::handleAudiobooksHistory(
        $mock_client,
        sub { $bookshelf_result = shift; },
        {},
        $api_client
    );

    ok(defined $bookshelf_result && $bookshelf_result->{items}, 'Bookshelf returned items from entities');
    is(scalar(@{$bookshelf_result->{items}}), 1, 'One book item returned');
    is($bookshelf_result->{items}[0]{line1}, 'Джордж Оруэлл. «Фунты лиха в Париже и Лондоне»', 'Book title matched');
    like($bookshelf_result->{items}[0]{line2}, qr{Часть 38 \(1:15\)}, 'Subtitle includes chapter title and position');
}

# --------------------------------------------------------------------------
# Test 13: handleMusicHistoryDayTracks shortModels resolution via itemId.trackId
# --------------------------------------------------------------------------
{
    my $mock_client = MockClient2->new();
    my $api_client = Plugins::yandex::API::Async->new('dummy_token');

    local *Plugins::yandex::API::Async::tracks = sub {
        my ($self, $track_ids, $cb) = @_;
        $cb->([
            {
                id => '999111',
                title => 'Resolved Track Title',
                artists => [{ name => 'Resolved Artist' }],
                albums => [{ id => 555, title => 'Resolved Album' }],
                durationMs => 180000,
            }
        ]);
    };

    my $short_model_tab = {
        date => '2026-10-28',
        items => [
            {
                context => { type => 'album', data => { itemId => { id => '555' } } },
                tracks => [
                    {
                        type => 'track',
                        data => {
                            itemId => { trackId => '999111', albumId => '555' },
                        },
                    },
                ],
            },
        ],
    };

    my $res;
    Plugins::yandex::Browse::History::handleMusicHistoryDayTracks(
        $mock_client,
        sub { $res = shift; },
        {},
        $api_client,
        $short_model_tab
    );

    ok(defined $res && $res->{items}, 'ShortModels day returned items');
    my @track_items = grep { $_->{type} eq 'audio' } @{$res->{items}};
    is(scalar(@track_items), 1, 'One audio track resolved');
    is($track_items[0]{line1}, 'Resolved Track Title', 'Resolved track title');
    like($track_items[0]{line2}, qr{Resolved Artist}, 'Resolved artist');
}

# --------------------------------------------------------------------------
# Test 16: Plugin::_renderRootMenu with entities from bookshelf recently-played
# --------------------------------------------------------------------------
{
    my $mock_client = MockClient->new();
    my $prefs = Slim::Utils::Prefs::preferences('plugin.yandex');
    $prefs->set('show_resume_quick_item', 1);

    my $api_client = Plugins::yandex::API::Async->new('dummy_token');
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb) = @_;
        $cb->({
            entities => [
                {
                    album => {
                        id => 32792140,
                        title => '1984',
                        coverUri => 'avatars.yandex.net/get-music-content/123/%%',
                    },
                    track => {
                        id => 129893157,
                        title => 'Глава 1',
                    }
                }
            ]
        });
    };

    my $menu_items;
    Plugins::yandex::Plugin::_renderRootMenu($mock_client, sub { $menu_items = shift; }, $api_client);

    ok(defined $menu_items && ref $menu_items eq 'ARRAY', '_renderRootMenu returned items array');
    my $first_item = $menu_items->[0];
    ok(defined $first_item, 'First item exists');
    is($first_item->{type}, 'action', 'Quick resume item has type action');
    like($first_item->{name}, qr{1984}, 'Quick resume item name includes book title 1984');
    is($first_item->{passthrough}[1], 32792140, 'Quick resume item passes album ID 32792140');
}

# --------------------------------------------------------------------------
# Test 17: is_basic_display_client helper tests
# --------------------------------------------------------------------------
{
    require Plugins::yandex::Browse::Common;

    {
        package Slim::Player::SqueezePlay;
        our @ISA = qw(MockClient);
        package Slim::Player::Boom;
        our @ISA = qw(MockClient);
        package Slim::Player::Squeezebox2;
        our @ISA = qw(MockClient);
        package Slim::Player::Transporter;
        our @ISA = qw(MockClient);
        package Slim::Player::Receiver;
        our @ISA = qw(MockClient);
    }

    is(Plugins::yandex::Browse::Common::is_basic_display_client(undef), 0, 'undef client is not basic display');
    my $modern_client = MockClient->new();
    is(Plugins::yandex::Browse::Common::is_basic_display_client($modern_client), 0, 'generic client is not basic display');

    # Squeezelite (headless)
    my $squeezelite = MockClient->new(model => 'squeezelite');
    is(Plugins::yandex::Browse::Common::is_basic_display_client($squeezelite), 0, 'squeezelite is not basic display');

    # SqueezePlay class
    my $sqp_by_class = bless { id => '1' }, 'Slim::Player::SqueezePlay';
    is(Plugins::yandex::Browse::Common::is_basic_display_client($sqp_by_class), 1, 'Slim::Player::SqueezePlay is basic display');

    # SqueezePlay models (desktop, Touch, Radio, Controller)
    for my $m (qw(squeezeplay fab4 baby radio controller jive)) {
        my $c = MockClient->new(model => $m);
        is(Plugins::yandex::Browse::Common::is_basic_display_client($c), 1, "model $m is basic display");
    }

    # Hardware players (Boom, Squeezebox 2/3/Classic, Transporter, Receiver)
    my $boom_by_class = bless { id => '2' }, 'Slim::Player::Boom';
    is(Plugins::yandex::Browse::Common::is_basic_display_client($boom_by_class), 1, 'Slim::Player::Boom is basic display');
    my $sb2_by_class = bless { id => '3' }, 'Slim::Player::Squeezebox2';
    is(Plugins::yandex::Browse::Common::is_basic_display_client($sb2_by_class), 1, 'Slim::Player::Squeezebox2 is basic display');

    for my $m (qw(boom squeezebox2 squeezebox3 classic transporter receiver slimp3)) {
        my $c = MockClient->new(model => $m);
        is(Plugins::yandex::Browse::Common::is_basic_display_client($c), 1, "hardware model $m is basic display");
    }

    # Explicit override flags
    my $override_yes = MockClient->new(is_basic_display => 1);
    is(Plugins::yandex::Browse::Common::is_basic_display_client($override_yes), 1, 'override is_basic_display => 1');
    my $override_no = MockClient->new(is_basic_display => 0, model => 'boom');
    is(Plugins::yandex::Browse::Common::is_basic_display_client($override_no), 0, 'override is_basic_display => 0 takes precedence');

    # Array-based real LMS client objects (Slim::Utils::Accessor blessed [])
    {
        package MockArrayBoomClient;
        our @ISA = qw(Slim::Player::Boom);
        sub model { 'boom' }

        package MockArrayGenericClient;
        our @ISA = qw(MockClient);
        sub model { 'http' }

        package main;
        my $array_boom = bless [], 'MockArrayBoomClient';
        is(Plugins::yandex::Browse::Common::is_basic_display_client($array_boom), 1, 'Array-based Boom client is detected as basic display without hash error');

        my $array_generic = bless [], 'MockArrayGenericClient';
        is(Plugins::yandex::Browse::Common::is_basic_display_client($array_generic), 0, 'Array-based generic client is not basic display without hash error');
    }
}

# --------------------------------------------------------------------------
# Test 18: Basic display client quick resume button on root menu
# --------------------------------------------------------------------------
{
    my $sqp_client = bless { id => 'sqp1', model => 'squeezeplay' }, 'Slim::Player::SqueezePlay';
    my $boom_client = bless { id => 'boom1', model => 'boom' }, 'Slim::Player::Boom';

    my $api_client = Plugins::yandex::API::Async->new('dummy_token');
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb) = @_;
        $cb->({
            entities => [
                {
                    album => {
                        id => 32792140,
                        title => '1984',
                    },
                    track => { id => 129893157, title => 'Глава 1' }
                }
            ]
        });
    };

    my $sqp_menu;
    Plugins::yandex::Plugin::_renderRootMenu($sqp_client, sub { $sqp_menu = shift; }, $api_client);
    ok(defined $sqp_menu && ref $sqp_menu eq 'ARRAY', 'Squeezeplay root menu returned items');
    like($sqp_menu->[0]{name}, qr{\[>\]\s*Продолжить:\s*1984}, 'Squeezeplay quick resume uses [>] instead of [▶]');
    unlike($sqp_menu->[0]{name}, qr{▶}, 'Squeezeplay quick resume does NOT contain ▶ symbol');

    my $boom_menu;
    Plugins::yandex::Plugin::_renderRootMenu($boom_client, sub { $boom_menu = shift; }, $api_client);
    ok(defined $boom_menu && ref $boom_menu eq 'ARRAY', 'Boom root menu returned items');
    like($boom_menu->[0]{name}, qr{\[>\]\s*Продолжить:\s*1984}, 'Boom quick resume uses [>] instead of [▶]');
    unlike($boom_menu->[0]{name}, qr{▶}, 'Boom quick resume does NOT contain ▶ symbol');
}

# --------------------------------------------------------------------------
# Test 19: History context items formatting for basic display clients
# --------------------------------------------------------------------------
{
    my $sqp_client = bless { id => 'sqp2', model => 'squeezeplay' }, 'Slim::Player::SqueezePlay';

    # Wave: [Радио] / [Radio] instead of ⚡
    my $wave_grp = {
        context => {
            type => 'wave',
            data => {
                fullModel => { wave => { title => 'Berlin school' } },
                itemId    => { seeds => ['artist:12345'] },
            },
        },
    };
    my $wave_item = Plugins::yandex::Browse::History::_parse_history_context_item($sqp_client, undef, $wave_grp);
    ok(defined $wave_item, 'Basic wave context item parsed');
    like($wave_item->{name}, qr{^\[Радио\]\s*Berlin school}, 'Basic wave name uses [Радио] prefix');
    unlike($wave_item->{name}, qr{⚡}, 'Basic wave name does NOT contain ⚡ emoji');
    like($wave_item->{line1}, qr{^\[Радио\]\s*Berlin school}, 'Basic wave line1 uses [Радио] prefix');
    unlike($wave_item->{line1}, qr{⚡}, 'Basic wave line1 does NOT contain ⚡ emoji');

    # Wave in English
    {
        package MockENClient;
        our @ISA = qw(Slim::Player::SqueezePlay);
        sub new { bless { id => 'en_sqp', model => 'squeezeplay' }, shift }
        sub string { return 'Radio' if $_[1] eq 'PLUGIN_YANDEX_RADIO'; return $_[1]; }
        package main;
        my $en_client = MockENClient->new();
        my $en_wave_item = Plugins::yandex::Browse::History::_parse_history_context_item($en_client, undef, $wave_grp);
        like($en_wave_item->{line1}, qr{^\[Radio\]\s*Berlin school}, 'English basic wave line1 uses [Radio] prefix');
    }

    # Album: [Альбом] instead of 💿
    my $album_grp = {
        context => {
            type => 'album',
            data => {
                fullModel => {
                    album => {
                        id => 999,
                        title => 'По волне моей памяти',
                        artists => [{ name => 'Давид Тухманов' }],
                    },
                },
                itemId => { id => 999 },
            },
        },
    };
    my $album_item = Plugins::yandex::Browse::History::_parse_history_context_item($sqp_client, undef, $album_grp);
    ok(defined $album_item, 'Basic album context item parsed');
    like($album_item->{name}, qr{\[Альбом\]\s*По волне моей памяти.*Давид Тухманов}, 'Basic album name uses [Альбом] badge and title');
    unlike($album_item->{name}, qr{💿}, 'Basic album name does NOT contain 💿 emoji');
    like($album_item->{line1}, qr{\[Альбом\]\s*По волне моей памяти}, 'Basic album line1 uses [Альбом]');
    unlike($album_item->{line1}, qr{💿}, 'Basic album line1 does NOT contain 💿 emoji');
    unlike($album_item->{line2}, qr{\x{2022}}, 'Basic album line2 does not contain bullet char');

    # Artist: [Артист] instead of 👤
    my $artist_grp = {
        context => {
            type => 'artist',
            data => {
                fullModel => {
                    artist => { id => 888, name => 'Queen' },
                },
                itemId => { id => 888 },
            },
        },
    };
    my $artist_item = Plugins::yandex::Browse::History::_parse_history_context_item($sqp_client, undef, $artist_grp);
    ok(defined $artist_item, 'Basic artist context item parsed');
    like($artist_item->{name}, qr{\[Артист\]\s*Queen}, 'Basic artist name uses [Артист] tag');
    unlike($artist_item->{name}, qr{👤}, 'Basic artist name does NOT contain 👤 emoji');
    like($artist_item->{line1}, qr{\[Артист\]\s*Queen}, 'Basic artist line1 uses [Артист] tag');
    unlike($artist_item->{line1}, qr{👤}, 'Basic artist line1 does NOT contain 👤 emoji');

    # Playlist: [Плейлист] instead of 📜
    my $playlist_grp = {
        context => {
            type => 'playlist',
            data => {
                fullModel => {
                    playlist => {
                        uid => 111,
                        kind => 222,
                        title => 'Top Hits',
                        owner => { name => 'Yandex Music' },
                    },
                },
                itemId => { uid => 111, kind => 222 },
            },
        },
    };
    my $playlist_item = Plugins::yandex::Browse::History::_parse_history_context_item($sqp_client, undef, $playlist_grp);
    ok(defined $playlist_item, 'Basic playlist context item parsed');
    like($playlist_item->{name}, qr{\[Плейлист\]\s*Top Hits.*Yandex Music}, 'Basic playlist name uses [Плейлист] tag');
    unlike($playlist_item->{name}, qr{📜}, 'Basic playlist name does NOT contain 📜 emoji');
    like($playlist_item->{line1}, qr{\[Плейлист\]\s*Top Hits}, 'Basic playlist line1 uses [Плейлист] tag');
    unlike($playlist_item->{line1}, qr{📜}, 'Basic playlist line1 does NOT contain 📜 emoji');
    unlike($playlist_item->{line2}, qr{\x{2022}}, 'Basic playlist line2 does not contain bullet char');
}

# --------------------------------------------------------------------------
# Test 20: Listening history and bookshelf caching & cache invalidation
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('token123');
    $api->{me} = { uid => 555666 };

    my $history_calls = 0;
    my $bookshelf_calls = 0;
    my $post_items_calls = 0;

    no warnings 'redefine';
    local *Plugins::yandex::API::Async::get = sub {
        my ($s, $url, $params, $cb) = @_;
        if ($url =~ m{/music-history$}) {
            $history_calls++;
            $cb->({ result => { historyTabs => [{ date => '2026-10-30', items => [] }] } });
        } elsif ($url =~ m{/non-music/bookshelf/recently-played$}) {
            $bookshelf_calls++;
            $cb->({ result => { entities => [{ album => { id => 42, title => 'Cached Book' } }] } });
        } else {
            $cb->({ result => {} });
        }
    };
    local *Plugins::yandex::API::Async::post = sub {
        my ($s, $url, $body, $cb) = @_;
        if ($url =~ m{/music-history/items$}) {
            $post_items_calls++;
            $cb->({ result => [{ id => 'item100' }] });
        } else {
            $cb->({ result => { status => 'ok' } });
        }
    };

    # 1. get_music_history caching
    my $hist_res1;
    $api->get_music_history(50, sub { $hist_res1 = shift; });
    is($history_calls, 1, 'First get_music_history call hits network');
    is($hist_res1->{historyTabs}[0]{date}, '2026-10-30', 'First get_music_history got result');

    my $hist_res2;
    $api->get_music_history(50, sub { $hist_res2 = shift; });
    is($history_calls, 1, 'Second get_music_history call hit cache (network not called)');
    is($hist_res2->{historyTabs}[0]{date}, '2026-10-30', 'Cached get_music_history matched');

    # no_cache forces fresh call
    $api->get_music_history(50, sub {}, undef, { no_cache => 1 });
    is($history_calls, 2, 'get_music_history with no_cache => 1 bypasses cache');

    # 2. send_play invalidates music history cache
    $api->send_play({ trackId => '100:200', totalPlayedSeconds => 40 });
    $api->get_music_history(50, sub {});
    is($history_calls, 3, 'send_play invalidated music history cache (network called again)');

    # 3. get_bookshelf_recently_played caching
    my $book_res1;
    $api->get_bookshelf_recently_played(0, 20, sub { $book_res1 = shift; });
    is($bookshelf_calls, 1, 'First get_bookshelf_recently_played call hits network');
    is($book_res1->{entities}[0]{album}{title}, 'Cached Book', 'First bookshelf got result');

    my $book_res2;
    $api->get_bookshelf_recently_played(0, 20, sub { $book_res2 = shift; });
    is($bookshelf_calls, 1, 'Second get_bookshelf_recently_played hit cache');

    # 4. save_stream_progress invalidates bookshelf cache
    $api->save_stream_progress(101, 50, 200, 0);
    $api->get_bookshelf_recently_played(0, 20, sub {});
    is($bookshelf_calls, 2, 'save_stream_progress invalidated bookshelf cache');

    # 5. post_music_history_items caching
    my $post_res1;
    $api->post_music_history_items(['track_1', 'track_2'], sub { $post_res1 = shift; });
    is($post_items_calls, 1, 'First post_music_history_items hits network');

    my $post_res2;
    $api->post_music_history_items(['track_1', 'track_2'], sub { $post_res2 = shift; });
    is($post_items_calls, 1, 'Second post_music_history_items hit cache');

    # 6. Dynamic bookshelf page invalidation
    my $book_page1_res;
    $api->get_bookshelf_recently_played(1, 10, sub { $book_page1_res = shift; });
    is($bookshelf_calls, 3, 'Bookshelf custom page hits network');
    $api->get_bookshelf_recently_played(1, 10, sub {});
    is($bookshelf_calls, 3, 'Bookshelf custom page hits cache');

    $api->save_stream_progress(101, 75, 200, 0);
    $api->get_bookshelf_recently_played(1, 10, sub {});
    is($bookshelf_calls, 4, 'save_stream_progress invalidated dynamic bookshelf custom page cache');
}

# --------------------------------------------------------------------------
# Test 21: sanitize_for_client & separator checks across basic vs full clients
# --------------------------------------------------------------------------
{
    my $sqp_client = bless { id => 'sqp_disp', model => 'squeezeplay' }, 'Slim::Player::SqueezePlay';
    my $full_client = bless { id => 'web_disp', model => 'squeezelite' }, 'Slim::Player::Client';

    # 1. sanitize_for_client
    my $raw_str = "▶ Play • ⚡ Super 💿 Album 👤 Artist 📜 Playlist 🎵";
    my $clean_sqp = Plugins::yandex::Browse::Common::sanitize_for_client($sqp_client, $raw_str);
    is($clean_sqp, "> Play - [Радио] Super Album Artist Playlist", 'Basic client sanitizes ▶, •, ⚡ to [Радио], and strips emojis');
    my $untouched = Plugins::yandex::Browse::Common::sanitize_for_client($full_client, $raw_str);
    is($untouched, $raw_str, 'Full client leaves all glyphs and emojis completely untouched');

    # 2. _format_history_track_item separator and emoji sanitization
    my $track_obj = {
        id => '123456',
        title => '⚡ Flash 💿 Track',
        artists => [{ name => 'Queen 👑' }],
        albums => [{ title => 'A Night At The Opera' }],
    };
    my $basic_tr_item = Plugins::yandex::Browse::History::_format_history_track_item($sqp_client, $track_obj);
    like($basic_tr_item->{line1}, qr{^\[Радио\]\s*Flash Track}, 'Basic track line1 sanitized');
    unlike($basic_tr_item->{line1}, qr{[⚡💿]}, 'Basic track line1 has no unsupported glyphs');
    like($basic_tr_item->{line2}, qr{Queen - A Night At The Opera}, 'Basic track line2 uses - separator instead of bullet');
    unlike($basic_tr_item->{line2}, qr{\x{2022}}, 'Basic track line2 does not contain bullet char');

    my $full_tr_item = Plugins::yandex::Browse::History::_format_history_track_item($full_client, $track_obj);
    like($full_tr_item->{line2}, qr{\x{2022}}, 'Full client track line2 retains bullet separator');

    # 3. renderTrackList separator
    my $rendered_basic;
    Plugins::yandex::Browse::Common::renderTrackList(
        [$track_obj],
        sub { $rendered_basic = shift; },
        'Test Tracks',
        undef,
        { client => $sqp_client }
    );
    ok(defined $rendered_basic && @{$rendered_basic->{items}}, 'renderTrackList returned items');
    like($rendered_basic->{items}[0]{line2}, qr{Queen.*-.*A Night At The Opera}, 'renderTrackList on basic client uses - separator');
    unlike($rendered_basic->{items}[0]{line2}, qr{\x{2022}}, 'renderTrackList on basic client has no bullet char');

    my $rendered_full;
    Plugins::yandex::Browse::Common::renderTrackList(
        [$track_obj],
        sub { $rendered_full = shift; },
        'Test Tracks',
        undef,
        { client => $full_client }
    );
    like($rendered_full->{items}[0]{line2}, qr{\x{2022}}, 'renderTrackList on full client retains bullet char');
}

# --------------------------------------------------------------------------
# Test 22: renderPlaylistList and handleNewPlaylists callback execution
# --------------------------------------------------------------------------
{
    require Plugins::yandex::Browse::Common;
    require Plugins::yandex::Browse::Collection;

    # 1. renderPlaylistList with playlists
    my $mock_playlists = [
        {
            title => 'Indie Hits',
            owner => { uid => '12345', name => 'Yandex Music' },
            kind => '1001',
            cover => { uri => 'avatars.yandex.net/get-music-content/123/%%' },
        },
        {
            title => 'Rock Classics',
            owner => { uid => '67890', name => 'Curator' },
            kind => '2002',
            cover => { uri => 'avatars.yandex.net/get-music-content/456/%%' },
        },
        undef, # Should be skipped gracefully
    ];

    my $render_res;
    Plugins::yandex::Browse::Common::renderPlaylistList(
        'MOCK_API',
        $mock_playlists,
        sub { $render_res = shift; },
        'New Playlists'
    );

    ok(defined $render_res, 'renderPlaylistList invoked callback');
    is($render_res->{title}, 'New Playlists', 'renderPlaylistList sets correct title');
    is(scalar(@{$render_res->{items}}), 2, 'renderPlaylistList returned 2 items (undef skipped)');
    is($render_res->{items}[0]{name}, 'Indie Hits (Yandex Music)', 'First playlist item title and owner');
    is($render_res->{items}[0]{line1}, 'Indie Hits', 'First playlist item line1');
    is($render_res->{items}[0]{line2}, 'Yandex Music', 'First playlist item line2');
    is($render_res->{items}[0]{type}, 'playlist', 'First playlist item type');
    is($render_res->{items}[0]{play}, 'yandexmusic://playlist/12345/1001', 'First playlist item play URL');
    is($render_res->{items}[0]{image}, 'https://avatars.yandex.net/get-music-content/123/200x200', 'First playlist formatted cover URL');
    is_deeply($render_res->{items}[0]{passthrough}, ['MOCK_API', '12345', '1001'], 'First playlist passthrough args');

    # 2. renderPlaylistList with empty array
    my $empty_res;
    Plugins::yandex::Browse::Common::renderPlaylistList(
        'MOCK_API',
        [],
        sub { $empty_res = shift; },
        'Empty Playlists'
    );
    ok(defined $empty_res, 'renderPlaylistList invoked callback on empty array');
    is(scalar(@{$empty_res->{items}}), 0, 'renderPlaylistList empty items count is 0');

    # 3. renderPlaylistList with mosaic cover, coverUri, and owner without name
    my $cover_variants = [
        {
            title => 'Mosaic Playlist',
            owner => { uid => '111', name => 'Curator 1' },
            kind => '501',
            cover => { type => 'mosaic', itemsUri => ['avatars.yandex.net/mosaic-1/%%'] },
        },
        {
            title => 'CoverUri Playlist',
            owner => { uid => '222' }, # no name
            kind => '502',
            coverUri => 'avatars.yandex.net/coveruri-2/%%',
        },
    ];

    my $variants_res;
    Plugins::yandex::Browse::Common::renderPlaylistList(
        'MOCK_API',
        $cover_variants,
        sub { $variants_res = shift; },
        'Variants'
    );
    ok(defined $variants_res, 'renderPlaylistList with mosaic/coverUri invoked callback');
    is($variants_res->{items}[0]{image}, 'https://avatars.yandex.net/mosaic-1/200x200', 'Mosaic itemsUri parsed');
    is($variants_res->{items}[1]{image}, 'https://avatars.yandex.net/coveruri-2/200x200', 'Direct coverUri parsed');
    is($variants_res->{items}[1]{name}, 'CoverUri Playlist', 'Playlist without owner name does not append (Unknown)');
    is($variants_res->{items}[1]{line1}, 'CoverUri Playlist', 'Playlist line1 matches title');
    ok(!defined $variants_res->{items}[1]{line2}, 'Playlist line2 is undef without owner name');

    # 4. renderPlaylistList on basic display client sanitizes emoji
    my $emoji_playlist = [
        {
            title => "🔥 Top Hits \x{26A1}",
            owner => { uid => '333', name => "Super \x{1F600} Dj" },
            kind => '601',
        },
    ];
    my $basic_client = { is_basic_display => 1 };
    my $basic_pl_res;
    Plugins::yandex::Browse::Common::renderPlaylistList(
        'MOCK_API',
        $emoji_playlist,
        sub { $basic_pl_res = shift; },
        'Emoji Test',
        { client => $basic_client }
    );
    ok(defined $basic_pl_res, 'renderPlaylistList with basic client invoked callback');
    is($basic_pl_res->{items}[0]{line1}, 'Top Hits [PLUGIN_YANDEX_RADIO]', 'Basic client strips fire emoji and replaces lightning with radio tag');
    is($basic_pl_res->{items}[0]{line2}, 'Super Dj', 'Basic client strips emoji from owner name');
    is($basic_pl_res->{items}[0]{name}, 'Top Hits [PLUGIN_YANDEX_RADIO] (Super Dj)', 'Basic client name sanitized correctly');

    # 5. handleNewPlaylists end-to-end with mock API
    {
        package MockYandexClientNewPlaylists;
        sub new { bless {}, shift }
        sub get_new_playlists {
            my ($self, $cb, $err_cb) = @_;
            $cb->([
                { uid => '100', kind => '10' },
                { uid => '200', kind => '20' },
                { uid => '300', kind => '30' },
            ]);
        }
        sub get_playlist {
            my ($self, $uid, $kind, $cb, $err_cb) = @_;
            my $pl = {
                title => "Playlist $kind",
                owner => { uid => $uid, name => "User $uid" },
                kind  => $kind,
            };
            $cb->($pl);
        }
    }

    my $mock_client_obj = { client_id => 'test' };
    my $mock_api = MockYandexClientNewPlaylists->new();
    my $cb_res;

    Plugins::yandex::Browse::Collection::handleNewPlaylists(
        $mock_client_obj,
        sub { $cb_res = shift; },
        {},
        $mock_api
    );

    ok(defined $cb_res, 'handleNewPlaylists callback invoked successfully');
    is(scalar(@{$cb_res->{items}}), 3, 'handleNewPlaylists returned all 3 playlists');
    is($cb_res->{items}[0]{play}, 'yandexmusic://playlist/100/10', 'First playlist in order');
    is($cb_res->{items}[1]{play}, 'yandexmusic://playlist/200/20', 'Second playlist in order');
    is($cb_res->{items}[2]{play}, 'yandexmusic://playlist/300/30', 'Third playlist in order');
}

# --------------------------------------------------------------------------
# Test 23: Fix for natural chapter finish duration in _mark_chapter_finished
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    my ($posted_url, $posted_body);
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::post = sub {
        my ($self, $url, $body, $cb, $err_cb) = @_;
        $posted_url  = $url;
        $posted_body = $body;
        $cb->({ result => 'ok' }) if $cb;
    };

    # 23a: mark_stream_finished with explicit duration
    $api->mark_stream_finished(127083193, undef, undef, 796);
    is($posted_body->{trackStreams}[0]{trackId}, '127083193', 'mark_stream_finished trackId matches');
    is($posted_body->{trackStreams}[0]{positionSec}, 796, 'mark_stream_finished positionSec > 0');
    is($posted_body->{trackStreams}[0]{trackLengthSec}, 796, 'mark_stream_finished trackLengthSec matches duration');
    is(${$posted_body->{trackStreams}[0]{finished}}, 1, 'mark_stream_finished finished flag is 1');

    # 23b: mark_stream_finished without duration falls back to cache or 1 (never 0)
    my $cache = Slim::Utils::Cache->new();
    $cache->set('yandex_meta_99999', { duration => 350 });
    $api->mark_stream_finished(99999);
    is($posted_body->{trackStreams}[0]{trackLengthSec}, 350, 'mark_stream_finished without arg resolved duration from cache');

    $api->mark_stream_finished(88888); # No cache
    ok($posted_body->{trackStreams}[0]{trackLengthSec} > 0, 'mark_stream_finished without cache defaults length > 0 (prevents 400 Bad Request)');
}

# --------------------------------------------------------------------------
# Test 24: Fix for _send_music_play clean trackId and Wave radioSessionId propagation
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    my ($sent_url, $sent_body, $sent_params);
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::post = sub {
        my ($self, $url, $body, $cb, $err_cb, $params) = @_;
        $sent_url    = $url;
        $sent_body   = $body;
        $sent_params = $params;
        $cb->({ result => 'ok' }) if $cb;
    };
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $api; };

    my $player = MockPlayerClient->new();
    $player->pluginData('yandex_curr_radio_session', 'session-xyz-123');
    $player->pluginData('yandex_curr_batch_id', 'batch-abc-789');

    # When trackId has "trackId:albumId" format from LMS, it must be cleaned to numeric trackId
    Plugins::yandex::Plugin::_send_music_play($player, '27536680:3296314', 3296314, 45, 210);

    my $play_record = $sent_body->{plays}[0];
    is($play_record->{trackId}, '27536680', '_send_music_play passes pure numeric trackId');
    is($play_record->{albumId}, 3296314, '_send_music_play passes albumId separately');
    is($play_record->{context}, 'wave', '_send_music_play sets context to wave for radio session');
    is($play_record->{contextItem}, 'session-xyz-123', '_send_music_play sets contextItem to radioSessionId');
    is($play_record->{radioSessionId}, 'session-xyz-123', '_send_music_play propagates radioSessionId');
    is($play_record->{batchId}, 'batch-abc-789', '_send_music_play propagates batchId');
}

# --------------------------------------------------------------------------
# Test 25: _calculate_resume_point advances to chapter 2 when chapter 1 is finished
# --------------------------------------------------------------------------
{
    my @tracks_prodawec = (
        { id => 127083193, durationMs => 796_000, streamProgress => { everFinished => 1, endPositionSec => 0 } },
        { id => 127083194, durationMs => 820_000 },
        { id => 127083195, durationMs => 750_000 },
    );
    my $album_prodawec = {
        id      => 31670261,
        title   => 'Продавец приключений',
        volumes => [ \@tracks_prodawec ],
    };

    my ($target_idx, $offset_sec) = Plugins::yandex::Browse::History::_calculate_resume_point($album_prodawec, \@tracks_prodawec);
    is($target_idx, 1, 'Chapter 1 finished: Advances resume point to Chapter 2 (index 1)');
    is($offset_sec, 0, 'Offset is 0s at start of Chapter 2');
}

# --------------------------------------------------------------------------
# Test 26: Quick resume prioritization of local audiobook over older remote bookshelf
# --------------------------------------------------------------------------
{
    my $api_client = Plugins::yandex::API::Async->new('dummy_token');
    my $client = MockPlayerClient->new();

    # Set local audiobook played today (recent timestamp)
    my $local_time = time();
    my $prefs = Slim::Utils::Prefs::preferences('plugin.yandex');
    $prefs->set('last_played_audiobook_19183055', {
        album_id  => 31670261,
        title     => 'Продавец приключений',
        cover_uri => 'cover.jpg',
        timestamp => $local_time,
    });
    $prefs->client($client)->set('userId', '19183055');
    $prefs->set('accounts', {
        '19183055' => { name => 'Test User', token => 'test_token' }
    });

    # Remote bookshelf still returns Orwell from 3 days ago
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb) = @_;
        $cb->({
            entities => [
                {
                    album => {
                        id    => 32792140,
                        title => 'Джордж Оруэлл. «Фунты лиха в Париже и Лондоне»',
                    },
                    listeningDate => '2026-10-29T10:21:29Z', # Older than local_time
                }
            ]
        });
    };

    my $rendered_menu;
    Plugins::yandex::Plugin::_renderRootMenu($client, sub { $rendered_menu = shift; }, $api_client);
    ok(defined $rendered_menu && ref $rendered_menu eq 'ARRAY', 'Root menu rendered');
    my $quick_item = $rendered_menu->[0];
    ok(defined $quick_item, 'Quick resume button exists');
    like($quick_item->{name}, qr{Продавец приключений}, 'Quick resume prioritizes newer local book over older remote book');
    is($quick_item->{passthrough}[1], 31670261, 'Quick resume links to album 31670261 (Продавец приключений)');

    # Remote bookshelf returns a newer book from mobile app (tomorrow)
    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb) = @_;
        $cb->({
            entities => [
                {
                    album => {
                        id    => 99999999,
                        title => 'New Mobile Book',
                    },
                    listeningDate => '2035-01-01T12:00:00Z', # Newer than local_time
                }
            ]
        });
    };

    my $rendered_menu_new;
    Plugins::yandex::Plugin::_renderRootMenu($client, sub { $rendered_menu_new = shift; }, $api_client);
    like($rendered_menu_new->[0]{name}, qr{New Mobile Book}, 'Quick resume prioritizes remote book if listeningDate is newer than local');

    # Remote bookshelf errors out: fallback to local book
    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb, $err_cb) = @_;
        $err_cb->('Network Timeout');
    };

    my $rendered_menu_err;
    Plugins::yandex::Plugin::_renderRootMenu($client, sub { $rendered_menu_err = shift; }, $api_client);
    ok(defined $rendered_menu_err->[0], 'Quick resume shows on remote network error');
    like($rendered_menu_err->[0]{name}, qr{Продавец приключений}, 'Quick resume falls back to local book on remote error');
}

# --------------------------------------------------------------------------
# Test 27: _iso_to_epoch parses ISO8601, epoch seconds, and epoch milliseconds
# --------------------------------------------------------------------------
{
    is(Plugins::yandex::Plugin::_iso_to_epoch('2026-11-02T10:00:00Z'), 1793613600, '_iso_to_epoch parses ISO8601');
    is(Plugins::yandex::Plugin::_iso_to_epoch('1730541600'), 1730541600, '_iso_to_epoch parses 10-digit epoch seconds');
    is(Plugins::yandex::Plugin::_iso_to_epoch('1730541600000'), 1730541600, '_iso_to_epoch parses 13-digit epoch milliseconds');
    is(Plugins::yandex::Plugin::_iso_to_epoch(''), 0, '_iso_to_epoch handles empty string');
    is(Plugins::yandex::Plugin::_iso_to_epoch(undef), 0, '_iso_to_epoch handles undef');
}

# --------------------------------------------------------------------------
# Test 28: send_play omits albumId when 0 or undef, includes string when > 0
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    my $posted_body;
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::post = sub {
        my ($self, $url, $body, $cb, $err_cb) = @_;
        $posted_body = $body;
        $cb->({ result => 'ok' }) if $cb;
    };

    # albumId is undef
    $api->send_play({ trackId => 111, totalPlayedSeconds => 35 });
    ok(!exists $posted_body->{plays}[0]{albumId}, 'send_play omits albumId when undef');

    # albumId is 0
    $api->send_play({ trackId => 222, albumId => 0, totalPlayedSeconds => 35 });
    ok(!exists $posted_body->{plays}[0]{albumId}, 'send_play omits albumId when 0');

    # albumId is positive
    $api->send_play({ trackId => 333, albumId => 444, totalPlayedSeconds => 35 });
    ok(exists $posted_body->{plays}[0]{albumId}, 'send_play includes albumId when > 0');
    is($posted_body->{plays}[0]{albumId}, '444', 'send_play serializes albumId as string');
}

# --------------------------------------------------------------------------
# Test 29: save_stream_progress clamps duration and position to avoid 400 Bad Request
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    my $posted_body;
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::post = sub {
        my ($self, $url, $body, $cb, $err_cb) = @_;
        $posted_body = $body;
        $cb->({ result => 'ok' }) if $cb;
    };

    # Both position and duration are 0 on finished track
    $api->save_stream_progress(127083193, 0, 0, 1);
    my $stream = $posted_body->{trackStreams}[0];
    ok($stream->{trackLengthSec} >= 1, 'save_stream_progress trackLengthSec clamped to >= 1 when 0');
    ok($stream->{positionSec} >= 1, 'save_stream_progress positionSec clamped to length when finished');

    # Duration resolved from cache when not passed
    my $cache = Slim::Utils::Cache->new();
    $cache->set('yandex_meta_55555', { duration => 420 });
    $api->save_stream_progress(55555, 10, 0, 0);
    is($posted_body->{trackStreams}[0]{trackLengthSec}, 420, 'save_stream_progress resolved duration from cache');
}

# --------------------------------------------------------------------------
# Test 30: _save_current_progress updates last_played_audiobook when switching books
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    no warnings 'redefine';
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $api; };
    local *Plugins::yandex::API::Async::save_stream_progress = sub {
        my ($self, $tid, $pos, $dur, $fin, $cb) = @_;
        $cb->() if $cb;
    };

    my $client = MockPlayerClient->new();
    my $prefs = Slim::Utils::Prefs::preferences('plugin.yandex');
    $prefs->set('accounts', { 'user_switch' => { name => 'User Switch', token => 'tok' } });
    $prefs->client($client)->set('userId', 'user_switch');

    # User previously played Orwell
    $prefs->set('last_played_audiobook_user_switch', {
        album_id => 32792140,
        title    => 'Orwell',
        timestamp => 1000,
    });

    # Now playing "Продавец приключений" (album 31670261)
    $client->pluginData('yandex_curr_album_id', 31670261);
    my $cache = Slim::Utils::Cache->new();
    $cache->set('yandex_album_31670261', { title => 'Продавец приключений', coverUri => 'cover.jpg' });

    Plugins::yandex::Plugin::_save_current_progress($client, 127083193, 15, 796, 0);

    my $updated_book = $prefs->get('last_played_audiobook_user_switch');
    is($updated_book->{album_id}, 31670261, '_save_current_progress updated album_id when book switched');
    is($updated_book->{title}, 'Продавец приключений', '_save_current_progress resolved title for new book');
    ok($updated_book->{timestamp} > 1000, '_save_current_progress refreshed timestamp');
}

# --------------------------------------------------------------------------
# Test 31: Audiobook chapter tracks save progress, music tracks report play >= 30s
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    my @reported_plays;
    my @saved_progress;
    no warnings 'redefine';
    local *Plugins::yandex::Plugin::getAPIForClient = sub { return $api; };
    local *Plugins::yandex::Plugin::_save_current_progress = sub {
        my ($client, $tid, $pos, $dur, $fin) = @_;
        push @saved_progress, { track_id => $tid, pos => $pos, dur => $dur, fin => $fin };
    };
    local *Plugins::yandex::Plugin::_mark_chapter_finished = sub {};
    local *Plugins::yandex::API::Async::send_play = sub {
        my ($self, $play_obj, $cb) = @_;
        push @reported_plays, $play_obj;
        $cb->() if $cb;
    };

    my $client = MockPlayerClient->new();
    $client->pluginData('yandex_curr_track_id', 127083193);
    $client->pluginData('yandex_curr_album_id', 31670261);
    $client->pluginData('yandex_curr_is_chapter', 1);
    $client->pluginData('yandex_curr_duration', 796);
    $client->pluginData('yandex_curr_play_sent', 0);

    # Mock songTime returning 35 seconds
    local *Slim::Player::Source::songTime = sub { return 35; };

    # Tick timer while playing audiobook chapter
    Plugins::yandex::Plugin::_progress_timer_tick($client);

    is(scalar(@saved_progress), 1, 'Audiobook chapter triggered _save_current_progress');
    is(scalar(@reported_plays), 0, 'Audiobook chapter did NOT trigger send_play (not music)');

    # Now play a regular music track
    my $music_client = MockPlayerClient->new();
    $music_client->pluginData('yandex_curr_track_id', 16782654);
    $music_client->pluginData('yandex_curr_album_id', 20138562);
    $music_client->pluginData('yandex_curr_is_chapter', 0);
    $music_client->pluginData('yandex_curr_duration', 240);
    $music_client->pluginData('yandex_curr_play_sent', 0);

    Plugins::yandex::Plugin::_progress_timer_tick($music_client);

    is(scalar(@reported_plays), 1, 'Music track triggered send_play when pos >= 30s');
    is($reported_plays[0]{trackId}, '16782654', 'send_play passed music trackId');
    is($reported_plays[0]{albumId}, 20138562, 'send_play passed music albumId');
}

# --------------------------------------------------------------------------
# Test 32: API::Async::play_audio posts form-urlencoded to /play-audio
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    my ($posted_url, $posted_form);
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::post_form = sub {
        my ($self, $url, $form, $cb, $err_cb) = @_;
        $posted_url  = $url;
        $posted_form = $form;
        $cb->({ result => 'ok' }) if $cb;
    };

    $api->play_audio({
        trackId            => 102213,
        albumId            => 11048,
        from               => 'desktop_win-home-playlist_of_the_day-playlist-default',
        totalPlayedSeconds => 45,
        trackLengthSeconds => 354,
        endPositionSeconds => 45,
    });

    like($posted_url, qr{/play-audio$}, 'play_audio hits /play-audio endpoint');
    is($posted_form->{'track-id'}, '102213', 'play_audio sets track-id');
    is($posted_form->{'album-id'}, '11048', 'play_audio sets album-id');
    is($posted_form->{'from'}, 'desktop_win-home-playlist_of_the_day-playlist-default', 'play_audio sets from');
    is($posted_form->{'from-cache'}, 'false', 'play_audio sets from-cache false');
    is($posted_form->{'total-played-seconds'}, 45, 'play_audio sets total-played-seconds');
    is($posted_form->{'track-length-seconds'}, 354, 'play_audio sets track-length-seconds');
    is($posted_form->{'end-position-seconds'}, 45, 'play_audio sets end-position-seconds');
    ok(defined $posted_form->{'play-id'}, 'play_audio auto-generates play-id UUID');
    ok(defined $posted_form->{'timestamp'}, 'play_audio includes timestamp');
    ok(defined $posted_form->{'client-now'}, 'play_audio includes client-now');
}

# --------------------------------------------------------------------------
# Test 33: send_play dispatches play_audio alongside POST /plays
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    my @play_audio_calls;
    my @plays_post_calls;
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::play_audio = sub {
        my ($self, $data, $cb, $err_cb) = @_;
        push @play_audio_calls, $data;
        $cb->({ result => 'ok' }) if $cb;
    };
    local *Plugins::yandex::API::Async::post = sub {
        my ($self, $url, $body, $cb, $err_cb) = @_;
        push @plays_post_calls, { url => $url, body => $body };
        $cb->({ result => 'ok' }) if $cb;
    };

    $api->send_play({
        trackId            => 998877,
        albumId            => 665544,
        totalPlayedSeconds => 60,
        trackLengthSeconds => 240,
    });

    is(scalar(@plays_post_calls), 1, 'send_play posted to /plays');
    is(scalar(@play_audio_calls), 1, 'send_play also dispatched play_audio (/play-audio)');
    is($play_audio_calls[0]{trackId}, '998877', 'play_audio received trackId');
    is($play_audio_calls[0]{albumId}, 665544, 'play_audio received albumId');
    is($play_audio_calls[0]{totalPlayedSeconds}, 60, 'play_audio received totalPlayedSeconds');
}

# --------------------------------------------------------------------------
# Test 34: handleAudiobooksHistory sorts newest first and displays listening date/time
# --------------------------------------------------------------------------
{
    my $mock_client = MockClient2->new();
    my $api_client = Plugins::yandex::API::Async->new('dummy_token');

    # Provide 3 books in random/unordered date sequence
    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb) = @_;
        $cb->({
            entities => [
                {
                    type => 'album',
                    album => {
                        id => 100,
                        title => 'Older Book',
                        artists => [{ name => 'Author One' }],
                    },
                    listeningDate => '2026-06-20T17:49:27Z',
                    track => { id => '1', title => 'Ch 1' },
                },
                {
                    type => 'album',
                    album => {
                        id => 200,
                        title => 'Newest Book',
                        artists => [{ name => 'Author Two' }],
                    },
                    listeningDate => '2026-10-29T10:21:29Z',
                    track => { id => '2', title => 'Ch 2' },
                },
                {
                    type => 'album',
                    album => {
                        id => 300,
                        title => 'Middle Book',
                        artists => [{ name => 'Author Three' }],
                    },
                    listeningDate => '2026-08-20T19:34:31Z',
                    track => { id => '3', title => 'Ch 3' },
                },
            ],
        });
    };

    my $bookshelf_result;
    Plugins::yandex::Browse::History::handleAudiobooksHistory(
        $mock_client,
        sub { $bookshelf_result = shift; },
        {},
        $api_client
    );

    ok(defined $bookshelf_result && $bookshelf_result->{items}, 'Bookshelf returned items');
    is(scalar(@{$bookshelf_result->{items}}), 3, 'Three books returned');

    # Must be sorted descending by listening timestamp:
    # 1st: Newest Book (2026-10-29)
    # 2nd: Middle Book (2026-08-20)
    # 3rd: Older Book (2026-06-20)
    is($bookshelf_result->{items}[0]{line1}, 'Newest Book', 'First book is the newest listened');
    is($bookshelf_result->{items}[1]{line1}, 'Middle Book', 'Second book is the middle listened');
    is($bookshelf_result->{items}[2]{line1}, 'Older Book', 'Third book is the oldest listened');

    # Date/time should be formatted in line2
    like($bookshelf_result->{items}[0]{line2}, qr{29\.10\.2026}, 'Newest book line2 displays date 29.10.2026');
    like($bookshelf_result->{items}[1]{line2}, qr{20\.08\.2026}, 'Middle book line2 displays date 20.08.2026');
    like($bookshelf_result->{items}[2]{line2}, qr{20\.06\.2026}, 'Older book line2 displays date 20.06.2026');
}

# --------------------------------------------------------------------------
# Test 35: _iso_to_epoch correctly adjusts for timezone offsets (+HH:MM, -HH:MM)
# --------------------------------------------------------------------------
{
    my $t_utc  = Plugins::yandex::Browse::History::_iso_to_epoch('2026-11-02T08:16:17Z');
    my $t_plus = Plugins::yandex::Browse::History::_iso_to_epoch('2026-11-02T11:16:17+03:00');
    my $t_min  = Plugins::yandex::Browse::History::_iso_to_epoch('2026-11-02T03:16:17-05:00');

    is($t_plus, $t_utc, '_iso_to_epoch adjusts +03:00 timezone offset correctly');
    is($t_min,  $t_utc, '_iso_to_epoch adjusts -05:00 timezone offset correctly');
}

# --------------------------------------------------------------------------
# Test 36: handleAudiobooksHistory displays chapter/track and progress% simultaneously
# --------------------------------------------------------------------------
{
    my $mock_client = MockClient2->new();
    my $api_client  = Plugins::yandex::API::Async->new('dummy_token');

    local *Plugins::yandex::API::Async::get_bookshelf_recently_played = sub {
        my ($self, $page, $pageSize, $cb) = @_;
        $cb->({
            entities => [
                {
                    type => 'album',
                    album => {
                        id           => 32792140,
                        title        => 'Джордж Оруэлл',
                        artists      => [{ name => 'Андрей Крупник' }],
                        durationSec  => 24492,
                        durationLeft => 137,
                    },
                    listeningDate => '2026-10-29T10:21:29Z',
                    track => {
                        id    => '129893157',
                        title => 'Джордж Оруэлл. Часть 38',
                        streamProgress => { endPositionSec => 0, everFinished => \0 },
                    },
                },
            ],
        });
    };

    my $bookshelf_res;
    Plugins::yandex::Browse::History::handleAudiobooksHistory(
        $mock_client,
        sub { $bookshelf_res = shift; },
        {},
        $api_client
    );

    ok(defined $bookshelf_res && $bookshelf_res->{items}, 'Bookshelf returned Orwell item');
    my $item = $bookshelf_res->{items}[0];
    is($item->{line1}, 'Джордж Оруэлл', 'Audiobook title matches');
    like($item->{line2}, qr{Часть 38}, 'Audiobook subtitle displays chapter/track title');
    like($item->{line2}, qr{99%}, 'Audiobook subtitle displays progress percentage');
    like($item->{line2}, qr{29\.10\.2026}, 'Audiobook subtitle displays listening date');
}

# --------------------------------------------------------------------------
# Test 37: handleBookChaptersList displays status badge and marks current chapter
# --------------------------------------------------------------------------
{
    my $mock_client = MockClient2->new();
    my $api_client  = Plugins::yandex::API::Async->new('dummy_token');

    local *Plugins::yandex::API::Async::get_album_with_tracks = sub {
        my ($self, $album_id, $cb) = @_;
        $cb->({
            id           => 32792140,
            title        => 'George Orwell',
            lastListened => { trackId => '102' },
            volumes => [
                [
                    {
                        id         => '101',
                        title      => 'Chapter 1',
                        durationMs => 300000,
                        streamProgress => { everFinished => \1, endPositionSec => 0 },
                    },
                    {
                        id         => '102',
                        title      => 'Chapter 2',
                        durationMs => 400000,
                        streamProgress => { everFinished => \0, endPositionSec => 120 },
                    },
                    {
                        id         => '103',
                        title      => 'Chapter 3',
                        durationMs => 500000,
                        streamProgress => { everFinished => \0, endPositionSec => 0 },
                    },
                ]
            ],
        });
    };

    my $chapters_res;
    Plugins::yandex::Browse::History::handleBookChaptersList(
        $mock_client,
        sub { $chapters_res = shift; },
        {},
        $api_client,
        32792140
    );

    ok(defined $chapters_res && $chapters_res->{items}, 'Chapters list returned');
    is(scalar(@{$chapters_res->{items}}), 3, 'Three chapters returned');

    # Chapter 1 finished
    like($chapters_res->{items}[0]{line2}, qr{Finished|Прослушано}, 'Chapter 1 marked finished');

    # Chapter 2 is current and in-progress
    like($chapters_res->{items}[1]{line1}, qr{▶ 2\. Chapter 2}, 'Chapter 2 marked with play arrow');
    like($chapters_res->{items}[1]{line2}, qr{2:00 / 6:40}, 'Chapter 2 displays offset position');

    # Chapter 3 not started
    is($chapters_res->{items}[2]{line1}, '3. Chapter 3', 'Chapter 3 title unmodified');
    is($chapters_res->{items}[2]{line2}, '8:20', 'Chapter 3 displays duration only');
}

# --------------------------------------------------------------------------
# Test 38: handleMusicHistory formats API history tabs without local prefs
# --------------------------------------------------------------------------
{
    my $mock_client = MockClient2->new();
    my $api_client  = Plugins::yandex::API::Async->new('dummy_token');

    my ($sec, $min, $hour, $mday, $mon, $year) = localtime(time);
    my $today_str = sprintf("%04d-%02d-%02d", $year + 1900, $mon + 1, $mday);

    my $prefs = Slim::Utils::Prefs::preferences('plugin.yandex');
    my $userId = eval { Plugins::yandex::Plugin::_getUserIdForClient($mock_client) } || 'default';

    # Ensure no local history exists in prefs
    $prefs->remove("recent_played_music_${userId}");

    # Mock get_music_history returning tabs directly from API
    local *Plugins::yandex::API::Async::get_music_history = sub {
        my ($self, $count, $cb) = @_;
        $cb->({
            historyTabs => [
                {
                    date  => $today_str,
                    items => [
                        {
                            tracks => [
                                {
                                    type => 'track',
                                    data => {
                                        fullModel => {
                                            id         => '2773110',
                                            title      => 'Time',
                                            durationMs => 422000,
                                            artists    => [{ name => 'Pink Floyd' }],
                                            albums     => [{ title => 'The Dark Side of the Moon', id => 298151 }],
                                            timestamp  => '2026-11-03T10:00:00Z',
                                        }
                                    }
                                }
                            ]
                        }
                    ],
                },
                {
                    date  => '2026-10-30',
                    items => [],
                }
            ],
        });
    };

    my $history_res;
    Plugins::yandex::Browse::History::handleMusicHistory(
        $mock_client,
        sub { $history_res = shift; },
        {},
        $api_client
    );

    ok(defined $history_res && $history_res->{items}, 'Music history returned tabs from API');
    is(scalar(@{$history_res->{items}}), 2, 'Two tabs returned');
    like($history_res->{items}[0]{name}, qr{Today|Сегодня}, 'First tab in music history is localized Today');
    is($history_res->{items}[1]{name}, '30.10.2026', 'Second tab formatted as dd.mm.yyyy');

    # Verify no local prefs were accessed or written
    is($prefs->get("recent_played_music_${userId}"), undef, 'No local history written to prefs');

    # Inspect today tracks
    my $day_tracks_tab = $history_res->{items}[0]{passthrough}[1];
    my $day_tracks_res;
    Plugins::yandex::Browse::History::handleMusicHistoryDayTracks(
        $mock_client,
        sub { $day_tracks_res = shift; },
        {},
        $api_client,
        $day_tracks_tab
    );

    ok(defined $day_tracks_res && $day_tracks_res->{items}, 'Today tracks returned');
    like($day_tracks_res->{title}, qr{Today|Сегодня}, 'Today day tracks submenu title is localized Today');
    is($day_tracks_res->{items}[0]{line1}, 'Time', 'Track title matches');
    like($day_tracks_res->{items}[0]{line2}, qr{Pink Floyd}, 'Track line2 has artist');
    like($day_tracks_res->{items}[0]{line2}, qr{The Dark Side of the Moon}, 'Track line2 has album');

    # Empty tabs case
    local *Plugins::yandex::API::Async::get_music_history = sub {
        my ($self, $count, $cb) = @_;
        $cb->({ historyTabs => [] });
    };

    my $empty_res;
    Plugins::yandex::Browse::History::handleMusicHistory(
        $mock_client,
        sub { $empty_res = shift; },
        {},
        $api_client
    );
    ok(defined $empty_res && $empty_res->{items}, 'Empty history returned items');
    is($empty_res->{items}[0]{name}, 'PLUGIN_YANDEX_NO_HISTORY', 'Empty tabs returns NO_HISTORY message');
}

# --------------------------------------------------------------------------
# Test 39: API::Async::get_user_contexts queries /users/{uid}/contexts
# --------------------------------------------------------------------------
{
    my $api = Plugins::yandex::API::Async->new('dummy_token');
    $api->{userId} = '19183055';

    my ($req_url, $req_params);
    no warnings 'redefine';
    local *Plugins::yandex::API::Async::get = sub {
        my ($self, $url, $params, $cb, $err_cb) = @_;
        $req_url    = $url;
        $req_params = $params;
        $cb->({ result => { contexts => [] } }) if $cb;
    };

    my $contexts_result;
    $api->get_user_contexts(
        sub { $contexts_result = shift; },
        sub { }
    );

    like($req_url, qr{/users/19183055/contexts$}, 'get_user_contexts queries /users/19183055/contexts');
    is($req_params->{trackCount}, 10, 'get_user_contexts sets trackCount=10');
    is($req_params->{contextCount}, 30, 'get_user_contexts sets contextCount=30');
    ok(defined $contexts_result, 'get_user_contexts invoked success callback');
}

# --------------------------------------------------------------------------
# Test 40: Audiobook chapters are strictly filtered out of API Music History
# --------------------------------------------------------------------------
{
    my $mock_client = MockPlayerClient->new();
    my $api_client  = Plugins::yandex::API::Async->new('dummy_token');

    my $prefs = Slim::Utils::Prefs::preferences('plugin.yandex');
    my $userId = eval { Plugins::yandex::Plugin::_getUserIdForClient($mock_client) } || 'default';

    my $day_tab = {
        date  => '2026-11-03',
        items => [
            {
                tracks => [
                    {
                        type => 'track',
                        data => {
                            fullModel => {
                                id        => '153294569',
                                title     => 'Роберт Шекли. «Корпорация „Бессмертие"». Часть 3',
                                artists   => [{ name => 'Григорий Перель' }],
                                albums    => [{ title => 'Роберт Шекли. «Корпорация „Бессмертие"»', id => 19752174 }],
                                timestamp => '2026-11-03T11:00:00Z',
                            }
                        }
                    },
                    {
                        type => 'track',
                        data => {
                            fullModel => {
                                id        => '999999',
                                title     => 'Actual Music Song',
                                artists   => [{ name => 'Rock Band' }],
                                albums    => [{ title => 'Rock Album', id => 888888 }],
                                timestamp => '2026-11-03T11:05:00Z',
                            }
                        }
                    }
                ]
            }
        ]
    };

    my $day_tracks;
    Plugins::yandex::Browse::History::handleMusicHistoryDayTracks(
        $mock_client,
        sub { $day_tracks = shift; },
        {},
        $api_client,
        $day_tab
    );

    ok(defined $day_tracks && $day_tracks->{items}, 'Day tracks returned');
    is(scalar(@{$day_tracks->{items}}), 1, 'Only 1 track returned (audiobook filtered out)');
    is($day_tracks->{items}[0]{line1}, 'Actual Music Song', 'The only track in music history is the actual music track');
    is($prefs->get("recent_played_music_${userId}"), undef, 'No history stored in prefs');
}

# --------------------------------------------------------------------------
# Test 41: Plugin::initPlugin cleans up legacy recent_played_music from prefs
# --------------------------------------------------------------------------
{
    my $prefs = Slim::Utils::Prefs::preferences('plugin.yandex');
    $prefs->set('recent_played_music_19183055', [{ track_id => '123' }]);
    $prefs->set('recent_played_music_default', [{ track_id => '456' }]);
    $prefs->set('recent_played_music_orphaned999', [{ track_id => '789' }]);
    $prefs->set('accounts', { '19183055' => { token => 'dummy' } });

    no warnings 'redefine';
    local *Plugins::yandex::Plugin::_init_api_client = sub {};

    Plugins::yandex::Plugin->initPlugin();

    is($prefs->get('recent_played_music_19183055'), undef, 'recent_played_music_19183055 cleaned up from prefs');
    is($prefs->get('recent_played_music_default'), undef, 'recent_played_music_default cleaned up from prefs');
    is($prefs->get('recent_played_music_orphaned999'), undef, 'recent_played_music_orphaned999 cleaned up from prefs');
}

1;


