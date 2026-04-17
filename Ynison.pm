package Plugins::yandex::Ynison;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison - Yandex Music Ynison playback sync protocol

=head1 DESCRIPTION

LMS registers as a B<player-only> device (receiver model, like Chromecast).
Yandex sends state updates; LMS executes playback and reports back.

=head2 Connection flow

  DISCONNECTED → connect_redirector()
  STATE_REDIRECTOR   ynison.music.yandex.ru
    GET /redirector.YnisonRedirectService/GetRedirectToYnison
    ← {host, redirect_ticket, session_id}
  STATE_STATE_SERVICE  dynamic host
    GET /ynison_state.YnisonStateService/PutYnisonState
    → UpdateFullState (registration)
  STATE_ACTIVE
    ← UpdateFullState (external changes)
    → UpdatePlayerState (our state reports)
    ↔ Ping/Pong heartbeat every 60 s
  STATE_RECONNECT_WAIT → exponential backoff → connect_redirector()

=head2 Echo detection

Every state message carries C<player_queue.version.device_id>.
When it equals our own device_id, it is our own echo — skip sync logic.
No timers needed.

=head2 Cast detection / sync model

On external state change with C<active_device_id == our device_id>:

  Same entity_id, same track list, different index
    → NEXT/PREV: move LMS playlist position only

  Different entity_id or different track list
    → Cast: rebuild LMS playlist from scratch

  Same track, different paused flag
    → Play/Pause only

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
use Slim::Player::Source;

my $log   = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

use constant {
    STATE_DISCONNECTED   => 0,
    STATE_REDIRECTOR     => 1,
    STATE_STATE_SERVICE  => 2,
    STATE_ACTIVE         => 3,
    STATE_RECONNECT_WAIT => 4,
    HEARTBEAT_INTERVAL   => 60,   # seconds (server keep_alive_time_seconds)
    RECONNECT_MIN        => 5,    # seconds (first retry delay)
    RECONNECT_MAX        => 60,   # seconds (cap)
    SYNCING_GUARD        => 3,    # seconds (suppress Plugin.pm during track load)
};

# ---------------------------------------------------------------------------
# Inner class: SSL-capable async socket
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------
sub new {
    my ($class, $client, $token, $user_id) = @_;
    return unless $client && $token && $user_id;

    my $self = bless {
        client    => $client,
        id        => $client->id(),
        token     => $token,
        user_id   => $user_id,
        device_id => undef,

        socket       => undef,
        read_buffer  => '',
        write_queue  => [],
        state        => STATE_DISCONNECTED,
        is_connected => 0,           # true only in STATE_ACTIVE

        reconnect_delay => RECONNECT_MIN,

        # Yandex state cache — preserved across echoes, used for echo-back
        yandex_queue  => undef,      # full player_queue hash from Yandex
        yandex_status => undef,      # status hash from Yandex

        # Public flags read by Plugin.pm
        syncing_from_yandex => 0,    # Ynison loading content → inhibit detach/volume
        local_mode          => 0,    # User took control → ignore Yandex until Cast
    }, $class;

    my $pref_key = 'ynison_device_id_' . $self->{id};
    $self->{device_id} = $prefs->get($pref_key);
    unless ($self->{device_id}) {
        $self->{device_id} = sprintf('%08x%08x', rand(0xffffffff), rand(0xffffffff));
        $prefs->set($pref_key, $self->{device_id});
    }

    $log->info(sprintf('Ynison [%s]: Initialized, device_id=%s',
        $client->name(), $self->{device_id}));
    $self->connect_redirector();
    return $self;
}

# ---------------------------------------------------------------------------
# Connection lifecycle
# ---------------------------------------------------------------------------
sub connect_redirector {
    my $self = shift;
    $self->{local_mode} = 0;
    $self->{state}      = STATE_REDIRECTOR;
    $log->info(sprintf('Ynison [%s]: Connecting to redirector...', $self->{client}->name()));
    $self->_open_ws('ynison.music.yandex.ru',
                    '/redirector.YnisonRedirectService/GetRedirectToYnison');
}

sub _open_ws {
    my ($self, $host, $path, $extra) = @_;

    # Build Sec-WebSocket-Protocol JSON blob (manual, server is key-order sensitive)
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

    my @hex    = (0..9, 'a'..'f');
    my $ws_key = encode_base64(pack('H*', join('', map { $hex[rand @hex] } 1..32)), '');
    $ws_key =~ s/\s+//g;

    my $async = Plugins::yandex::Ynison::Async->new();
    $async->open({
        Host      => $host,
        PeerPort  => 443,
        https     => 1,
        onConnect => sub {
            my $fh = $async->socket();
            $self->{socket}      = $fh;
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
}

# ---------------------------------------------------------------------------
# HTTP upgrade handler
# ---------------------------------------------------------------------------
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
        $log->info(sprintf('Ynison [%s]: WebSocket upgrade OK on %s',
            $self->{client}->name(), $where));

        Slim::Networking::IO::Select::removeRead($fh);
        Slim::Networking::IO::Select::addRead($fh, sub { $self->_on_readable(@_) });

        if ($self->{state} == STATE_STATE_SERVICE) {
            $self->{state}          = STATE_ACTIVE;
            $self->{is_connected}   = 1;
            $self->{reconnect_delay} = RECONNECT_MIN;   # reset backoff
            $self->_send_full_state_msg();
            $self->_restart_heartbeat();
        }

        $self->_process_frames() if length $self->{read_buffer};
    } else {
        my ($status) = $headers =~ /^(HTTP\/1\.1 \d+ .+)$/m;
        $log->error(sprintf('Ynison [%s]: Upgrade failed: %s',
            $self->{client}->name(), $status // 'unknown'));
        $self->_schedule_reconnect();
    }
}

# ---------------------------------------------------------------------------
# WebSocket frame I/O
# ---------------------------------------------------------------------------
sub _on_readable {
    my ($self, $fh) = @_;
    my $bytes = $fh->sysread(my $buf, 4096);

    if (!defined $bytes) {
        return if $! == EAGAIN || $! == EWOULDBLOCK;
        $log->error(sprintf('Ynison [%s]: Read error: %s', $self->{client}->name(), $!));
        $self->_schedule_reconnect();
        return;
    }
    if ($bytes == 0) {
        $log->debug(sprintf('Ynison [%s]: Server closed connection', $self->{client}->name()));
        $self->_process_frames() if length $self->{read_buffer};
        $self->_schedule_reconnect();
        return;
    }
    $self->{read_buffer} .= $buf;
    $self->_process_frames();
}

sub _process_frames {
    my $self = shift;
    while (length($self->{read_buffer}) >= 2) {
        my ($b1, $b2) = unpack('CC', substr($self->{read_buffer}, 0, 2));
        my $opcode     = $b1 & 0x0F;
        my $masked     = $b2 & 0x80;
        my $len        = $b2 & 0x7F;
        my $header_len = 2;

        if ($len == 126) {
            return if length($self->{read_buffer}) < 4;
            $len = unpack('n', substr($self->{read_buffer}, 2, 2));
            $header_len = 4;
        } elsif ($len == 127) {
            return if length($self->{read_buffer}) < 10;
            $len = unpack('N', substr($self->{read_buffer}, 6, 4));
            $header_len = 10;
        }

        $header_len += 4 if $masked;
        return if length($self->{read_buffer}) < $header_len + $len;

        my $payload = substr($self->{read_buffer}, $header_len, $len);

        if ($masked) {
            my $mask = substr($self->{read_buffer}, $header_len - 4, 4);
            my @m    = unpack('C4', $mask);
            my @d    = unpack('C*', $payload);
            $d[$_] ^= $m[$_ % 4] for 0..$#d;
            $payload = pack('C*', @d);
        }

        $self->{read_buffer} = substr($self->{read_buffer}, $header_len + $len);

        if ($opcode == 1) {           # Text frame
            my $data = eval { decode_json($payload) };
            if ($@) {
                $log->error(sprintf('Ynison [%s]: JSON decode error: %s',
                    $self->{client}->name(), $@));
                next;
            }
            $self->_on_message($data);
            return unless $self->{socket};   # socket closed during redirect

        } elsif ($opcode == 8) {      # Close frame
            my $code   = length($payload) >= 2 ? unpack('n', substr($payload, 0, 2)) : '?';
            my $reason = length($payload)  > 2 ? substr($payload, 2) : '';
            $log->info(sprintf('Ynison [%s]: Close frame: %s %s',
                $self->{client}->name(), $code, $reason));
            $self->_schedule_reconnect();
            return;

        } elsif ($opcode == 9) {      # Ping → Pong
            $self->{socket}->syswrite(pack('CC', 0x8A, 0)) if $self->{socket};

        }
        # opcode 10 = Pong: ignore
    }
}

sub _on_writable {
    my ($self, $fh) = @_;
    while (@{$self->{write_queue}}) {
        my $buf   = shift @{$self->{write_queue}};
        my $bytes = $fh->syswrite($buf);
        if (!defined $bytes) {
            if ($! == EAGAIN || $! == EWOULDBLOCK) {
                unshift @{$self->{write_queue}}, $buf;
                return;
            }
            $log->error(sprintf('Ynison [%s]: Write error: %s', $self->{client}->name(), $!));
            $self->_schedule_reconnect();
            return;
        }
        if ($bytes < length($buf)) {
            unshift @{$self->{write_queue}}, substr($buf, $bytes);
            return;
        }
    }
    Slim::Networking::IO::Select::removeWrite($fh);
}

sub _encode_ws_frame {
    my ($self, $text) = @_;
    my $len  = length($text);
    my $mask = pack('N', int(rand(0xffffffff)));
    my @m    = unpack('C4', $mask);
    my @d    = unpack('C*', $text);
    $d[$_] ^= $m[$_ % 4] for 0..$#d;

    my $header;
    if    ($len <= 125)   { $header = pack('CC',  0x81, 0x80 | $len); }
    elsif ($len <= 65535) { $header = pack('CCn', 0x81, 0x80 | 126, $len); }
    else                  { return; }

    return $header . $mask . pack('C*', @d);
}

sub _send_message {
    my ($self, $data) = @_;
    return unless $self->{socket};
    my $frame = $self->_encode_ws_frame(encode_json($data));
    push @{$self->{write_queue}}, $frame;
    Slim::Networking::IO::Select::addWrite($self->{socket}, sub { $self->_on_writable(@_) });
}

# ---------------------------------------------------------------------------
# Message routing
# ---------------------------------------------------------------------------
sub _on_message {
    my ($self, $msg) = @_;
    if ($self->{state} == STATE_REDIRECTOR) {
        $self->_handle_redirect($msg);
    } else {
        $self->_handle_state_message($msg);
    }
}

sub _handle_redirect {
    my ($self, $msg) = @_;
    unless ($msg->{host} && $msg->{redirect_ticket}) {
        $log->error(sprintf('Ynison [%s]: Unexpected redirector message: %s',
            $self->{client}->name(), encode_json($msg)));
        $self->_schedule_reconnect();
        return;
    }

    my $host = $msg->{host};
    $host =~ s{^(wss?|https?)://}{};
    $host =~ s{/+$}{};
    $log->info(sprintf('Ynison [%s]: Redirected to %s', $self->{client}->name(), $host));

    $self->_disconnect_socket();
    $self->{state} = STATE_STATE_SERVICE;
    $self->_open_ws($host, '/ynison_state.YnisonStateService/PutYnisonState', {
        'Ynison-Redirect-Ticket' => $msg->{redirect_ticket},
        'Ynison-Session-Id'      => $msg->{session_id},
    });
}

sub _handle_state_message {
    my ($self, $msg) = @_;
    my $client = $self->{client};

    if ($msg->{error}) {
        $log->error(sprintf('Ynison [%s]: Server error: %s', $client->name(),
            $msg->{error}{message} // encode_json($msg->{error})));
        return;
    }

    # Normalize: server sends player_state at top level or inside update_full_state
    my $player_state = $msg->{player_state}
        // ($msg->{update_full_state} && $msg->{update_full_state}{player_state});

    my $active_id = $msg->{active_device_id_optional} // '';

    # Volume sync is independent of echo detection
    $self->_sync_volume($msg->{devices}) if $msg->{devices};

    return unless $player_state;

    my $queue = $player_state->{player_queue} // {};

    # Echo filter: if queue version.device_id == ours, we sent this state update
    my $q_author = ($queue->{version} // {})->{device_id} // '';
    if ($q_author eq $self->{device_id}) {
        $log->debug(sprintf('Ynison [%s]: Skipping own echo', $client->name()));
        return;
    }

    $log->debug(sprintf('Ynison [%s]: External state, active=%s author=%s',
        $client->name(), $active_id || '(none)', $q_author));

    # Cache full Yandex state (used when echoing back to preserve entity_id etc.)
    $self->_cache_yandex_state($player_state);

    # Only act when we are the active device
    return unless $active_id eq $self->{device_id};

    # Re-attach from local_mode on Cast (someone selected us as active)
    if ($self->{local_mode}) {
        $log->info(sprintf('Ynison [%s]: Cast received — exiting local mode', $client->name()));
        $self->{local_mode} = 0;
    }

    $self->_apply_yandex_state($player_state);
}

# ---------------------------------------------------------------------------
# State application: decide what to do with incoming Yandex state
# ---------------------------------------------------------------------------
sub _apply_yandex_state {
    my ($self, $player_state) = @_;
    my $client = $self->{client};

    my $queue  = $player_state->{player_queue} // {};
    my $status = $player_state->{status}       // {};

    my $remote_paused = $status->{paused} ? 1 : 0;
    my $remote_idx    = $queue->{current_playable_index} // 0;
    my $remote_list   = $queue->{playable_list}          // [];
    my $remote_entity = $queue->{entity_id}              // '';

    return unless @$remote_list;
    return unless $remote_idx >= 0 && $remote_idx < @$remote_list;

    my $remote_track = $remote_list->[$remote_idx]{playable_id} // '';
    return unless $remote_track;

    # Current LMS track
    my $lms_track = '';
    if (my $song = $client->playingSong()) {
        if (my $track = $song->track()) {
            ($lms_track) = $track->url() =~ /yandexmusic:\/\/(\d+)/;
            $lms_track //= '';
        }
    }

    my $same_queue = $self->_is_same_queue($remote_list, $remote_entity);
    my $pfx        = sprintf('Ynison [%s]:', $client->name());

    $log->debug(sprintf('%s _apply_yandex_state: same_queue=%d, remote_track=%s, lms_track=%s, entity=%s',
        $pfx, $same_queue, $remote_track, $lms_track, $remote_entity || '(none)'));

    if ($same_queue && $remote_track eq $lms_track) {
        # Same track, same queue — only play/pause
        $log->info("$pfx Same track, syncing play/pause (remote_paused=$remote_paused)");
        $self->_sync_play_pause($remote_paused);

    } elsif ($same_queue) {
        # Same queue, different track — NEXT/PREV, no rebuild needed
        $log->info("$pfx NEXT/PREV to index $remote_idx (track=$remote_track)");
        $self->_set_syncing_guard();
        $client->execute(['playlist', 'index', $remote_idx]);
        $self->_sync_play_pause($remote_paused) unless $remote_paused;

    } else {
        # Different entity or different track list — full Cast, rebuild playlist
        $log->info(sprintf('%s Cast: entity=%s, %d tracks, idx=%d, track=%s',
            $pfx, $remote_entity || '(none)', scalar(@$remote_list), $remote_idx, $remote_track));
        $self->_rebuild_queue($remote_list, $remote_idx, $remote_paused);
    }
}

sub _is_same_queue {
    my ($self, $remote_list, $remote_entity) = @_;
    my $cached = $self->{yandex_queue};
    return 0 unless $cached;
    return 0 unless ($cached->{entity_id} // '') eq $remote_entity;
    my $cached_list = $cached->{playable_list} // [];
    return 0 unless @$cached_list == @$remote_list;
    for my $i (0..$#$remote_list) {
        return 0 unless ($remote_list->[$i]{playable_id} // '') eq
                        ($cached_list->[$i]{playable_id}  // '');
    }
    return 1;
}

sub _sync_play_pause {
    my ($self, $remote_paused) = @_;
    my $client = $self->{client};
    if ($remote_paused && $client->isPlaying()) {
        $self->_set_syncing_guard();
        $client->execute(['pause', 1]);
    } elsif (!$remote_paused && $client->isPaused()) {
        $self->_set_syncing_guard();
        $client->execute(['play']);
    }
}

sub _rebuild_queue {
    my ($self, $list, $target_idx, $start_paused) = @_;
    my $client = $self->{client};

    $log->info(sprintf('Ynison [%s]: _rebuild_queue: clearing playlist, adding %d tracks, target_idx=%d, paused=%d',
        $client->name(), scalar(@$list), $target_idx, $start_paused));

    $self->_set_syncing_guard();
    $client->execute(['playlist', 'clear']);

    for my $i (0..$#$list) {
        my $track = $list->[$i];
        next unless $track && $track->{playable_id};
        my $url = 'yandexmusic://' . $track->{playable_id};
        $log->debug(sprintf('Ynison [%s]: Adding track %d: %s', $client->name(), $i, $url));
        $client->execute(['playlist', 'add', $url]);
    }

    $log->info(sprintf('Ynison [%s]: Setting index to %d, playing=%d',
        $client->name(), $target_idx, !$start_paused));
    $client->execute(['playlist', 'index', $target_idx]);
    $client->execute(['play']) unless $start_paused;
}

# ---------------------------------------------------------------------------
# Yandex state cache
# ---------------------------------------------------------------------------
sub _cache_yandex_state {
    my ($self, $player_state) = @_;

    if (ref $player_state->{player_queue} eq 'HASH') {
        my $list = $player_state->{player_queue}{playable_list};
        if (ref $list eq 'ARRAY' && @$list) {
            $self->{yandex_queue} = $player_state->{player_queue};
        }
    }
    if (ref $player_state->{status} eq 'HASH') {
        $self->{yandex_status} = $player_state->{status};
    }
}

# ---------------------------------------------------------------------------
# Volume sync
# ---------------------------------------------------------------------------
sub _sync_volume {
    my ($self, $devices) = @_;
    return unless ref $devices eq 'ARRAY';
    my $client = $self->{client};

    for my $dev (@$devices) {
        next unless $dev->{info} && ($dev->{info}{device_id} // '') eq $self->{device_id};
        my $v = ($dev->{volume_info} // {})->{volume};
        next unless defined $v;

        my $new_vol = int($v * 100);
        my $cur_vol = $client->volume() || 0;
        if (abs($new_vol - $cur_vol) >= 1) {
            $log->info(sprintf('Ynison [%s]: Volume %.2f → %d',
                $client->name(), $v, $new_vol));
            $self->_set_syncing_guard();
            $client->execute(['mixer', 'volume', $new_vol]);
        }
        last;
    }
}

sub _send_volume_update {
    my ($self, $volume_float) = @_;
    return unless $self->{is_connected} && !$self->{local_mode};
    $volume_float = 0 if $volume_float < 0;
    $volume_float = 1 if $volume_float > 1;
    my $ts  = int(time() * 1000);
    my $ver = int(rand(0x7fffffff));
    $self->_send_message({
        update_volume_info => {
            device_id  => $self->{device_id},
            volume_info => {
                volume  => $volume_float,
                version => {
                    device_id    => $self->{device_id},
                    version      => "$ver",
                    timestamp_ms => "$ts",
                },
            },
        },
        rid                        => $self->_new_rid(),
        player_action_timestamp_ms => "$ts",
        activity_interception_type => 'DO_NOT_INTERCEPT_BY_DEFAULT',
    });
}

# ---------------------------------------------------------------------------
# State reporting (LMS → Yandex)
# ---------------------------------------------------------------------------
sub update_state {
    my $self   = shift;
    my $client = $self->{client};

    return unless $self->{is_connected};
    return if $self->{syncing_from_yandex};
    return if $self->{local_mode};
    return unless $client->isPlaying() || $client->isPaused();

    my $state;
    eval {
        $state = $self->_build_player_state();
    };
    if ($@) {
        $log->error(sprintf('Ynison [%s]: Failed to build player state: %s',
            $client->name(), $@));
        return;
    }
    return unless @{$state->{player_queue}{playable_list} // []};

    my $ts  = int(time() * 1000);
    $self->_send_message({
        update_player_state        => {player_state => $state},
        rid                        => $self->_new_rid(),
        player_action_timestamp_ms => "$ts",
        activity_interception_type => 'DO_NOT_INTERCEPT_BY_DEFAULT',
    });
}

sub _build_player_state {
    my $self   = shift;
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
    eval {
        $prog_ms = int((Slim::Player::Source::songTime($client) || 0) * 1000);
    };
    if ($@) {
        $log->debug(sprintf('Ynison [%s]: songTime error (ignore): %s',
            $client->name(), $@));
        $prog_ms = 0;
    }

    my $status = {
        duration_ms    => "$dur_ms",
        paused         => $paused,
        playback_speed => 1.0,
        progress_ms    => "$prog_ms",
        version        => $version,
    };

    my $player_queue;

    if ($self->{yandex_queue} && @{$self->{yandex_queue}{playable_list} // []}) {
        # Shallow-copy cached Yandex queue — preserves entity_id, entity_type,
        # album_id_optional, navigation_id_optional, playback_action_id_optional,
        # track_info, cover_url_optional and all other extra fields intact.
        $player_queue = {%{$self->{yandex_queue}}};
        $player_queue->{version} = $version;

        # Update index to reflect actual LMS position
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
        # No Yandex cache yet — minimal single-track fallback
        my $tid = '';
        if ($song && $song->track()) {
            ($tid) = $song->track()->url() =~ /yandexmusic:\/\/(\d+)/;
        }
        $player_queue = {
            current_playable_index => 0,
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

sub _send_full_state_msg {
    my ($self, %opts) = @_;
    my $client    = $self->{client};
    my $is_active = $opts{force_inactive} ? \0
                  : ($client->isPlaying() || $client->isPaused()) ? \1 : \0;
    my $intercept = $opts{force_inactive} ? 'DO_NOT_INTERCEPT_BY_DEFAULT'
                  : 'INTERCEPT_IF_NO_ONE_ACTIVE';
    my $vol       = ($client->volume() || 0) / 100.0;
    my $ts_ms     = int(time() * 1000);
    my $state;
    eval {
        $state = $self->_build_player_state();
    };
    if ($@) {
        $log->error(sprintf('Ynison [%s]: Failed to build player state in full msg: %s',
            $client->name(), $@));
        return;
    }

    $self->_send_message({
        update_full_state => {
            player_state => $state,
            device => {
                capabilities => {
                    can_be_player            => \1,
                    can_be_remote_controller => \0,
                    volume_granularity       => 16,
                },
                info => {
                    device_id => $self->{device_id},
                    type      => 'WEB',
                    title     => $client->name() . ' (LMS)',
                    app_name  => 'Chrome',
                },
                volume_info => {volume => $vol},
                is_shadow   => \0,
            },
            is_currently_active => $is_active,
        },
        rid                        => $self->_new_rid(),
        player_action_timestamp_ms => "$ts_ms",
        activity_interception_type => $intercept,
    });
}

sub detach_from_yandex {
    my $self = shift;
    return unless $self->{is_connected};
    return if $self->{local_mode};
    $self->{local_mode} = 1;
    $log->info(sprintf('Ynison [%s]: Local control taken', $self->{client}->name()));
    $self->_send_full_state_msg(force_inactive => 1);
    # Auto-reset local_mode after 10 minutes with explicit update_state()
    Slim::Utils::Timers::killTimers($self, \&_local_mode_timeout);
    Slim::Utils::Timers::setTimer($self, time() + 600, \&_local_mode_timeout);
}

# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------
sub _restart_heartbeat {
    my $self = shift;
    Slim::Utils::Timers::killTimers($self, \&_heartbeat_tick);
    Slim::Utils::Timers::setTimer($self, time() + HEARTBEAT_INTERVAL, \&_heartbeat_tick);
}

sub _heartbeat_tick {
    my $self = shift;
    return unless $self->{socket} && $self->{state} == STATE_ACTIVE;
    $self->{socket}->syswrite(pack('CC', 0x89, 0x00));   # WebSocket Ping frame
    $log->debug(sprintf('Ynison [%s]: Heartbeat ping sent', $self->{client}->name()));
    Slim::Utils::Timers::setTimer($self, time() + HEARTBEAT_INTERVAL, \&_heartbeat_tick);
}

# ---------------------------------------------------------------------------
# Reconnect with exponential backoff (5 → 10 → 30 → 60 → 60 → …)
# ---------------------------------------------------------------------------
sub _schedule_reconnect {
    my $self  = shift;
    my $delay = $self->{reconnect_delay};
    $self->_disconnect_socket();
    $self->{state} = STATE_RECONNECT_WAIT;

    $log->info(sprintf('Ynison [%s]: Reconnecting in %ds...',
        $self->{client}->name(), $delay));

    my $next = $delay * 2;
    $next = RECONNECT_MAX if $next > RECONNECT_MAX;
    $self->{reconnect_delay} = $next;

    Slim::Utils::Timers::setTimer($self, time() + $delay, sub {
        my $s = shift;
        $s->connect_redirector();
    });
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
sub _disconnect_socket {
    my $self = shift;
    if ($self->{socket}) {
        Slim::Networking::IO::Select::removeRead($self->{socket});
        Slim::Networking::IO::Select::removeWrite($self->{socket});
        eval { $self->{socket}->close() };
        $self->{socket} = undef;
    }
    $self->{is_connected} = 0;
    $self->{read_buffer}  = '';
}

sub _cleanup {
    my $self = shift;
    Slim::Utils::Timers::killTimers($self, \&_heartbeat_tick);
    Slim::Utils::Timers::killTimers($self, \&_clear_syncing_flag);
    Slim::Utils::Timers::killTimers($self, \&_local_mode_timeout);
    $self->_disconnect_socket();
    $self->{state} = STATE_DISCONNECTED;
    $log->info(sprintf('Ynison [%s]: Disconnected', $self->{client}->name()));
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub _set_syncing_guard {
    my $self = shift;
    Slim::Utils::Timers::killTimers($self, \&_clear_syncing_flag);
    $self->{syncing_from_yandex} = 1;
    Slim::Utils::Timers::setTimer($self, time() + SYNCING_GUARD, \&_clear_syncing_flag);
}

sub _clear_syncing_flag { $_[0]->{syncing_from_yandex} = 0 }

sub is_ynison_track {
    my $self = shift;
    my $client = $self->{client};
    my $song = $client->playingSong();
    return 0 unless $song && $song->track();

    # Extract current track ID from URL
    my ($tid) = $song->track()->url() =~ /yandexmusic:\/\/(\d+)/;
    return 0 unless $tid;

    # Check if this track is in the cached Yandex queue
    my $list = $self->{yandex_queue}{playable_list} // [];
    for my $item (@$list) {
        return 1 if ($item->{playable_id} // '') eq $tid;
    }
    return 0;
}

sub _local_mode_timeout {
    my $self = shift;
    my $client = $self->{client};
    $log->info(sprintf('Ynison [%s]: local_mode timeout — resetting', $client->name()));
    $self->{local_mode} = 0;
    # Send current LMS state to re-register without auto-capture
    $self->update_state();
}

sub _new_rid {
    sprintf('%08x-%04x-%04x-%04x-%06x%06x',
        int(rand(0xffffffff)), int(rand(0xffff)), int(rand(0xffff)),
        int(rand(0xffff)),     int(rand(0xffffff)), int(rand(0xffffff)));
}

1;
