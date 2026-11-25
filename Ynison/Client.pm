package Plugins::yandex::Ynison::Client;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Client - the protocol orchestrator of the Ynison engine

=head1 DESCRIPTION

Runs the two-step connection (redirector, then state service), registers after
every connection, arms the heartbeat from the redirector's keep-alive params,
and routes inbound frames through Ynison::State and the reconnect policy.
Everything external is injected: the transport (or its factory), the scheduler
({set => cb, kill => cb}) and the clock. The go-away window of a server error
is waited out exactly here (constraint 8). The reconnect engine schedules one
retry at a time along the policy ladder, arms on_reclaim after the settle
window of every reconnect, and refreshes the token once per run through the
on_auth_failure callback. The outbound commands live here too: report_status
with its guards (duration, the empty-queue gate, the active-device gate and
the dedup window), the player-state/active-device/session-params/volume
setters, and the strict-send queue that is flushed after a re-registration.

=cut

# The protocol orchestrator: redirector → state service, registration after
# every connection, heartbeat from the redirector's keep-alive params, inbound
# frame handling through Ynison::State and the reconnect policy. Everything
# external is injected: the transport (or its factory), the scheduler
# ({set => cb, kill => cb}) and the clock. The reconnect engine, the settle
# window reclaim and the token refresh live here too, as do the outbound
# commands: guarded report_status, the setters and the strict-send queue.

use strict;
use warnings;

use Plugins::yandex::Ynison::Constants ();
use Plugins::yandex::Ynison::Message ();
use Plugins::yandex::Ynison::State ();
use Plugins::yandex::Ynison::ReconnectPolicy ();
use Plugins::yandex::Ynison::Transport ();

my $C = 'Plugins::yandex::Ynison::Constants';

sub new {
    my ($class, %o) = @_;
    my $device = $o{device} or die 'device info required';
    my $clock = $o{clock} // sub { Time::HiRes::time() };
    my $self = bless {
        token       => $o{token},
        user_id     => $o{user_id},
        redirect_host => $o{redirect_host} // $C->YNISON_REDIRECT_HOST(),
        redirect_port => $o{redirect_port} // $C->YNISON_PORT(),
        tls           => $o{transport_tls} // 1,
        device      => $device,
        can_be_player => $o{can_be_player} ? 1 : 0,
        mute_if_passive => exists $o{mute_events_if_passive} ? ($o{mute_events_if_passive} ? 1 : 0) : 1,
        get_volume  => $o{get_volume} // sub { 0 },
        on_state    => $o{on_state},
        on_connect  => $o{on_connect},
        on_reclaim  => $o{on_reclaim},
        on_auth_failure => $o{on_auth_failure}, # () -> (token, 'refreshed'|'permanent')
        on_event    => $o{on_event} // sub { },
        factory     => $o{transport_factory},
        scheduler   => $o{scheduler},
        clock       => $clock,
        logger      => $o{logger} // sub { },
        state       => Plugins::yandex::Ynison::State->new(device_id => $device->{device_id}, now_s => $clock),
        policy      => Plugins::yandex::Ynison::ReconnectPolicy->new,
        ws          => undef,
        redirect_ws => undef,
        strict_queue => [],                     # strict sends made while the channel is down
        ready       => 0,
        ever_connected => 0,
        settle_until => 0,
        last_event  => undef,
        saw_frame   => 0,                       # a state frame arrived on THIS connection
        first_frame_timer => undef,
        reconnect_timer => undef,               # at most one retry in flight (the handle)
        reclaim_timer => undef,                 # on_reclaim after a reconnect's settle window
        auth_refreshed => 0,                    # one token refresh attempt per run
        interval_s  => undef,
        stopped     => 0,
    }, $class;
    return $self;
}

# The journal callback is the module's only voice (constraint 14); a dying
# sink must not abort the event loop, and reporting a dying sink through the
# same sink would recurse - so that one failure is swallowed.
sub _log {
    my ($self, $level, $msg) = @_;
    return if $level eq 'debug' || $self->{in_log};
    $self->{in_log} = 1;
    eval { $self->{on_event}->($level, $msg) };
    $self->{in_log} = 0;
    return;
}

sub state       { $_[0]->{state} }
sub is_ready    { $_[0]->{ready} ? 1 : 0 }
sub last_event  { $_[0]->{last_event} }

sub in_settle_window {
    my ($self) = @_;
    return $self->{clock}->() < $self->{settle_until} ? 1 : 0;
}

sub _factory_transport {
    my ($self) = @_;
    if (my $f = $self->{factory}) {
        return $f->(logger => sub { }, scheduler => $self->{scheduler});
    }
    return Plugins::yandex::Ynison::Transport->new(logger => $self->{logger}, scheduler => $self->{scheduler});
}

sub _headers {
    my ($self, $ticket, $session_id) = @_;
    return [
        ['Sec-WebSocket-Protocol', Plugins::yandex::Ynison::Message::protocol_header(
            device_id  => $self->{device}{device_id},
            app_name   => $self->{device}{app_name},
            app_version => $self->{device}{app_version},
            token      => $self->{token},
            user_id    => $self->{user_id},
            defined $ticket ? (ticket => $ticket) : (),
            defined $session_id ? (session_id => $session_id) : (),
        )],
        ['Authorization', 'OAuth ' . ($self->{token} // '')],
        ['Origin', $C->YNISON_ORIGIN()],
    ];
}

sub connect {
    my ($self) = @_;
    return if $self->{ready} || $self->{stopped} || defined $self->{reconnect_timer};
    my $t = $self->_factory_transport;
    $self->{redirect_ws} = $t;                          # tests pump this hop too
    $t->fetch_redirect($self->{redirect_host}, $C->YNISON_REDIRECT_PATH(), $self->_headers, sub {
        my (undef, $data, $status) = @_;
        return if $self->{stopped};
        if (!defined $data) {
            if (defined $status && ($status == 401 || $status == 403)) {
                $self->{policy}->on_server_error($C->ERR_UNAUTHENTICATED(), grpc_code => 16, go_away => 0, ladder => undef);
            }
            else {
                $self->{policy}->on_transport_failure;
            }
            $self->_log('error', 'redirector failed' . (defined $status ? " (HTTP $status)" : ''));
            $self->_schedule_reconnect;
            return;
        }
        my $ka = $data->{keep_alive_params};
        my $interval = $ka && $ka->{keep_alive_time_seconds} ? 0 + $ka->{keep_alive_time_seconds} : $C->WS_HEARTBEAT_DEFAULT();
        $interval = $C->WS_MIN_HEARTBEAT() if $interval < $C->WS_MIN_HEARTBEAT();
        $self->{interval_s} = $interval;
        $self->_connect_state($data->{host}, $data->{redirect_ticket}, $data->{session_id});
    }, port => $self->{redirect_port}, https => $self->{tls});
    return;
}

sub _connect_state {
    my ($self, $host, $ticket, $session_id) = @_;
    my ($h, $p) = $host =~ /^(.+):(\d+)$/ ? ($1, 0 + $2) : ($host, $C->YNISON_PORT());
    my $t = $self->_factory_transport;
    $t->set_heartbeat($self->{interval_s} // $C->WS_HEARTBEAT_DEFAULT());
    $t->open(
        host => $h, path => $C->YNISON_STATE_PATH(), https => $self->{tls}, port => $p,
        headers => $self->_headers($ticket, $session_id),
        on_open  => sub { $self->_on_channel_open($t) },
        on_text  => sub { my (undef, $msg) = @_; $self->_on_frame($msg) },
        on_close => sub { my (undef, $code, $reason) = @_; $self->_on_channel_closed("server closed the connection ($code $reason)") },
        on_error => sub { my (undef, $reason, $status) = @_; $self->_on_channel_closed("transport error: $reason") },
    );
    $self->{ws} = $t;
    return;
}

sub _on_channel_open {
    my ($self, $t) = @_;
    $self->{saw_frame} = 0;                             # the watchdog is per connection
    $self->{ready} = 1;
    $self->{settle_until} = $self->{ever_connected} ? $self->{clock}->() + $C->SETTLE_WINDOW() : 0;
    $self->{ever_connected} = 1;
    delete $self->{reconnect_timer};                    # a tick dialing while ready
    # Reclaim the active device after the settle window of a RECONNECT (the
    # condition on settle_until separates this from the first connect, whose
    # empty registration already makes the server drop us from the stage).
    if ($self->{settle_until} && $self->{on_reclaim} && $self->{scheduler}) {
        $self->{reclaim_timer} = $self->{scheduler}{set}->($C->SETTLE_WINDOW() + $C->RECLAIM_DELAY(), sub {
            return unless $self->{ready};
            delete $self->{reclaim_timer};              # the timer already fired
            $self->_log('info', 'reclaiming the active device after reconnect');
            eval { $self->{on_reclaim}->($self) };
            $self->_log('error', "on_reclaim listener failed: $@") if $@;
        });
    }
    $t->send_text(JSON::XS::VersionOneAndTwo::encode_json(
        Plugins::yandex::Ynison::Message::update_full_state(
            device => $self->_device_block,
            player_state => Plugins::yandex::Ynison::Message::empty_player_state($self->{device}{device_id}),
        )));
    $t->send_text(JSON::XS::VersionOneAndTwo::encode_json(Plugins::yandex::Ynison::Message::update_session_params($self->{mute_if_passive})));
    # Strict sends made while the channel was down ride right behind the
    # re-registration - before any state frame could matter.
    if (my $queued = $self->{strict_queue} && @{ $self->{strict_queue} }) {
        my @frames = @{ $self->{strict_queue} };
        $self->{strict_queue} = [];
        $t->send_text($_) for @frames;
        $self->_log('info', sprintf('flushed %d queued strict sends', scalar @frames));
    }
    # First-frame watchdog: a silent state channel must not hang forever.
    if (my $s = $self->{scheduler}) {
        $self->{first_frame_timer} = $s->{set}->($C->FIRST_FRAME_TIMEOUT(), sub {
            return unless $self->{ready} && !$self->{saw_frame};
            $self->_on_channel_closed('no state frame after connect');
        });
    }
    if ($self->{on_connect}) {
        eval { $self->{on_connect}->($self) };
        $self->_log('error', "on_connect listener failed: $@") if $@;
    }
    $self->_log('info', 'state channel ready');
    return;
}

sub _device_block {
    my ($self) = @_;
    return Plugins::yandex::Ynison::Message::device_block(
        device_id   => $self->{device}{device_id},
        title       => $self->{device}{title},
        app_name    => $self->{device}{app_name},
        app_version => $self->{device}{app_version},
        can_be_player            => $self->{can_be_player},
        can_be_remote_controller => $self->{can_be_player} ? 0 : 1,
        volume_granularity       => $self->{can_be_player} ? $C->VOLUME_GRANULARITY() : 0,
        volume      => $self->{get_volume}->(),
    );
}

sub _on_channel_closed {
    my ($self, $reason) = @_;
    return unless $self->{ready} || $self->{ws};
    $self->{ready} = 0;
    if (my $t = delete $self->{ws}) { $t->close }
    if (my $h = delete $self->{first_frame_timer}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
    }
    $self->{policy}->on_transport_failure;
    if (my $h = delete $self->{reclaim_timer}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
    }
    $self->_schedule_reconnect;
    $self->_log('error', $reason);
    return;
}

sub _on_frame {
    my ($self, $frame) = @_;
    my ($kind, $payload) = Plugins::yandex::Ynison::Message::parse_frame($frame);
    if ($kind eq 'error') {
        my $d = Plugins::yandex::Ynison::Message::error_details($payload);
        $self->{policy}->on_server_error($d->{code},
            grpc_code => $d->{grpc_code}, go_away => $d->{go_away_s}, ladder => $d->{backoff_millis});
        if ($d->{go_away_s}) {
            $self->_log('warn', "Yandex asked this device to stay away for $d->{go_away_s} s (code $d->{code}); reconnecting earlier would extend the wait");
        }
        else {
            $self->_log('warn', "Ynison error code=$d->{code} " . ($d->{message} // ''));
        }
        # An error frame is a server directive, not a transport failure: break
        # the session either way. next_delay has already consumed the go-away
        # (if any), so the retry waits the window out exactly (constraint 8),
        # and a tick that lands inside it defers through go_away_pending.
        $self->{ready} = 0;
        my $t = delete $self->{ws};
        $t->close if $t;
        if (my $h = delete $self->{first_frame_timer}) {
            $self->{scheduler}{kill}->($h) if $self->{scheduler};
        }
        if (my $h = delete $self->{reclaim_timer}) {
            $self->{scheduler}{kill}->($h) if $self->{scheduler};
        }
        $self->_schedule_reconnect;
        return;
    }
    if ($kind eq 'ping') {
        $self->_log('debug', 'JSON ping frame ignored');
        return;
    }
    return unless $kind eq 'state';

    if (my $h = delete $self->{first_frame_timer}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
    }
    $self->{saw_frame} = 1;
    $self->{last_event} = $self->{state}->apply_frame($payload);
    $self->{policy}->on_healthy;
    if ($self->{on_state}) {
        eval { $self->{on_state}->($self) };
        $self->_log('error', "on_state listener failed: $@") if $@;
    }
    return;
}

# --- outbound commands (Task 10) ------------------------------------------------

# _send($hashref, strict): JSON-encode and send; a strict send while the
# channel is down is queued and flushed after the next registration.
sub _send {
    my ($self, $msg, $strict) = @_;
    my $json = JSON::XS::VersionOneAndTwo::encode_json($msg);
    if (!$self->{ready}) {
        if ($strict) {
            push @{ $self->{strict_queue} }, $json;
            return 1;
        }
        return 0;
    }
    return $self->{ws}->send_text($json) ? 1 : 0;
}

# report_status(progress_ms, duration_ms, paused, strict => 0|1)
# 1 = sent (or queued strict), 0 = skipped by a guard, undef = strict failure.
sub report_status {
    my ($self, $progress, $duration, $paused, %o) = @_;
    $paused = $paused ? 1 : 0;
    my $strict = $o{strict} ? 1 : 0;
    $duration = ($self->state->status || {})->{duration_ms} // 0 unless $duration && $duration > 0;
    $duration = 0 + ($duration // 0);
    if ($duration <= 0) {
        return $strict ? undef : 0;                      # an unknown duration is a hard failure for strict
    }
    $progress = Plugins::yandex::Ynison::Message::clamp_progress($progress, $duration);
    # Constraint 17: an unpaused heartbeat over an empty server queue closes the
    # socket. Strict user commands are exempt (upstream: "strict user commands
    # are not gated").
    if (!$strict && !$paused && !defined $self->state->current_track_id) {
        $self->_log('warn', 'skipping an unpaused status: the server queue has no current track');
        return 0;
    }
    if (!$strict && !$self->state->is_active) {
        return 0;                                        # another device owns the session
    }
    if (!$strict && $self->state->status_matches($progress, $duration, $paused)) {
        return 0;                                        # nothing new for Ynison to learn
    }
    my $sent = $self->_send(Plugins::yandex::Ynison::Message::update_playing_status(
        progress_ms => $progress, duration_ms => $duration, paused => $paused,
        version     => Plugins::yandex::Ynison::Message::new_version($self->{device}{device_id}),
    ), $strict);
    if ($sent) {
        $self->state->note_status_sent($progress, $duration, $paused);
    }
    return $sent;
}

sub set_player_state {
    my ($self, $player_state) = @_;
    return $self->_send(Plugins::yandex::Ynison::Message::update_player_state($player_state));
}

sub set_active_device {
    my ($self, $device_id) = @_;
    return $self->_send(Plugins::yandex::Ynison::Message::update_active_device($device_id));
}

sub set_session_params {
    my ($self, $mute) = @_;
    return $self->_send(Plugins::yandex::Ynison::Message::update_session_params($mute));
}

sub set_volume {
    my ($self, $volume) = @_;
    $volume = 0 if !defined $volume || $volume < 0;
    $volume = 1 if $volume > 1;
    return $self->_send(Plugins::yandex::Ynison::Message::update_volume_info(
        $self->{device}{device_id}, $volume,
        Plugins::yandex::Ynison::Message::new_version($self->{device}{device_id})));
}

sub debug_snapshot {
    my ($self) = @_;
    return {
        ready       => $self->{ready},
        device_id   => $self->{device}{device_id},
        active      => $self->state->is_active,
        track       => $self->state->current_track_id,
        paused      => $self->state->is_paused,
        progress_ms => $self->state->progress_ms,
        strict_queue => scalar @{ $self->{strict_queue} },
        reconnecting => $self->is_reconnecting,
        last_event  => $self->{last_event},
    };
}

sub disconnect {
    my ($self) = @_;
    $self->{stopped} = 1;
    $self->{ready} = 0;
    if (my $t = delete $self->{ws}) { $t->close }
    if (my $t = delete $self->{redirect_ws}) { $t->close }
    for my $key (qw(first_frame_timer reconnect_timer reclaim_timer)) {
        if (my $h = delete $self->{$key}) {
            $self->{scheduler}{kill}->($h) if $self->{scheduler};
        }
    }
    return;
}

# --- reconnect machinery (Task 9) --------------------------------------------

sub is_reconnecting {
    my ($self) = @_;
    return defined $self->{reconnect_timer} ? 1 : 0;
}

# Idempotent: one retry in flight at any time; nothing after disconnect().
sub _schedule_reconnect {
    my ($self) = @_;
    return if $self->{stopped};
    return if defined $self->{reconnect_timer};
    my $delay = $self->{policy}->next_delay;
    $self->_log('info', sprintf('reconnecting in %.0f s', $delay));
    $self->{reconnect_timer} = $self->{scheduler}{set}->($delay, sub { $self->_reconnect_tick });
    return;
}

sub _reconnect_tick {
    my ($self) = @_;
    $self->{reconnect_timer} = undef;
    return if $self->{stopped};
    if ($self->{policy}->go_away_pending) {
        # A go-away arrived while we were waiting: dialing now would land inside its window.
        $self->_schedule_reconnect;
        return;
    }
    if (!$self->{auth_refreshed} && $self->{on_auth_failure}) {
        # A single refresh attempt per client run, upstream-style; an expired
        # token is possible on the very first connect, too. Any outcome latches,
        # a dying callback included: it is never consulted twice.
        $self->{auth_refreshed} = 1;
        eval {
            my ($token, $outcome) = $self->{on_auth_failure}->();
            if (defined $token && $outcome eq 'refreshed') {
                $self->{token} = $token;
                $self->_log('info', 'token refreshed');
            }
        };
        $self->_log('error', "on_auth_failure callback failed: $@") if $@;
    }
    $self->connect;
    return;
}

1;
