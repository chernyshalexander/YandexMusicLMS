package Plugins::yandex::Ynison;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison - Yandex Music Ynison multi-device playback sync

=head1 DESCRIPTION

MVP Implementation: Cast incoming tracks, pause/play/next/prev commands.

Connection flow:
  1. Connect to redirector.YnisonRedirectService
  2. Get host ticket, redirect to real Ynison host
  3. Connect to ynison_state.YnisonStateService
  4. Send UpdateFullState (device registration)
  5. Receive state updates continuously
  6. Send commands (pause/play/next/prev)
  7. Keep-alive ping every 20s

=cut

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::Async;
use Time::HiRes qw(time);
use UUID::Tiny qw(create_uuid_as_string);

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

use constant {
    STATE_DISCONNECTED   => 0,
    STATE_REDIRECTOR     => 1,
    STATE_CONNECTING     => 2,
    STATE_ACTIVE         => 3,
    KEEPALIVE_INTERVAL   => 20,     # seconds (ping interval)
    RECONNECT_MIN        => 5,      # seconds
    RECONNECT_MAX        => 60,     # seconds
};

# ===========================================================================
# Constructor
# ===========================================================================
sub new {
    my ($class, $client, $token, $user_id) = @_;
    return unless $client && $token && $user_id;

    my $self = bless {
        # User & Auth
        client    => $client,
        id        => $client->id(),
        token     => $token,
        user_id   => $user_id,
        device_id => undef,

        # Connection state
        socket          => undef,
        read_buffer     => '',
        write_queue     => [],
        state           => STATE_DISCONNECTED,
        redirect_data   => undef,   # {host, redirect_ticket, session_id}

        # Timing
        reconnect_delay => RECONNECT_MIN,
        keepalive_time  => 0,

        # Listeners / callbacks
        listeners => [],

        # Last known state
        last_state => undef,
    }, $class;

    # Load or generate device_id
    my $pref_key = 'ynison_device_id_' . $self->{id};
    $self->{device_id} = $prefs->get($pref_key);
    unless ($self->{device_id}) {
        $self->{device_id} = _generate_device_id();
        $prefs->set($pref_key, $self->{device_id});
    }

    $log->info(sprintf('Ynison [%s]: Initialized, device_id=%s',
        $client->name(), $self->{device_id}));

    return $self;
}

# ===========================================================================
# Public API
# ===========================================================================

sub enabled {
    my ($self) = @_;
    return $self->{state} == STATE_ACTIVE;
}

sub latest_state {
    my ($self) = @_;
    return $self->{last_state};
}

sub build_pause_cmd {
    my ($self, $paused) = @_;
    my $state = $self->latest_state();
    return unless $state;
    return build_pause_request($self->{device_id}, $state->{player_state}{status}, $paused);
}

sub build_next_cmd {
    my ($self) = @_;
    my $state = $self->latest_state();
    return unless $state;
    return build_next_track_request($self->{device_id}, $state->{player_state});
}

sub build_prev_cmd {
    my ($self) = @_;
    my $state = $self->latest_state();
    return unless $state;
    return build_prev_track_request($self->{device_id}, $state->{player_state});
}

sub connect {
    my ($self) = @_;
    $self->{state} = STATE_REDIRECTOR;
    $self->_connect_redirector();
}

sub disconnect {
    my ($self) = @_;
    $self->{state} = STATE_DISCONNECTED;
    if ($self->{socket}) {
        $self->{socket}->close();
        $self->{socket} = undef;
    }
    # Cancel any pending timers
    Slim::Utils::Timers::killTimers($self, 'keepalive');
    Slim::Utils::Timers::killTimers($self, 'reconnect');
}

sub on_state {
    my ($self, $callback) = @_;
    push @{$self->{listeners}}, $callback;
}

sub send_command {
    my ($self, $request_hash) = @_;
    return unless $self->{state} == STATE_ACTIVE;
    return unless $self->{socket};

    my $json = JSON::XS::VersionOneAndTwo::encode_json($request_hash);
    $self->_send_frame($json);
}

# ===========================================================================
# Connection: Phase 1 - Redirector
# ===========================================================================

sub _connect_redirector {
    my ($self) = @_;

    $log->info(sprintf('Ynison [%s]: Connecting to redirector...', $self->{client}->name()));

    my $async = Plugins::yandex::Ynison::Async->new({
        host     => 'ynison.music.yandex.ru',
        port     => 443,
        https    => 1,
        onError  => sub { $self->_on_error('redirector', @_) },
        onRead   => sub { $self->_on_redirector_data(@_) },
    });

    unless ($async) {
        $log->error('Failed to create async connection');
        $self->_schedule_reconnect();
        return;
    }

    # Build WebSocket headers
    my $headers = $self->_build_headers();
    my $subprotocols = $self->_build_subprotocols();

    # WebSocket upgrade request to redirector
    my $path = '/redirector.YnisonRedirectService/GetRedirectToYnison';
    my $request = "GET $path HTTP/1.1\r\n";
    $request .= "Host: ynison.music.yandex.ru\r\n";
    $request .= "Connection: Upgrade\r\n";
    $request .= "Upgrade: websocket\r\n";
    $request .= "Sec-WebSocket-Key: " . _base64(pack('C*', map { int(rand(256)) } 1..16)) . "\r\n";
    $request .= "Sec-WebSocket-Version: 13\r\n";
    $request .= "Sec-WebSocket-Protocol: " . join(', ', @$subprotocols) . "\r\n";
    $request .= $headers;
    $request .= "\r\n";

    $self->{socket} = $async;
    $async->write($request);
}

sub _on_redirector_data {
    my ($self, $async, $data) = @_;

    $self->{read_buffer} .= $$data;

    # Simple WebSocket frame parsing
    if ($self->{read_buffer} =~ /\r\n\r\n/s) {
        # Got headers, look for WebSocket frame
        my @lines = split /\r\n/, $self->{read_buffer};

        # Check if it's an HTTP upgrade response
        if ($lines[0] =~ /101 Switching Protocols/i) {
            $log->info('Ynison: Got WebSocket upgrade from redirector');

            # Extract the frame data (after headers)
            my $frame_start = index($self->{read_buffer}, "\r\n\r\n") + 4;
            my $frame_data = substr($self->{read_buffer}, $frame_start);

            if ($frame_data) {
                $self->_parse_redirector_frame($frame_data);
            }

            $self->{read_buffer} = '';
            $self->{state} = STATE_CONNECTING;
            $self->_connect_state_service();
        }
    }
}

sub _parse_redirector_frame {
    my ($self, $frame_data) = @_;

    # Decode WebSocket frame (simplified)
    my $text = _decode_ws_frame($frame_data);
    return unless $text;

    my $json = JSON::XS::VersionOneAndTwo::decode_json($text);

    $self->{redirect_data} = {
        host              => $json->{host},
        redirect_ticket   => $json->{redirect_ticket},
        session_id        => $json->{session_id},
    };

    $log->info(sprintf('Ynison [%s]: Got redirect: host=%s',
        $self->{client}->name(), $self->{redirect_data}{host}));
}

# ===========================================================================
# Connection: Phase 2 - State Service
# ===========================================================================

sub _connect_state_service {
    my ($self) = @_;

    return unless $self->{redirect_data};

    my $host = $self->{redirect_data}{host};
    $log->info(sprintf('Ynison [%s]: Connecting to state service at %s...',
        $self->{client}->name(), $host));

    my $async = Plugins::yandex::Ynison::Async->new({
        host     => $host,
        port     => 443,
        https    => 1,
        onError  => sub { $self->_on_error('state', @_) },
        onRead   => sub { $self->_on_state_data(@_) },
    });

    unless ($async) {
        $log->error('Failed to connect to state service');
        $self->_schedule_reconnect();
        return;
    }

    # WebSocket upgrade request
    my $headers = $self->_build_headers();
    my $subprotocols = $self->_build_subprotocols();

    my $path = '/ynison_state.YnisonStateService/PutYnisonState';
    my $request = "GET $path HTTP/1.1\r\n";
    $request .= "Host: $host\r\n";
    $request .= "Connection: Upgrade\r\n";
    $request .= "Upgrade: websocket\r\n";
    $request .= "Sec-WebSocket-Key: " . _base64(pack('C*', map { int(rand(256)) } 1..16)) . "\r\n";
    $request .= "Sec-WebSocket-Version: 13\r\n";
    $request .= "Sec-WebSocket-Protocol: " . join(', ', @$subprotocols) . "\r\n";
    $request .= $headers;
    $request .= "\r\n";

    $self->{socket} = $async;
    $async->write($request);
}

sub _on_state_data {
    my ($self, $async, $data) = @_;

    $self->{read_buffer} .= $$data;

    # Check for WebSocket upgrade response
    if ($self->{state} == STATE_CONNECTING && $self->{read_buffer} =~ /\r\n\r\n/s) {
        my @lines = split /\r\n/, $self->{read_buffer};

        if ($lines[0] =~ /101 Switching Protocols/i) {
            $log->info('Ynison: WebSocket connected to state service');
            $self->{state} = STATE_ACTIVE;
            $self->{read_buffer} = '';

            # Send registration message
            $self->_send_register_device();

            # Start keep-alive
            $self->_schedule_keepalive();
        }
    }
    elsif ($self->{state} == STATE_ACTIVE) {
        # Parse incoming frames
        $self->_process_state_frames();
    }
}

# ===========================================================================
# Registration & Commands
# ===========================================================================

sub _send_register_device {
    my ($self) = @_;

    my $msg = {
        rid                         => _generate_request_id(),
        player_action_timestamp_ms  => _get_timestamp(),
        activity_interception_type  => 'DO_NOT_INTERCEPT_BY_DEFAULT',
        update_full_state => {
            device => {
                capabilities => {
                    can_be_player            => JSON::XS::VersionOneAndTwo::true,
                    can_be_remote_controller => JSON::XS::VersionOneAndTwo::false,
                    volume_granularity       => 16,
                },
                info => {
                    device_id => $self->{device_id},
                    type      => 'OTHER',
                    title     => $self->{client}->name(),
                    app_name  => 'Yandex Music LMS Plugin',
                },
                volume_info => {
                    volume => 0.5,
                },
            },
            player_state => {
                player_queue => {
                    current_playable_index => -1,
                    playable_list          => [],
                    options => {
                        repeat_mode => 'NONE',
                    },
                    entity_id   => '',
                    entity_type => 'VARIOUS',
                    entity_context => 'BASED_ON_ENTITY_BY_DEFAULT',
                    from_optional => '',
                    version => {
                        device_id => $self->{device_id},
                    },
                },
                status => {
                    paused          => JSON::XS::VersionOneAndTwo::true,
                    progress_ms     => 0,
                    duration_ms     => 0,
                    playback_speed  => 1,
                    version => {
                        device_id => $self->{device_id},
                        timestamp_ms => 0,
                    },
                },
            },
            is_currently_active => JSON::XS::VersionOneAndTwo::false,
        },
    };

    $self->send_command($msg);
}

# ===========================================================================
# State Processing
# ===========================================================================

sub _process_state_frames {
    my ($self) = @_;

    # Parse WebSocket frames from read_buffer
    while (length($self->{read_buffer}) >= 2) {
        my ($frame_data, $remaining) = _extract_ws_frame($self->{read_buffer});
        last unless $frame_data;

        $self->{read_buffer} = $remaining;

        my $text = _decode_ws_frame($frame_data);
        next unless $text;

        # Parse JSON state
        my $state = JSON::XS::VersionOneAndTwo::decode_json($text);
        $self->_handle_state_update($state);
    }
}

sub _handle_state_update {
    my ($self, $state) = @_;

    # Skip pings
    if ($state->{ping}) {
        $self->_send_pong();
        return;
    }

    # Echo detection: skip if this is our own update
    if (my $queue = $state->{player_state}{player_queue} // $state->{update_player_state}{player_state}{player_queue}) {
        if (my $version = $queue->{version}) {
            if ($version->{device_id} && $version->{device_id} eq $self->{device_id}) {
                $log->debug('Ynison: Skipping echo from own device');
                return;
            }
        }
    }

    # Cache latest state
    $self->{last_state} = $state;

    # Call registered listeners
    foreach my $listener (@{$self->{listeners}}) {
        eval {
            $listener->($state);
        };
        if ($@) {
            $log->error("Ynison listener error: $@");
        }
    }
}

# ===========================================================================
# Keep-Alive & Reconnection
# ===========================================================================

sub _schedule_keepalive {
    my ($self) = @_;
    Slim::Utils::Timers::setTimer($self, \&_send_ping, KEEPALIVE_INTERVAL, 'keepalive');
}

sub _send_ping {
    my ($self) = @_;
    return unless $self->{state} == STATE_ACTIVE;

    $self->_send_frame(_encode_ws_ping());
    $self->_schedule_keepalive();
}

sub _send_pong {
    my ($self) = @_;
    return unless $self->{socket};
    $self->_send_frame(_encode_ws_pong());
}

sub _schedule_reconnect {
    my ($self) = @_;

    if ($self->{reconnect_delay} < RECONNECT_MAX) {
        $self->{reconnect_delay} *= 2;
    }

    $log->warn(sprintf('Ynison [%s]: Reconnecting in %d seconds...',
        $self->{client}->name(), $self->{reconnect_delay}));

    Slim::Utils::Timers::setTimer($self, \&connect, $self->{reconnect_delay}, 'reconnect');
}

# ===========================================================================
# Error Handling
# ===========================================================================

sub _on_error {
    my ($self, $phase, $async, $error) = @_;

    $log->warn(sprintf('Ynison [%s]: Error during %s: %s',
        $self->{client}->name(), $phase, $error));

    $self->{state} = STATE_DISCONNECTED;
    if ($self->{socket}) {
        $self->{socket}->close();
        $self->{socket} = undef;
    }

    $self->_schedule_reconnect();
}

# ===========================================================================
# Low-level I/O
# ===========================================================================

sub _send_frame {
    my ($self, $data) = @_;
    return unless $self->{socket};
    $self->{socket}->write($data);
}

# ===========================================================================
# Helper Functions
# ===========================================================================

sub _build_headers {
    my ($self) = @_;
    return "Authorization: OAuth " . $self->{token} . "\r\n"
         . "Origin: https://music.yandex.ru\r\n";
}

sub _build_subprotocols {
    my ($self) = @_;

    my $device_info = {
        app_name => 'Yandex Music LMS Plugin',
        type     => '1',
    };

    return [
        'Bearer',
        'v2',
        JSON::XS::VersionOneAndTwo::encode_json($device_info),
    ];
}

sub _generate_device_id {
    return sprintf('%08x%08x', int(rand(0xffffffff)), int(rand(0xffffffff)));
}

sub _generate_request_id {
    return lc(create_uuid_as_string());
}

sub _get_timestamp {
    return int(time() * 1000);
}

sub _base64 {
    my ($data) = @_;
    require MIME::Base64;
    return MIME::Base64::encode_base64($data, '');
}

# ===========================================================================
# Message Builders (Command Factory)
# ===========================================================================

=head2 build_pause_request($device_id, $current_status, $paused)

Build UpdatePlayingStatus request to pause or resume playback.

Clones current PlayingStatus, changes only paused flag and version.
Preserves progress_ms, duration_ms, playback_speed from server state.

Args:
  $device_id - This device's ID
  $current_status - Current PlayingStatus from latest server state
  $paused - 1 to pause, 0 to play

Returns:
  Hash suitable for send_command()

=cut

sub build_pause_request {
    my ($device_id, $current_status, $paused) = @_;

    return {
        rid                         => _generate_request_id(),
        player_action_timestamp_ms  => _get_timestamp(),
        activity_interception_type  => 'DO_NOT_INTERCEPT_BY_DEFAULT',
        update_playing_status => {
            playing_status => {
                progress_ms    => $current_status->{progress_ms} // 0,
                duration_ms    => $current_status->{duration_ms} // 0,
                paused         => $paused ? JSON::XS::VersionOneAndTwo::true
                                          : JSON::XS::VersionOneAndTwo::false,
                playback_speed => $current_status->{playback_speed} // 1.0,
                version => {
                    device_id    => $device_id,
                    version      => int(rand(10**18)),
                    timestamp_ms => _get_timestamp(),
                },
            },
        },
    };
}

=head2 build_change_track_request($device_id, $current_state, $delta)

Build UpdatePlayerState request to change track index by delta.

Clones current PlayerQueue, changes only current_playable_index and version.
Resets playback progress but preserves paused flag.

Args:
  $device_id - This device's ID
  $current_state - Current PlayerState from server
  $delta - Index offset: 1 for next, -1 for prev

Returns:
  Hash suitable for send_command()

=cut

sub build_change_track_request {
    my ($device_id, $current_state, $delta) = @_;

    my $queue = $current_state->{player_queue} // {};
    my $status = $current_state->{status} // {};

    my $current_idx = $queue->{current_playable_index} // -1;
    my $playable_count = scalar(@{$queue->{playable_list} // []});

    # Calculate new index, clamped to valid range
    my $new_idx;
    if ($playable_count > 0) {
        $new_idx = $current_idx + $delta;
        $new_idx = 0 if $new_idx < 0;
        $new_idx = $playable_count - 1 if $new_idx >= $playable_count;
    } else {
        $new_idx = -1;
    }

    return {
        rid                         => _generate_request_id(),
        player_action_timestamp_ms  => _get_timestamp(),
        activity_interception_type  => 'DO_NOT_INTERCEPT_BY_DEFAULT',
        update_player_state => {
            player_state => {
                player_queue => {
                    current_playable_index => $new_idx,
                    playable_list          => $queue->{playable_list} // [],
                    options => {
                        repeat_mode => $queue->{options}{repeat_mode} // 'NONE',
                    },
                    entity_id      => $queue->{entity_id} // '',
                    entity_type    => $queue->{entity_type} // 'VARIOUS',
                    entity_context => $queue->{entity_context} // 'BASED_ON_ENTITY_BY_DEFAULT',
                    from_optional  => $queue->{from_optional} // '',
                    version => {
                        device_id    => $device_id,
                        version      => int(rand(10**18)),
                        timestamp_ms => _get_timestamp(),
                    },
                },
                status => {
                    progress_ms    => 0,
                    duration_ms    => 0,
                    paused         => $status->{paused} // JSON::XS::VersionOneAndTwo::true,
                    playback_speed => $status->{playback_speed} // 1.0,
                    version => {
                        device_id    => $device_id,
                        version      => int(rand(10**18)),
                        timestamp_ms => _get_timestamp(),
                    },
                },
            },
        },
    };
}

=head2 build_next_track_request($device_id, $current_state)

Build request to skip to next track.

Args:
  $device_id - This device's ID
  $current_state - Current PlayerState from server

Returns:
  Hash suitable for send_command()

=cut

sub build_next_track_request {
    my ($device_id, $current_state) = @_;
    return build_change_track_request($device_id, $current_state, 1);
}

=head2 build_prev_track_request($device_id, $current_state)

Build request to skip to previous track.

Args:
  $device_id - This device's ID
  $current_state - Current PlayerState from server

Returns:
  Hash suitable for send_command()

=cut

sub build_prev_track_request {
    my ($device_id, $current_state) = @_;
    return build_change_track_request($device_id, $current_state, -1);
}

# WebSocket frame helpers (simplified)
sub _encode_ws_ping {
    # 0x89 = FIN + PING opcode
    return pack('CC', 0x89, 0);
}

sub _encode_ws_pong {
    # 0x8a = FIN + PONG opcode
    return pack('CC', 0x8a, 0);
}

sub _extract_ws_frame {
    my ($buffer) = @_;
    # Simplified: expects unmasked frames (server→client)
    return unless length($buffer) >= 2;

    my $byte1 = unpack('C', substr($buffer, 0, 1));
    my $byte2 = unpack('C', substr($buffer, 1, 1));

    my $opcode = $byte1 & 0x0f;
    my $payload_len = $byte2 & 0x7f;

    # TODO: Handle extended payload length (127, 126)
    # For MVP, assume short payloads

    my $frame_size = 2 + $payload_len;
    return unless length($buffer) >= $frame_size;

    my $frame = substr($buffer, 0, $frame_size);
    my $remaining = substr($buffer, $frame_size);

    return ($frame, $remaining);
}

sub _decode_ws_frame {
    my ($frame) = @_;
    # Simplified: extract text payload (opcode 1)
    return unless length($frame) >= 2;

    my $byte1 = unpack('C', substr($frame, 0, 1));
    my $opcode = $byte1 & 0x0f;

    # Skip non-text frames
    return if $opcode != 1;  # 1 = text frame

    my $byte2 = unpack('C', substr($frame, 1, 1));
    my $payload_len = $byte2 & 0x7f;

    return substr($frame, 2, $payload_len);
}

# ===========================================================================
# Inner Class: SSL-capable async socket
# ===========================================================================
{
    package Plugins::yandex::Ynison::Async;
    use base qw(Slim::Networking::Async);

    sub new_socket {
        my ($self, %args) = @_;
        if ($args{https}) {
            $args{SSL_hostname} //= $args{Host};
            require Slim::Networking::Async::Socket::HTTPS;
            return Slim::Networking::Async::Socket::HTTPS->new(%args);
        }
        return $self->SUPER::new_socket(%args);
    }
}

1;
