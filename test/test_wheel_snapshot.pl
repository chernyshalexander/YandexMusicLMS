#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More tests => 31;

# Mock Slim framework and environment
BEGIN {
    for my $c (qw(SCANNER PERFMON DEBUGLOG INFOLOG STATISTICS ISWINDOWS ISMAC RESIZER WEBUI NOMYSB TRANSCODING SB1SLIMP3SYNC LOCALFILE NOBROWSECACHE SLIM_SERVICE NOUPNP ISACTIVEPERL HAS_AIO)) {
        no strict "refs"; *{"main::$c"} = sub () { 0 };
    }
    require Slim::Utils::OSDetect; Slim::Utils::OSDetect->init();
    $INC{"Slim/Utils/Cache.pm"} = 1; $INC{"Slim/Utils/DbCache.pm"} = 1;
    package Slim::Utils::Cache; sub new { bless {}, shift } sub get { undef } sub set {}
    package Slim::Utils::DbCache; sub new { bless {}, shift } sub db { bless {}, shift } sub prepare { bless {}, shift } sub execute {} sub fetchrow_array {} sub selectrow_array {}
    package main;
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
use Plugins::yandex::Browse::Radio;

# Mock Client
package MockClient;
sub new { bless { id => '00:04:20:11:22:33', name => 'TestSqueezebox', executed => [] }, shift }
sub id { shift->{id} }
sub name { shift->{name} }
sub string { return $_[1] }
sub execute {
    my ($self, $cmd) = @_;
    push @{ $self->{executed} }, $cmd;
}

package main;

my $client = MockClient->new();

# 1. Initially snapshot should be empty
my $snap0 = Plugins::yandex::Plugin::get_wheel_snapshot($client, 'user:onyourwave');
is($snap0, undef, "Initial snapshot is empty");

# 2. Set snapshot
my $mock_menu = {
    items => [
        { name => 'Любимое', url => 'yandexmusic://rotor_session/_vibe_?seeds=diversity:favorite' },
        { name => 'Мировая классика', url => 'yandexmusic://rotor_session/_vibe_?seeds=genre:classicalmusic' },
        { name => 'Deep Purple', url => 'yandexmusic://rotor_session/_vibe_?seeds=artist:6920' },
    ],
    title => 'Колесо Моей волны',
};

Plugins::yandex::Plugin::set_wheel_snapshot($client, {
    menu_result => $mock_menu,
    wheel_id    => 'test-wheel-123',
    seeds_str   => 'user:onyourwave',
    timestamp   => time(),
});

# 3. Retrieve snapshot with matching seeds
my $snap1 = Plugins::yandex::Plugin::get_wheel_snapshot($client, 'user:onyourwave');
ok($snap1, "Retrieved snapshot with matching seeds");
is($snap1->{menu_result}->{items}->[1]->{name}, 'Мировая классика', "Index 1 is strictly 'Мировая классика'");

# 4. Attempt retrieval with different seeds should return undef
my $snap_diff = Plugins::yandex::Plugin::get_wheel_snapshot($client, 'genre:rock');
is($snap_diff, undef, "Snapshot does not match different seeds");

# 5. Simulate item click via handleVibeWheel: cache hit test
my $called_api = 0;
my $mock_yandex_client = bless {}, 'MockYandexClient';
{
    no warnings 'redefine';
    *MockYandexClient::wheel_new_with_seeds = sub { $called_api++; };
}

my $returned_menu;
Plugins::yandex::Browse::Radio::handleVibeWheel($client, sub { $returned_menu = shift; }, {}, $mock_yandex_client);

is($called_api, 0, "handleVibeWheel did NOT call API on cache hit");
is($returned_menu->{items}->[1]->{name}, 'Мировая классика', "Menu returned from cache has 'Мировая классика' at index 1");

# 6. Clear snapshot
Plugins::yandex::Plugin::clear_wheel_snapshot($client);
my $snap_cleared = Plugins::yandex::Plugin::get_wheel_snapshot($client, 'user:onyourwave');
is($snap_cleared, undef, "Snapshot successfully cleared");

# 7. Reshuffle ignores snapshot cache
Plugins::yandex::Plugin::set_wheel_snapshot($client, {
    menu_result => $mock_menu,
    wheel_id    => 'test-wheel-123',
    seeds_str   => 'diversity:reshuffle_123',
    timestamp   => time(),
});

my $reshuffle_api_called = 0;
{
    no warnings 'redefine';
    *MockYandexClient::wheel_new_with_seeds = sub {
        my ($self, $cl, $seeds, $cb) = @_;
        $reshuffle_api_called++;
        $cb->({ items => [], wheelId => 'reshuffled-wheel' });
    };
}

Plugins::yandex::Browse::Radio::handleVibeWheelReshuffle($client, sub {}, {}, $mock_yandex_client, 'diversity:reshuffle_123');
is($reshuffle_api_called, 1, "Reshuffle bypassed snapshot cache and called API");
is(Plugins::yandex::Plugin::get_wheel_state($client)->{wheel_id}, 'reshuffled-wheel', "Wheel state updated with new wheelId");

# 8. vibe_wheel_rebuild_on_play = 1 (default): wave items are links with play attribute
my $prefs = Slim::Utils::Prefs::preferences('plugin.yandex');
$prefs->set('vibe_wheel_rebuild_on_play', 1);
Plugins::yandex::Plugin::clear_wheel_snapshot($client);

my $raw_wheel_items = {
    wheelId => 'wheel-rebuild-1',
    items => [
        {
            type => 'WAVE',
            data => {
                wave => { name => 'Рок волна', seeds => ['genre:rock'] },
                agent => { cover => { uri => 'http://cover.jpg/%%' } },
            },
        },
        {
            type => 'WAVE',
            style => 'CONTROL_ACCENT',
            data => {
                wave => { seeds => ['user:onyourwave'] },
                agent => { cover => { uri => 'http://cover.jpg/%%' } },
            },
        },
    ],
};

{
    no warnings 'redefine';
    *MockYandexClient::wheel_new_with_seeds = sub {
        my ($self, $cl, $seeds, $cb) = @_;
        $cb->($raw_wheel_items);
    };
}

my $menu_rebuild_on;
Plugins::yandex::Browse::Radio::handleVibeWheel($client, sub { $menu_rebuild_on = shift; }, {}, $mock_yandex_client, 'genre:rock');
my $item0 = $menu_rebuild_on->{items}->[0];
is($item0->{type}, 'link', "When rebuild_on_play=1, regular wave item type is 'link'");
is($item0->{url}, \&Plugins::yandex::Browse::Radio::handleVibeWaveSelect, "Item url points to handleVibeWaveSelect");
ok($item0->{play}, "Item has play URL attribute for direct play");

# 9. handleVibeWaveSelect executes playlist play, records pending seed, and transitions to nowPlaying
my $play_cb_called = 0;
my $rebuilt_menu_result;
Plugins::yandex::Browse::Radio::handleVibeWaveSelect(
    $client,
    sub {
        $play_cb_called++;
        $rebuilt_menu_result = shift;
    },
    {},
    $mock_yandex_client,
    'genre:rock',
    $item0->{play}
);

is(scalar(@{ $client->{executed} }), 1, "Player executed playlist play command");
is($client->{executed}->[0]->[1], 'play', "Playlist play command executed");
is($prefs->client($client)->get('yandex_wheel_pending_seed'), 'genre:rock', "Pending seed stored in client prefs");
is($rebuilt_menu_result->{items}->[0]->{nowPlaying}, 1, "Returned menu has nowPlaying => 1 for LMS XMLBrowser goNow transition");

# 10. Cached snapshot retains clean items without nowPlaying flag
my $snap_after_play = Plugins::yandex::Plugin::get_wheel_snapshot($client, 'genre:rock');
ok($snap_after_play, "Snapshot was saved after rebuild on play");
is($snap_after_play->{menu_result}->{items}->[0]->{nowPlaying}, undef, "Stored snapshot has clean item without nowPlaying flag");

# 11. vibe_wheel_rebuild_on_play = 0: wave items are audio items with on_select => play
$prefs->set('vibe_wheel_rebuild_on_play', 0);
Plugins::yandex::Plugin::clear_wheel_snapshot($client);

my $menu_rebuild_off;
Plugins::yandex::Browse::Radio::handleVibeWheel($client, sub { $menu_rebuild_off = shift; }, {}, $mock_yandex_client, 'genre:rock');
my $item_off = $menu_rebuild_off->{items}->[0];
is($item_off->{type}, 'audio', "When rebuild_on_play=0, regular wave item type is 'audio'");
is($item_off->{on_select}, 'play', "When rebuild_on_play=0, on_select is 'play'");

# ---------------------------------------------------------------------------
# 12+. Delivered-snapshot fix for the index shift bug:
# XMLBrowser re-fetches the wheel level (args{quantity}==1) on every wave
# click and resolves the clicked index against that fresh list. After a
# rebuild-on-play the fresh list is reordered, so intermediate resolution
# must be served from the list last DELIVERED to the client.
# ---------------------------------------------------------------------------
$prefs->set('vibe_wheel_rebuild_on_play', 1);

# 12. Delivered snapshot is initially empty
is(Plugins::yandex::Plugin::get_delivered_wheel_snapshot($client), undef, "Delivered snapshot is initially empty");

# 13. set/get roundtrip
my $delivered_menu = {
    items => [ { name => 'Тест доставки', url => 'yandexmusic://rotor_session/_vibe_?seeds=genre:test' } ],
    title => 'Delivered',
};
Plugins::yandex::Plugin::set_delivered_wheel_snapshot($client, $delivered_menu);
is(Plugins::yandex::Plugin::get_delivered_wheel_snapshot($client)->{menu_result}->{items}->[0]->{name},
   'Тест доставки', "Delivered snapshot roundtrip");

# 14. A real menu open (no initial_seeds, no trigger_now_playing) marks delivered
Plugins::yandex::Plugin::clear_wheel_snapshot($client);
Plugins::yandex::Plugin::set_wheel_state($client, { wheel_id => 'state-open', seeds => ['user:onyourwave'] });

my $open_wheel = {
    wheelId => 'open-wheel-1',
    items => [
        { type => 'WAVE', data => { wave => { name => 'Открытая волна X', seeds => ['genre:classical'] },
                                    agent => { cover => { uri => 'http://cover.jpg/%%' } } } },
    ],
};
my $open_api_calls = 0;
{
    no warnings 'redefine';
    *MockYandexClient::wheel_new_with_seeds = sub {
        my ($self, $cl, $seeds, $cb) = @_;
        $open_api_calls++;
        $cb->($open_wheel);
    };
}

my $menu_open;
Plugins::yandex::Browse::Radio::handleVibeWheel($client, sub { $menu_open = shift; }, {}, $mock_yandex_client);
is($open_api_calls, 1, "Real menu open fetched the wheel from API");
is(Plugins::yandex::Plugin::get_delivered_wheel_snapshot($client)->{menu_result}->{items}->[0]->{name},
   'Открытая волна X', "Real menu open marked its list as delivered");

# 15. Intermediate resolution (quantity==1) serves the delivered list and does
# NOT hit the API, even when the current snapshot has drifted (reordered)
Plugins::yandex::Plugin::set_wheel_snapshot($client, {
    menu_result => {
        items => [ { name => 'НОВАЯ волна A' }, { name => 'НОВАЯ волна B' } ],
        title => 'Drifted',
    },
    wheel_id    => 'drift-wheel',
    seeds_str   => 'genre:rock',
    timestamp   => time(),
});

my $inter_cb_menu;
Plugins::yandex::Browse::Radio::handleVibeWheel($client, sub { $inter_cb_menu = shift; }, { quantity => 1 }, $mock_yandex_client);
is($open_api_calls, 1, "Intermediate resolution did NOT call the API");
is($inter_cb_menu->{items}->[0]->{name}, 'Открытая волна X',
   "Intermediate resolution served the delivered list, not the drifted snapshot");

# 16. handleVibeWaveSelect intermediate descent: no playback, no pending overwrite
$prefs->client($client)->set('yandex_wheel_pending_seed', 'old-seed');
my $executed_before = scalar @{ $client->{executed} };
my $guard_cb_called = 0;
my $guard_menu;
Plugins::yandex::Browse::Radio::handleVibeWaveSelect(
    $client,
    sub { $guard_cb_called++; $guard_menu = shift; },
    { quantity => 1 },
    $mock_yandex_client,
    'genre:rock',
    'yandexmusic://rotor_session/_vibe_?seeds=genre%3Arock',
);
is(scalar @{ $client->{executed} }, $executed_before, "Intermediate wave descent did NOT start playback");
is($prefs->client($client)->get('yandex_wheel_pending_seed'), 'old-seed', "Intermediate wave descent did NOT touch pending seed");
is($guard_menu->{items}->[0]->{name}, 'НОВАЯ волна A', "Intermediate wave descent served current wheel snapshot");

# 17. A real wave select (rebuild-on-play) must NOT overwrite delivered
Plugins::yandex::Browse::Radio::handleVibeWaveSelect(
    $client,
    sub {},
    {},
    $mock_yandex_client,
    'genre:rock',
    'yandexmusic://rotor_session/_vibe_?seeds=genre%3Arock',
);
{
    no warnings 'redefine';
    *MockYandexClient::wheel_new_with_seeds = sub {
        my ($self, $cl, $seeds, $cb) = @_;
        $cb->($raw_wheel_items);
    };
}
is(Plugins::yandex::Plugin::get_delivered_wheel_snapshot($client)->{menu_result}->{items}->[0]->{name},
   'Открытая волна X', "Rebuild-on-play select did NOT overwrite delivered snapshot");

# 18. Delivered snapshot expires after TTL (3600s)
my $snap_id = $client->id;
{
    no strict 'refs';
    $Plugins::yandex::Plugin::wheel_delivered_snapshots{$snap_id}{timestamp} = time() - 3601;
}
is(Plugins::yandex::Plugin::get_delivered_wheel_snapshot($client), undef, "Delivered snapshot expires after TTL");

