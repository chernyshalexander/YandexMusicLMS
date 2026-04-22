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
use MIME::Base64;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::Async;
use Slim::Networking::IO::Select;
use Time::HiRes qw(time);
use Errno qw(EAGAIN EWOULDBLOCK);

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

use constant {
    STATE_DISCONNECTED   => 0,
    STATE_REDIRECTOR     => 1,
    STATE_STATE_SERVICE  => 2,
    STATE_ACTIVE         => 3,
    STATE_RECONNECT_WAIT => 4,
    RECONNECT_MIN        => 5,      # seconds
    RECONNECT_MAX        => 60,     # seconds
    KEEPALIVE_INTERVAL   => 20,     # seconds
};

# Inner class: Slim::Networking::Async with HTTPS support
{
    package Plugins::yandex::Ynison::Async;
    use base qw(Slim::Networking::Async);

    sub new_socket {
        my ($self, %args) = @_;
        # Use parent logger via Slim::Utils::Log
        my $alog = Slim::Utils::Log::logger('plugin.yandex');
        $alog->info(sprintf('Ynison::Async::new_socket() called, https=%s, Host=%s',
            $args{https} // 'undef', $args{Host} // 'undef'));

        if ($args{https}) {
            $args{SSL_hostname} //= $args{Host};
            $alog->info('Ynison::Async::new_socket: Creating HTTPS socket');
            require Slim::Networking::Async::Socket::HTTPS;
            my $socket = Slim::Networking::Async::Socket::HTTPS->new(%args);
            $alog->info(sprintf('Ynison::Async::new_socket: HTTPS socket created, ref=%s',
                ref($socket) // 'undef'));
            return $socket;
        }
        $alog->info('Ynison::Async::new_socket: Creating HTTP socket via parent');
        return $self->SUPER::new_socket(%args);
    }
}

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
        reconnect_delay => RECONNECT_MIN(),
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
    return $self->{state} == STATE_ACTIVE();
}

sub device_id {
    my ($self) = @_;
    return $self->{device_id};
}

sub latest_state {
    my ($self) = @_;
    return $self->{last_state};
}

sub cache_yandex_state {
    my ($self, $player_state) = @_;
    $self->{yandex_queue} = $player_state->{player_queue} if $player_state->{player_queue};
}

sub update_state {
    my ($self) = @_;
    my $client = $self->{client};
    return unless $self->{state} == STATE_ACTIVE();
    return if $self->{syncing_from_yandex};
    return unless $client->isPlaying() || $client->isPaused();

    my $state = eval { $self->_build_player_state() };
    if ($@) {
        $log->error(sprintf('Ynison [%s]: Failed to build player state: %s', $client->name(), $@));
        return;
    }
    return unless @{$state->{player_queue}{playable_list} // []};

    my $ts = int(time() * 1000);
    $self->send_command({
        update_player_state        => {player_state => $state},
        rid                        => _generate_request_id(),
        player_action_timestamp_ms => "$ts",
        activity_interception_type => 'DO_NOT_INTERCEPT_BY_DEFAULT',
    });
}

sub _build_player_state {
    my ($self) = @_;
    my $client = $self->{client};
    my $song   = $client->playingSong();

    my $ts_ns   = int(time() * 1_000_000_000);
    my $version = {
        device_id    => $self->{device_id},
        version      => "$ts_ns",
        timestamp_ms => '0',
    };

    my $paused  = ($client->isPaused() || !$client->isPlaying()) ? \1 : \0;
    my $dur_ms  = $song ? int(($song->duration() || 0) * 1000) : 0;
    my $prog_ms = 0;
    eval { $prog_ms = int((Slim::Player::Source::songTime($client) || 0) * 1000) };

    my $status = {
        duration_ms    => "$dur_ms",
        paused         => $paused,
        playback_speed => 1.0,
        progress_ms    => "$prog_ms",
        version        => $version,
    };

    my $player_queue;
    if ($self->{yandex_queue} && @{$self->{yandex_queue}{playable_list} // []}) {
        $player_queue = {%{$self->{yandex_queue}}};
        $player_queue->{version} = $version;
        if ($song && $song->track()) {
            my ($tid) = $song->track()->url() =~ /yandexmusic:\/\/(\d+)/;
            if ($tid) {
                my $list = $self->{yandex_queue}{playable_list};
                for my $i (0..$#$list) {
                    if (($list->[$i]{playable_id} // '') eq $tid) {
                        $player_queue->{current_playable_index} = $i;
                        last;
                    }
                }
            }
        }
    } else {
        my $tid = '';
        if ($song && $song->track()) {
            ($tid) = $song->track()->url() =~ /yandexmusic:\/\/(\d+)/;
        }
        $player_queue = {
            current_playable_index => $tid ? 0 : -1,
            entity_id              => '',
            entity_type            => 'VARIOUS',
            playable_list          => $tid ? [{
                playable_id   => $tid,
                playable_type => 'TRACK',
                from          => 'direct',
            }] : [],
            options        => {repeat_mode => 'NONE'},
            entity_context => 'BASED_ON_ENTITY_BY_DEFAULT',
            from_optional  => '',
            version        => $version,
        };
    }

    return {status => $status, player_queue => $player_queue};
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
    $self->_disconnect_socket();
    $self->{async} = undef;  # Clean up async reference
    # Cancel any pending timers
    Slim::Utils::Timers::killTimers($self, 'keepalive');
    Slim::Utils::Timers::killTimers($self, 'reconnect');
}

sub _disconnect_socket {
    my $self = shift;
    if ($self->{socket}) {
        Slim::Networking::IO::Select::removeRead($self->{socket});
        Slim::Networking::IO::Select::removeWrite($self->{socket});
        eval { $self->{socket}->close() };
        $self->{socket} = undef;
    }
}

sub on_state {
    my ($self, $callback) = @_;
    push @{$self->{listeners}}, $callback;
}

sub send_command {
    my ($self, $request_hash) = @_;
    unless ($self->{state} == STATE_ACTIVE()) {
        $log->warn(sprintf('Ynison [%s]: send_command() called but state=%d (not STATE_ACTIVE=%d)',
            $self->{client}->name(), $self->{state}, STATE_ACTIVE()));
        return;
    }
    unless ($self->{socket}) {
        $log->warn(sprintf('Ynison [%s]: send_command() called but no socket',
            $self->{client}->name()));
        return;
    }

    my $json = JSON::XS::VersionOneAndTwo::encode_json($request_hash);
    my $frame = _encode_ws_text_frame($json);
    return unless $frame;
    $log->debug(sprintf('Ynison [%s]: Sending frame (%d bytes)', $self->{client}->name(), length($frame)));
    $self->_queue_frame($frame);
}

# ===========================================================================
# Connection: Phase 1 - Redirector
# ===========================================================================

sub _connect_redirector {
    my ($self) = @_;

    $self->{state} = STATE_REDIRECTOR;
    $log->info(sprintf('Ynison [%s]: Connecting to redirector...', $self->{client}->name()));

    $self->_open_ws('ynison.music.yandex.ru', '/redirector.YnisonRedirectService/GetRedirectToYnison');
}

sub _open_ws {
    my ($self, $host, $path, $extra) = @_;

    $log->info(sprintf('Ynison [%s]: _open_ws() starting for %s',
        $self->{client}->name(), $host));

    # Build Sec-WebSocket-Protocol JSON blob (as per old module)
    my $dev_info_raw = '{"app_name":"Chrome","type":1}';
    (my $dev_info_esc = $dev_info_raw) =~ s/"/\\"/g;

    my $proto = sprintf('{"Ynison-Device-Info":"%s","Ynison-Device-Id":"%s"',
        $dev_info_esc, $self->{device_id});
    $proto .= sprintf(',"Ynison-Redirect-Ticket":"%s"', $extra->{'Ynison-Redirect-Ticket'})
        if $extra && $extra->{'Ynison-Redirect-Ticket'};
    $proto .= sprintf(',"Ynison-Session-Id":"%s"', $extra->{'Ynison-Session-Id'})
        if $extra && $extra->{'Ynison-Session-Id'};
    $proto .= sprintf(',"authorization":"OAuth %s"', $self->{token});
    $proto .= sprintf(',"X-Yandex-Music-Multi-Auth-User-Id":"%s"', $self->{user_id});
    $proto .= '}';

    # Generate WebSocket key
    my @hex = (0..9, 'a'..'f');
    my $ws_key = encode_base64(pack('H*', join('', map { $hex[rand @hex] } 1..32)), '');
    $ws_key =~ s/\s+//g;

    # Create Async handler and KEEP REFERENCE to prevent GC
    my $async = Plugins::yandex::Ynison::Async->new();
    $self->{async} = $async;  # Save reference!

    $log->info(sprintf('Ynison [%s]: Creating async socket to %s', $self->{client}->name(), $host));

    eval {
        $async->open({
        Host      => $host,
        PeerPort  => 443,
        https     => 1,
        onConnect => sub {
            $log->info(sprintf('Ynison [%s]: Connected to %s, sending WebSocket upgrade',
                $self->{client}->name(), $host));

            # Get socket from async object (callbacks receive passthrough, not socket!)
            my $fh = $async->socket();
            unless ($fh) {
                $log->error(sprintf('Ynison [%s]: async->socket() returned undef!',
                    $self->{client}->name()));
                $self->_schedule_reconnect();
                return;
            }

            $log->info(sprintf('Ynison [%s]: Socket obtained, type=%s',
                $self->{client}->name(), ref($fh)));

            $self->{socket} = $fh;
            $self->{read_buffer} = '';
            $self->{write_queue} = [];

            my $req =
                "GET $path HTTP/1.1\r\n"
                . "Host: $host\r\n"
                . "Upgrade: websocket\r\n"
                . "Connection: Upgrade\r\n"
                . "Sec-WebSocket-Key: $ws_key\r\n"
                . "Sec-WebSocket-Version: 13\r\n"
                . "Sec-WebSocket-Protocol: Bearer, v2, $proto\r\n"
                . "Authorization: OAuth $self->{token}\r\n"
                . "Origin: https://music.yandex.ru\r\n"
                . "\r\n";

            $log->info(sprintf('Ynison [%s]: Setting up read/write handlers via IO::Select',
                $self->{client}->name()));

            $fh->blocking(0);
            $self->{write_queue} = [$req];

            Slim::Networking::IO::Select::addWrite($fh, sub { $self->_on_writable(@_) });
            Slim::Networking::IO::Select::addRead($fh,  sub { $self->_on_http_response(@_) });
        },
        onError => sub {
            my ($async_obj, $error) = @_;
            $log->error(sprintf('Ynison [%s]: Connection error to %s: %s',
                $self->{client}->name(), $host, $error));
            $self->_schedule_reconnect();
        },
        });
    };
    if ($@) {
        $log->error(sprintf('Ynison [%s]: Exception during open(): %s',
            $self->{client}->name(), $@));
        $self->_schedule_reconnect();
    } else {
        $log->info(sprintf('Ynison [%s]: async->open() called successfully',
            $self->{client}->name()));
    }
}

sub _on_writable {
    my ($self, $fh) = @_;

    return unless $self->{write_queue} && @{$self->{write_queue}};

    my $data = $self->{write_queue}[0];
    my $written = syswrite($fh, $data);

    if (!defined $written) {
        return if $! == EAGAIN || $! == EWOULDBLOCK;
        $log->error('Ynison: Write error: ' . $!);
        $self->_schedule_reconnect();
        return;
    }

    if ($written == length($data)) {
        shift @{$self->{write_queue}};
        $log->debug('Ynison: Request sent');
        Slim::Networking::IO::Select::removeWrite($fh);
    } else {
        $self->{write_queue}[0] = substr($data, $written);
    }
}

sub _on_http_response {
    my ($self, $fh) = @_;
    my $bytes = $fh->sysread(my $buf, 4096);

    if (!defined $bytes) {
        return if $! == EAGAIN || $! == EWOULDBLOCK;
        $log->error(sprintf('Ynison [%s]: Read error during upgrade: %s',
            $self->{client}->name(), $!));
        $self->_schedule_reconnect();
        return;
    }
    if ($bytes == 0) {
        $log->error(sprintf('Ynison [%s]: Server closed during upgrade',
            $self->{client}->name()));
        $self->_schedule_reconnect();
        return;
    }

    $self->{read_buffer} .= $buf;
    return unless $self->{read_buffer} =~ /(\r?\n\r?\n)/;

    my $sep_start = $-[0];
    my $sep_len   = length($1);
    my $headers   = substr($self->{read_buffer}, 0, $sep_start);
    $self->{read_buffer} = substr($self->{read_buffer}, $sep_start + $sep_len);

    if ($headers =~ m{HTTP/1\.1 101}) {
        my $where = ($self->{state} == STATE_REDIRECTOR) ? 'redirector' : 'state service';
        $log->info(sprintf('Ynison [%s]: WebSocket upgrade OK on %s (current_state=%d)',
            $self->{client}->name(), $where, $self->{state}));

        Slim::Networking::IO::Select::removeRead($fh);
        Slim::Networking::IO::Select::addRead($fh, sub { $self->_on_readable(@_) });

        if ($self->{state} == STATE_STATE_SERVICE) {
            $self->{state} = STATE_ACTIVE;
            $self->{reconnect_delay} = RECONNECT_MIN();
            $log->info(sprintf('Ynison [%s]: ACTIVE - ready to receive state updates',
                $self->{client}->name()));
            $self->_send_register_device();
            $self->_schedule_keepalive();
            $self->_process_state_frames() if length $self->{read_buffer};
        } elsif ($self->{state} == STATE_REDIRECTOR) {
            $log->info('Ynison: Got 101 from redirector, processing frames...');
            $self->{state} = STATE_STATE_SERVICE;
            Slim::Networking::IO::Select::removeRead($fh);
            Slim::Networking::IO::Select::addRead($fh, sub { $self->_on_readable(@_) });
            # Process any frame data in buffer immediately
            $self->_process_state_frames();
        }
    } else {
        # Not 101 response
        my @lines = split /\r\n/, $headers;
        $log->error(sprintf('Ynison [%s]: Expected 101 Switching Protocols, got: %s',
            $self->{client}->name(), $lines[0]));
        $self->_schedule_reconnect();
    }
}

sub _connect_state_service {
    my ($self) = @_;

    return unless $self->{redirect_data};

    my $host = $self->{redirect_data}{host};
    my $extra = {
        'Ynison-Redirect-Ticket' => $self->{redirect_data}{redirect_ticket},
        'Ynison-Session-Id'      => $self->{redirect_data}{session_id},
    };

    $log->info(sprintf('Ynison [%s]: Connecting to state service at %s...',
        $self->{client}->name(), $host));

    $self->_open_ws($host, '/ynison_state.YnisonStateService/PutYnisonState', $extra);
}

# ===========================================================================
# Registration & Commands
# ===========================================================================

sub _send_register_device {
    my ($self) = @_;

    my $ts_ns = int(time() * 1_000_000_000);
    my $ts_ms = int(time() * 1000);

    my $version = {
        device_id    => $self->{device_id},
        version      => "$ts_ns",
        timestamp_ms => '0',
    };

    my $msg = {
        rid                         => _generate_request_id(),
        player_action_timestamp_ms  => "$ts_ms",
        activity_interception_type  => 'DO_NOT_INTERCEPT_BY_DEFAULT',
        update_full_state => {
            device => {
                capabilities => {
                    can_be_player            => \1,
                    can_be_remote_controller => \0,
                    volume_granularity       => 16,
                },
                info => {
                    device_id => $self->{device_id},
                    type      => 'WEB',
                    title     => $self->{client}->name() . ' (LMS)',
                    app_name  => 'Chrome',
                },
                volume_info => {
                    volume => 0.5,
                },
                is_shadow => \0,
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
                    version => $version,
                },
                status => {
                    paused         => \1,
                    progress_ms    => '0',
                    duration_ms    => '0',
                    playback_speed => 1.0,
                    version => $version,
                },
            },
            is_currently_active => \0,
        },
    };

    my $json = JSON::XS::VersionOneAndTwo::encode_json($msg);
    $log->info(sprintf('Ynison [%s]: Sending device registration: %s',
        $self->{client}->name(), substr($json, 0, 200)));

    $self->send_command($msg);
}

# ===========================================================================
# State Processing
# ===========================================================================

sub _process_state_frames {
    my ($self) = @_;

    # Parse WebSocket frames from read_buffer
    while (length($self->{read_buffer}) >= 2) {
        #$log->debug(sprintf('Ynison: Buffer has %d bytes, first bytes: %s',
        #    length($self->{read_buffer}), unpack('H*', substr($self->{read_buffer}, 0, 20))));

        my ($frame_data, $remaining) = _extract_ws_frame($self->{read_buffer});
        if (!defined $frame_data && !defined $remaining) {
            # Incomplete frame - wait for more data
            last;
        }
        $self->{read_buffer} = $remaining // '';
        next unless defined $frame_data;  # close frame already logged by _extract_ws_frame

        my $text = _decode_ws_frame($frame_data);
        unless (defined $text) {
            $log->warn('Ynison: Decode returned undef (close or binary frame)');
            next;
        }

        $log->info(sprintf('Ynison: Decoded text, length=%d: %s',
            length($text), substr($text, 0, 10000)));

        # Parse JSON state
        my $state;
        eval { $state = JSON::XS::VersionOneAndTwo::decode_json($text) };
        if ($@) {
            $log->error(sprintf('Ynison: JSON decode error: %s | raw: %s', $@, substr($text, 0, 200)));
            next;
        }
        $self->_handle_state_update($state);
    }
}

sub _handle_state_update {
    my ($self, $state) = @_;

    # Route based on connection state (like old module's _on_message)
    if ($self->{state} == STATE_STATE_SERVICE) {
        return $self->_handle_redirect($state);
    }

    # STATE_ACTIVE: handle normal state updates
    # Skip pings
    if ($state->{ping}) {
        $self->_send_pong();
        return;
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

sub _handle_redirect {
    my ($self, $msg) = @_;
    unless ($msg->{host} && $msg->{redirect_ticket}) {
        $log->error(sprintf('Ynison [%s]: Unexpected redirector message: %s',
            $self->{client}->name(), JSON::XS::VersionOneAndTwo::encode_json($msg)));
        $self->_schedule_reconnect();
        return;
    }

    $self->{redirect_data} = {
        host            => $msg->{host},
        redirect_ticket => $msg->{redirect_ticket},
        session_id      => $msg->{session_id},
    };

    $log->info(sprintf('Ynison [%s]: Got redirect to host=%s',
        $self->{client}->name(), $msg->{host}));

    $self->_disconnect_socket();
    $self->{state} = STATE_STATE_SERVICE();
    $self->_connect_state_service();
}

# ===========================================================================
# WebSocket Frame Handling
# ===========================================================================

sub _on_readable {
    my ($self, $fh) = @_;
    my $bytes = $fh->sysread(my $buf, 4096);

    if (!defined $bytes) {
        return if $! == EAGAIN || $! == EWOULDBLOCK;
        $log->error(sprintf('Ynison [%s]: Read error: %s',
            $self->{client}->name(), $!));
        $self->_schedule_reconnect();
        return;
    }
    if ($bytes == 0) {
        $log->warn(sprintf('Ynison [%s]: Server closed connection',
            $self->{client}->name()));
        $self->_schedule_reconnect();
        return;
    }

    $self->{read_buffer} .= $buf;
    $self->_process_state_frames();
}

# ===========================================================================
# Keep-Alive & Reconnection
# ===========================================================================

sub _schedule_keepalive {
    my ($self) = @_;
    Slim::Utils::Timers::setTimer($self, \&_send_ping, KEEPALIVE_INTERVAL(), 'keepalive');
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

    $self->_disconnect_socket();
    $self->{state} = STATE_RECONNECT_WAIT();

    if ($self->{reconnect_delay} < RECONNECT_MAX()) {
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

sub _encode_ws_text_frame {
    my ($text) = @_;
    my $len  = length($text);
    my $mask = pack('N', int(rand(0xffffffff)));
    my @m    = unpack('C4', $mask);
    my @d    = unpack('C*', $text);
    $d[$_] ^= $m[$_ % 4] for 0..$#d;

    my $header;
    if    ($len <= 125)   { $header = pack('CC',  0x81, 0x80 | $len); }
    elsif ($len <= 65535) { $header = pack('CCn', 0x81, 0x80 | 126, $len); }
    else                  { return undef; }

    return $header . $mask . pack('C*', @d);
}

sub _queue_frame {
    my ($self, $data) = @_;
    return unless $self->{socket};
    push @{$self->{write_queue}}, $data;
    Slim::Networking::IO::Select::addWrite($self->{socket}, sub { $self->_on_writable(@_) });
}

sub _send_frame {
    my ($self, $data) = @_;
    return unless $self->{socket};
    syswrite($self->{socket}, $data);
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
    # Generate UUID-like string (8-4-4-4-12 hex format)
    my @hex = ('0'..'9', 'a'..'f');
    my $uuid = '';
    for (0..35) {
        if ($_ == 8 || $_ == 13 || $_ == 18 || $_ == 23) {
            $uuid .= '-';
        } else {
            $uuid .= $hex[int(rand(16))];
        }
    }
    return $uuid;
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
                paused         => $paused ? \1 : \0,
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
                    paused         => $status->{paused} // \1,
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
    return unless length($buffer) >= 2;

    my ($b1, $b2) = unpack('CC', substr($buffer, 0, 2));
    my $opcode     = $b1 & 0x0F;
    my $masked     = $b2 & 0x80;
    my $len        = $b2 & 0x7F;
    my $header_len = 2;

    # Handle extended payload length
    if ($len == 126) {
        return unless length($buffer) >= 4;
        $len = unpack('n', substr($buffer, 2, 2));
        $header_len = 4;
    } elsif ($len == 127) {
        return unless length($buffer) >= 10;
        $len = unpack('N', substr($buffer, 6, 4));
        $header_len = 10;
    }

    # Add mask key size if masked
    $header_len += 4 if $masked;

    # Check if we have full frame
    return unless length($buffer) >= $header_len + $len;

    my $payload = substr($buffer, $header_len, $len);

    # Unmask if needed (client→server frames are masked)
    if ($masked) {
        my $mask = substr($buffer, $header_len - 4, 4);
        my @m = unpack('C4', $mask);
        my @d = unpack('C*', $payload);
        $d[$_] ^= $m[$_ % 4] for 0..$#d;
        $payload = pack('C*', @d);
    }

    my $remaining = substr($buffer, $header_len + $len);

    # Handle close frame (opcode 8)
    if ($opcode == 8) {
        my $code   = length($payload) >= 2 ? unpack('n', substr($payload, 0, 2)) : 0;
        my $reason = length($payload) >  2 ? substr($payload, 2) : '';
        $log->warn(sprintf('Ynison: Server sent CLOSE frame: code=%d reason=%s', $code, $reason));
        return (undef, $remaining);
    }

    # Only return text frames (opcode 1)
    return ($payload, $remaining) if $opcode == 1;
    return (undef, $remaining);
}

sub _decode_ws_frame {
    my ($payload) = @_;
    # Payload is already extracted and unmasked by _extract_ws_frame
    return $payload if defined $payload && length($payload) > 0;
    return;
}

1;
