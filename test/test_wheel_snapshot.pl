#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More tests => 20;

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

