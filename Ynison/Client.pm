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
is waited out exactly here (constraint 8); the rest of the reconnect
machinery (Task 9) and the outbound commands (Task 10) build on this module.

=cut

# The protocol orchestrator: redirector → state service, registration after
# every connection, heartbeat from the redirector's keep-alive params, inbound
# frame handling through Ynison::State and the reconnect policy. Everything
# external is injected: the transport (or its factory), the scheduler
# ({set => cb, kill => cb}) and the clock. Reconnects (Task 9) and outbound
# commands (Task 10) build on this module.

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
        on_reclaim  => $o{on_reclaim},          # wired in Task 9
        on_event    => $o{on_event} // sub { },
        factory     => $o{transport_factory},
        scheduler   => $o{scheduler},
        clock       => $clock,
        logger      => $o{logger} // sub { },
        state       => Plugins::yandex::Ynison::State->new(device_id => $device->{device_id}, now_s => $clock),
        policy      => Plugins::yandex::Ynison::ReconnectPolicy->new,
        ws          => undef,
        redirect_ws => undef,
        ready       => 0,
        ever_connected => 0,
        settle_until => 0,
        last_event  => undef,
        first_frame_timer => undef,
        reconnect_timer => undef,               # the go-away wait; Task 9 generalizes it
        interval_s  => undef,
        stopped     => 0,
    }, $class;
    return $self;
}

sub _log { my ($self, $level, $msg) = @_; $self->{on_event}->($level, $msg) if $level ne 'debug'; return }

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
    return if $self->{stopped};
    my $t = $self->_factory_transport;
    $self->{redirect_ws} = $t;                          # tests pump this hop too
    $t->fetch_redirect($self->{redirect_host}, $C->YNISON_REDIRECT_PATH(), $self->_headers, sub {
        my (undef, $data, $status) = @_;
        return if $self->{stopped};
        if (!defined $data) {
            $self->{policy}->on_transport_failure;
            $self->_log('error', "redirector failed" . (defined $status ? " (HTTP $status)" : ''));
            return;                                  # Task 9 schedules the retry
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
    $self->{ready} = 1;
    $self->{settle_until} = $self->{ever_connected} ? $self->{clock}->() + $C->SETTLE_WINDOW() : 0;
    $self->{ever_connected} = 1;
    $t->send_text(JSON::XS::VersionOneAndTwo::encode_json(
        Plugins::yandex::Ynison::Message::update_full_state(
            device => $self->_device_block,
            player_state => Plugins::yandex::Ynison::Message::empty_player_state($self->{device}{device_id}),
        )));
    $t->send_text(JSON::XS::VersionOneAndTwo::encode_json(Plugins::yandex::Ynison::Message::update_session_params($self->{mute_if_passive})));
    # First-frame watchdog: a silent state channel must not hang forever.
    if (my $s = $self->{scheduler}) {
        $self->{first_frame_timer} = $s->{set}->($C->FIRST_FRAME_TIMEOUT(), sub {
            return unless $self->{ready} && !$self->{last_event};
            $self->_on_channel_closed('no state frame after connect');
        });
    }
    $self->{on_connect}->($self) if $self->{on_connect};
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
            # The go-away window is waited out exactly (constraint 8): the
            # redirector is dialed only after it. Task 9 folds this into the
            # general reconnect machinery (ladder, reclaim, token refresh).
            if (my $h = delete $self->{first_frame_timer}) {
                $self->{scheduler}{kill}->($h) if $self->{scheduler};
            }
            if (!$self->{stopped} && $self->{scheduler} && !defined $self->{reconnect_timer}) {
                my $delay = $self->{policy}->next_delay;    # consumes the go-away
                $self->{reconnect_timer} = $self->{scheduler}{set}->($delay, sub {
                    $self->{reconnect_timer} = undef;
                    return if $self->{stopped};
                    $self->connect;
                });
            }
        }
        else {
            $self->_log('warn', "Ynison error code=$d->{code} " . ($d->{message} // ''));
        }
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
    $self->{last_event} = $self->{state}->apply_frame($payload);
    $self->{policy}->on_healthy;
    $self->{on_state}->($self) if $self->{on_state};
    return;
}

sub disconnect {
    my ($self) = @_;
    $self->{stopped} = 1;
    $self->{ready} = 0;
    if (my $t = delete $self->{ws}) { $t->close }
    if (my $t = delete $self->{redirect_ws}) { $t->close }
    for my $key (qw(first_frame_timer reconnect_timer)) {
        if (my $h = delete $self->{$key}) {
            $self->{scheduler}{kill}->($h) if $self->{scheduler};
        }
    }
    return;
}

1;
