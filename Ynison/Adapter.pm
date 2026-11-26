package Plugins::yandex::Ynison::Adapter;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Adapter - the seam between the from-scratch client and the legacy Plugin.pm

=head1 DESCRIPTION

Wraps Ynison::Client with the method surface and compat fields legacy
Plugin.pm expects (update_state, update_cached_queue, get_current_progress_ms,
send_volume_update, radio_replenish, skip_forward/skip_back, the
{yandex_queue}/{syncing_from_yandex}/{seek_grace_until}/{prefetch_inflight}/
{we_are_active}/{sent_paused} fields). The listener receives the legacy frame
shape plus the client's classification flags; the compat cache {yandex_queue}
is updated ONLY by update_cached_queue (lesson L5); radio_replenish keeps the
200-item window and extends the cache too (lesson L7); skip publishes the
neighbour in playback order with a published-index dedup. Slim is used only
for the device-id preference and the fallback timers.

=cut

# The seam between the from-scratch client (Ynison/Client.pm) and the legacy
# Plugin.pm expectations. The listener receives the legacy frame shape plus
# the client's classification flags; the compat cache {yandex_queue} is
# updated ONLY by update_cached_queue (lesson L5); radio_replenish keeps the
# 200-item window and extends the cache too (lesson L7).

use strict;
use warnings;

use Storable qw(dclone);
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::yandex::Ynison::Client ();
use Plugins::yandex::Ynison::Constants ();
use Plugins::yandex::Ynison::Message ();

my $C = 'Plugins::yandex::Ynison::Constants';

sub new {
    my ($class, $player, $token, $user_id, %o) = @_;
    return unless $player && $token && $user_id;
    my $clock = $o{clock} // sub { Time::HiRes::time() };
    my $api;
    if ($o{scheduler}) { $api = $o{scheduler} }
    else {
        require Slim::Utils::Timers;
        $api = {
            set  => sub { my ($delay, $cb) = @_; Slim::Utils::Timers::setTimer($player, Time::HiRes::time() + $delay, $cb) },
            kill => sub { my ($h) = @_; Slim::Utils::Timers::killSpecific($h) },
        };
    }
    my $device_id = $o{device_id} // _device_id_for($player);
    my $self = bless {
        client        => $player,
        device_id     => $device_id,
        yandex_queue  => undef,
        syncing_from_yandex => 0,
        seek_grace_until    => 0,
        prefetch_inflight   => 0,
        we_are_active       => 0,
        sent_paused         => 0,
        debug_mode          => 0,
        engine              => 'new',
        last_frame          => undef,
        listeners           => [],
        logger              => $o{logger},
        clock               => $clock,
    }, $class;
    $self->{_client} = Plugins::yandex::Ynison::Client->new(
        token => $token, user_id => $user_id,
        device => {
            device_id   => $device_id,
            title       => $player->name . ' (LMS)',
            app_name    => $C->APP_NAME(),
            app_version => $C->APP_VERSION(),
        },
        can_be_player => 1,
        get_volume => sub { ($player->volume || 0) / 100 },
        on_state => sub { $self->_on_client_state($_[0]) },
        on_event => sub {                                   # the client's only log channel: surface it
            my ($level, $msg) = @_;
            my $m = $level eq 'error' ? 'error' : $level eq 'warn' ? 'warn' : 'info';
            Slim::Utils::Log::logger('plugin.yandex')->$m("Ynison[new] $msg");
        },
        on_reclaim => sub { $self->update_state; $self->{_client}->set_active_device($device_id) },
        transport_factory => $o{transport_factory},
        logger => sub {                                     # Transport/_log passthrough: surface in server.log
            my ($level, $msg) = @_;
            my $m = $level eq 'error' ? 'error' : $level eq 'warn' ? 'warn' : 'info';
            Slim::Utils::Log::logger('plugin.yandex')->$m("Ynison[new] $msg");
        },
        scheduler => $api, clock => $clock,
    );
    return $self;
}

# The same preference key as the legacy engine (constraint 11): switching
# engines keeps the device's identity. 16 hex chars, like the legacy generator.
sub _device_id_for {
    my ($player) = @_;
    my $prefs = preferences('plugin.yandex');
    my $key = 'ynison_device_id_' . $player->id;
    my $id = $prefs->get($key);
    unless ($id) {
        $id = sprintf('%08x%08x', int(rand(0xffffffff)), int(rand(0xffffffff)));
        $prefs->set($key, $id);
    }
    return $id;
}

# --- legacy seam ----------------------------------------------------------------
sub on_state   { my ($self, $cb) = @_; push @{ $self->{listeners} }, $cb; return }
sub connect    { my ($self) = @_; $self->{_client}->connect; return }
sub disconnect { my ($self) = @_; $self->{_client}->disconnect; return }
sub device_id  { my ($self) = @_; return $self->{device_id} }
sub is_connected { my ($self) = @_; return $self->{_client}->is_ready }
sub is_active  { my ($self) = @_; return $self->is_connected && $self->{we_are_active} }

sub update_cached_queue {
    my ($self, $player_state) = @_;
    $self->{yandex_queue} = dclone($player_state->{player_queue})
        if $player_state && ref $player_state->{player_queue} eq 'HASH';
    return;
}

sub get_current_progress_ms {
    my ($self, $status, $now_ms) = @_;
    return 0 unless $status && ref $status eq 'HASH';
    my $progress = defined $status->{progress_ms}
        && "$status->{progress_ms}" =~ /^(\d+)/ ? 0 + $1 : 0;
    my $ts = defined $status->{version} && defined $status->{version}{timestamp_ms}
        && "$status->{version}{timestamp_ms}" =~ /^(\d+)/ ? 0 + $1 : 0;
    my $paused = ref $status->{paused} ? ${ $status->{paused} } : ($status->{paused} ? 1 : 0);
    if (!$paused && $ts > 0) {
        $now_ms //= int($self->{clock}->() * 1000);
        my $elapsed = $now_ms - $ts;
        $elapsed = 0 if $elapsed < 0;
        my $speed = $status->{playback_speed} || 1.0;
        $speed = 1.0 if $speed <= 0;
        $progress += int($elapsed * $speed);
    }
    return Plugins::yandex::Ynison::Message::clamp_progress($progress, 0 + ($status->{duration_ms} // 0));
}

# --- inbound frames ----------------------------------------------------------------
sub _on_client_state {
    my ($self, $client) = @_;
    my $ev = $client->last_event;
    $self->{we_are_active} = $self->{device_id} eq ($client->state->active_device_id // '') ? 1 : 0;
    # A foreign-authored queue version means the queue changed elsewhere;
    # reset the skip dedup so the next legitimate skip publishes even if it
    # lands on the previously published index.
    my $q_author = (($client->state->player_queue || {})->{version} || {})->{device_id} // '';
    $self->{published_index} = undef
        if $q_author ne '' && $q_author ne $self->{device_id};
    my $ps = $client->state->player_state;
    my $frame = {
        ping => 0,
        device_id                 => $self->{device_id},
        player_state              => $ps,
        active_device_id_optional => $client->state->active_device_id,
        devices                   => $client->state->devices,
        echo                      => $ev->{is_echo} ? 1 : 0,
        relay                     => $ev->{status_is_relay} ? 1 : 0,
        item_changed              => $ev->{item_changed} ? 1 : 0,
        active_changed            => $ev->{active_changed} ? 1 : 0,
        suppress_status           => $ev->{suppress_status} ? 1 : 0,
        engine                    => 'new',
    };
    $self->{last_frame} = $frame;

    # Live visibility: the first state frame and every meaningful change.
    $self->{_frames} = ($self->{_frames} // 0) + 1;
    if ($self->{_frames} == 1
        || $ev->{item_changed} || $ev->{active_changed} || $ev->{status_is_relay})
    {
        my $st = $client->state;
        $self->_log('info', sprintf('state #%d: track=%s idx=%s paused=%d active=%s devices=%d echo=%d relay=%d',
            $self->{_frames},
            $st->current_track_id // '-', $st->current_index, $st->is_paused,
            (defined $st->active_device_id ? substr($st->active_device_id, 0, 6) . '…' : '-'),
            scalar @{ $st->devices }, $ev->{is_echo} ? 1 : 0, $ev->{status_is_relay} ? 1 : 0));
    }
    for my $cb (@{ $self->{listeners} }) {
        eval { $cb->($frame) };
        $self->_log('error', "listener error: $@") if $@;
    }
    return;
}

# --- outbound: mirror LMS playback into Ynison -----------------------------------
sub update_state {
    my ($self, %opts) = @_;
    return if $self->{syncing_from_yandex};
    my $client = $self->{client};
    return unless $self->{_client}->is_ready;
    return unless $client->isPlaying || $client->isPaused;

    my $song = $client->playingSong;
    my ($track_id) = $song && $song->track ? ($song->track->url =~ /yandexmusic:\/\/(\d+)/) : ();
    if (!$track_id) {
        return unless $opts{allow_empty};
        # Local override: publish an empty queue so the phone drops the session.
        $self->{_client}->set_player_state(Plugins::yandex::Ynison::Message::empty_player_state($self->{device_id}));
        return;
    }

    my $paused = ($client->isPaused || !$client->isPlaying) ? 1 : 0;
    my $dur_ms = $song ? int(($song->duration || 0) * 1000) : 0;
    my $prog_ms = 0;
    eval { $prog_ms = int((Slim::Player::Source::songTime($client) || 0) * 1000) };
    $prog_ms = Plugins::yandex::Ynison::Message::clamp_progress($prog_ms, $dur_ms);

    my $cache = $self->{yandex_queue};
    my $list = $cache && $cache->{playable_list} ? $cache->{playable_list} : [];
    my $our_index;
    for my $i (0 .. $#$list) {
        if (($list->[$i]{playable_id} // '') eq ($track_id // '')) { $our_index = $i; last }
    }
    if (!defined $our_index) {
        # The LMS track is not part of the Ynison queue: publish an empty state.
        return unless $opts{allow_empty};
        $self->{_client}->set_player_state(Plugins::yandex::Ynison::Message::empty_player_state($self->{device_id}));
        return;
    }

    # Same playback as the retained queue: report the position only.
    $self->{_client}->report_status($prog_ms, $dur_ms, $paused, strict => $opts{strict} ? 1 : 0);
    return;
}

sub send_volume_update {
    my ($self) = @_;
    return unless $self->{_client}->is_ready;
    $self->{_client}->set_volume(($self->{client}->volume || 0) / 100);
    return;
}

# --- skip: publish the neighbour in the playback order --------------------------
sub _publish_neighbour {
    my ($self, $delta) = @_;
    return unless $self->{_client}->is_ready;
    my $queue = dclone($self->{_client}->state->player_queue);
    my $list = $queue->{playable_list} or return;
    my $idx = $queue->{current_playable_index} // -1;
    my $next = $idx + $delta;
    return if $next < 0 || $next > $#$list;
    return if defined $self->{published_index} && $next == $self->{published_index};
    $self->{published_index} = $next;
    $queue->{current_playable_index} = $next;
    $queue->{version} = Plugins::yandex::Ynison::Message::new_version($self->{device_id});
    my $ps = dclone($self->{_client}->state->player_state);
    $ps->{player_queue} = $queue;
    $ps->{status} = {
        progress_ms => '0', duration_ms => '0',
        paused => \0, playback_speed => 1.0,
        version => Plugins::yandex::Ynison::Message::new_version($self->{device_id}),
    };
    return $self->{_client}->set_player_state($ps);
}

sub skip_forward { my ($self) = @_; return $self->_publish_neighbour(1) }
sub skip_back    { my ($self) = @_; return $self->_publish_neighbour(-1) }

# --- radio replenish: a 200-item window around the current item -----------------
sub radio_replenish {
    my ($self, $new_items) = @_;
    return unless $new_items && @$new_items;
    return unless $self->{_client}->is_ready && $self->{_client}->state->is_active;

    my $queue = dclone($self->{_client}->state->player_queue);
    my $list = [ @{ $queue->{playable_list} || [] }, @$new_items ];
    my $current = $queue->{current_playable_index} // -1;
    my $dropped = 0;
    if (@$list > $C->QUEUE_WINDOW()) {
        $dropped = @$list - $C->QUEUE_WINDOW();
        splice(@$list, 0, $dropped);
    }
    $queue->{playable_list} = $list;
    $queue->{current_playable_index} = $current - $dropped;
    $queue->{version} = Plugins::yandex::Ynison::Message::new_version($self->{device_id});
    my $ps = dclone($self->{_client}->state->player_state);
    $ps->{player_queue} = $queue;
    $self->{_client}->set_player_state($ps);

    # Legacy parity: extend the compat cache, or the next inbound frame looks
    # like a queue change and triggers a full rebuild (lesson L7).
    if (my $cache = $self->{yandex_queue}) {
        $cache = dclone($cache);
        my $cached = [ @{ $cache->{playable_list} || [] }, @$new_items ];
        my $d = @$cached > $C->QUEUE_WINDOW() ? @$cached - $C->QUEUE_WINDOW() : 0;
        splice(@$cached, 0, $d) if $d;
        $cache->{playable_list} = $cached;
        $cache->{current_playable_index} = ($cache->{current_playable_index} // 0) - $d;
        $cache->{version} = $queue->{version};
        $self->{yandex_queue} = $cache;
    }
    return $dropped;
}

sub debug_snapshot {
    my ($self) = @_;
    return {
        engine => 'new',
        ready  => $self->{_client}->is_ready,
        active => $self->{we_are_active},
        cache_size => $self->{yandex_queue} && $self->{yandex_queue}{playable_list}
                    ? scalar @{ $self->{yandex_queue}{playable_list} } : 0,
        client => $self->{_client}->debug_snapshot,
    };
}

sub _log {
    my ($self, $level, $msg) = @_;
    my $m = $level eq 'error' ? 'error' : $level eq 'warn' ? 'warn' : 'info';
    if (my $l = $self->{logger}) { $l->($m, $msg); return }   # test override
    Slim::Utils::Log::logger('plugin.yandex')->$m("Ynison[new] $msg");
    return;
}

1;
