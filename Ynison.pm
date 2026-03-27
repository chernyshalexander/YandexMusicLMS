package Plugins::yandex::Ynison;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use MIME::Base64;
use Encode qw(encode_utf8 decode_utf8);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::Async;
use Slim::Networking::IO::Select;
use Time::HiRes qw(time);
use Errno qw(EAGAIN EWOULDBLOCK);
use Slim::Player::Source;

my $log = logger('plugin.yandex');
my $prefs = preferences('plugin.yandex');

# Connection states
use constant {
    STATE_DISCONNECTED => 0,
    STATE_REDIRECTOR   => 1,
    STATE_STATE_SERVICE => 2,
};

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

sub new {
    my ($class, $client) = @_;

    return unless $client;

    my $self = bless {
        client        => $client,
        id            => $client->id(),
        socket        => undef,
        read_buffer   => '',
        write_queue   => [],
        is_connected  => 0,
        current_state => STATE_DISCONNECTED,
        device_id     => undef,
        oauth_token   => undef,
        user_id       => undef,
        last_playable_list => [],  # Cache last playable list from Yandex
        last_state_version => undef,  # Cache last version to avoid duplicate updates
        syncing_from_yandex => 0,  # Flag to prevent update_state() loop during sync
    }, $class;

    $self->init();
    return $self;
}

sub init {
    my $self = shift;

    my $client = $self->{client};
    $log->info("Ynison: Initializing protocol for player: " . $client->name());

    my $yandex_client = Plugins::yandex::Plugin->getClient();
    if (!$yandex_client || !$yandex_client->get_me()) {
        $log->error("Ynison: Yandex client not fully initialized yet.");
        return;
    }

    $self->{oauth_token} = $yandex_client->{token};
    $self->{user_id} = $yandex_client->get_me()->{uid};

    # Use a persistent random device ID per player if not already set
    if (!$self->{device_id}) {
        my $id_pref = "ynison_device_id_" . $self->{id};
        $self->{device_id} = $prefs->get($id_pref);
        if (!$self->{device_id}) {
            $self->{device_id} = sprintf("%08x%08x", rand(0xffffffff), rand(0xffffffff));
            $prefs->set($id_pref, $self->{device_id});
        }
    }

    $self->connect_redirector();
}

sub connect_redirector {
    my $self = shift;

    $self->{current_state} = STATE_REDIRECTOR;
    my $host = "ynison.music.yandex.ru";
    my $path = "/redirector.YnisonRedirectService/GetRedirectToYnison";
    
    $log->info("Ynison [" . $self->{client}->name() . "]: Connecting to redirector...");
    $self->_open_ws($host, $path);
}

sub _open_ws {
    my ($self, $host, $path, $extra_handshake_data) = @_;

    # Use the same device_id that was initialized in init()
    my $device_id = $self->{device_id};
    
    # Successful test log format for device_info: {"app_name":"Chrome","type":1}
    # Note: JSON::PP encode_json doesn't add spaces.
    my $device_info_json = '{"app_name":"Chrome","type":1}';
    my $device_info_esc = $device_info_json;
    $device_info_esc =~ s/"/\\"/g;

    # Successful test log order for handshake from user's earlier message:
    # {"Ynison-Device-Info":"...","Ynison-Device-Id":"..."}
    my $handshake_json = sprintf(
        '{"Ynison-Device-Info":"%s","Ynison-Device-Id":"%s"',
        $device_info_esc,
        $device_id
    );

    if ($extra_handshake_data && $extra_handshake_data->{"Ynison-Redirect-Ticket"}) {
        $handshake_json .= sprintf(',"Ynison-Redirect-Ticket":"%s"', $extra_handshake_data->{"Ynison-Redirect-Ticket"});
    }
    if ($extra_handshake_data && $extra_handshake_data->{"Ynison-Session-Id"}) {
        $handshake_json .= sprintf(',"Ynison-Session-Id":"%s"', $extra_handshake_data->{"Ynison-Session-Id"});
    }

    # Add authorization headers for state service
    $handshake_json .= sprintf(',"authorization":"OAuth %s"', $self->{oauth_token});
    if ($self->{user_id}) {
        $handshake_json .= sprintf(',"X-Yandex-Music-Multi-Auth-User-Id":"%s"', $self->{user_id});
    }

    $handshake_json .= '}';
    
    my $protocol_header = "Bearer, v2, $handshake_json";

    my @hex = (0..9, 'a'..'f');
    my $random_hex = join('', map { $hex[rand @hex] } 1..32);
    my $ws_key = encode_base64(pack("H*", $random_hex), "");
    $ws_key =~ s/\s+//g;

    my $async = Plugins::yandex::Ynison::Async->new();
    $async->open({
        Host      => $host,
        PeerPort  => 443,
        https     => 1,
        onConnect => sub {
            my $fh = $async->socket();
            $self->{socket} = $fh;

            my $request = "GET $path HTTP/1.1\r\n" .
                         "Host: $host\r\n" .
                         "Upgrade: websocket\r\n" .
                         "Connection: Upgrade\r\n" .
                         "Sec-WebSocket-Key: $ws_key\r\n" .
                         "Sec-WebSocket-Version: 13\r\n" .
                         "Sec-WebSocket-Protocol: $protocol_header\r\n" .
                         "Authorization: OAuth " . $self->{oauth_token} . "\r\n" .
                         "Origin: https://music.yandex.ru\r\n" .
                         "\r\n";

            $log->info("Ynison [" . $self->{client}->name() . "]: Socket connected to $host, sending Upgrade...");

            $fh->blocking(0);
            $self->{write_queue} = [$request];
            $self->{read_buffer} = '';
            
            Slim::Networking::IO::Select::addWrite($fh, sub { $self->_on_writable(@_) });
            Slim::Networking::IO::Select::addRead($fh, sub { $self->_on_http_response(@_) });
        },
        onError => sub {
            my ($async, $error) = @_;
            $log->error("Ynison [" . $self->{client}->name() . "]: Connection error on $host: $error");
        }
    });
}

sub _on_http_response {
    my ($self, $fh) = @_;
    my $bytes = $fh->sysread(my $buffer, 4096);

    if (!defined $bytes) {
        if ($! == EAGAIN || $! == EWOULDBLOCK) {
            return; # Just wait for more data
        }
        $log->error("Ynison [" . $self->{client}->name() . "]: Read error during Upgrade: $!");
        $self->_cleanup();
        return;
    }
    if ($bytes == 0) {
        $log->error("Ynison [" . $self->{client}->name() . "]: Connection closed by server during Upgrade handshake.");
        $self->_cleanup();
        return;
    }

    $self->{read_buffer} .= $buffer;

    if ($self->{read_buffer} =~ /(\r?\n\r?\n)/) {
        my $headers_len = $-[0];
        my $sep_len = length($1);
        my $headers = substr($self->{read_buffer}, 0, $headers_len);
        my $body = substr($self->{read_buffer}, $headers_len + $sep_len);

        if ($headers =~ m{HTTP/1.1 101}) {
            $log->info("Ynison [" . $self->{client}->name() . "]: WebSocket upgrade successful on " . ($self->{current_state} == STATE_REDIRECTOR ? "redirector" : "state service"));
            
            $self->{read_buffer} = $body;
            
            Slim::Networking::IO::Select::removeRead($fh);
            Slim::Networking::IO::Select::addRead($fh, sub { $self->_on_readable(@_) });

            if (length $self->{read_buffer}) {
                if ($log->is_debug) {
                    my $hex = unpack("H*", substr($self->{read_buffer}, 0, 128));
                    $log->debug("Ynison [" . $self->{client}->name() . "]: Upgrade body hex (first 128 bytes): $hex");
                }
                $self->_process_frames();
            }
            
            if ($self->{current_state} == STATE_STATE_SERVICE) {
                $self->{is_connected} = 1;
                $self->_send_full_state_msg();
            }
        } else {
            my ($status) = $headers =~ /^(HTTP\/1.1 \d+ .+)$/m;
            $log->error("Ynison [" . $self->{client}->name() . "]: Upgrade failed: " . ($status || "Unknown error"));
            $log->debug("Ynison [" . $self->{client}->name() . "]: Response headers:\n" . $headers);
            $self->_cleanup();
        }
    }
}

sub _cleanup {
    my $self = shift;
    if ($self->{socket}) {
        Slim::Networking::IO::Select::removeRead($self->{socket});
        Slim::Networking::IO::Select::removeWrite($self->{socket});
        $self->{socket}->close();
        $self->{socket} = undef;
    }
    $self->{is_connected} = 0;
    $self->{current_state} = STATE_DISCONNECTED;
}

sub _cleanup_with_reconnect {
    my $self = shift;
    $self->_cleanup();

    # Schedule reconnection after 5 seconds (only on actual connection errors)
    Slim::Utils::Timers::setTimer($self, time() + 5, sub {
        my $s = shift;
        $log->info("Ynison [" . $s->{client}->name() . "]: Reconnecting after connection error...");
        $s->connect_redirector();
    });
}

sub _process_frames {
    my $self = shift;
    while (length($self->{read_buffer}) >= 2) {
        my ($b1, $b2) = unpack("CC", substr($self->{read_buffer}, 0, 2));
        my $opcode = $b1 & 0x0F;
        my $masked = $b2 & 0x80;
        my $len = $b2 & 0x7F;
        my $header_len = 2;

        if ($len == 126) {
            return if length($self->{read_buffer}) < 4;
            $len = unpack("n", substr($self->{read_buffer}, 2, 2));
            $header_len = 4;
        } elsif ($len == 127) {
            return if length($self->{read_buffer}) < 10;
            $len = unpack("N", substr($self->{read_buffer}, 6, 4));
            $header_len = 10;
        }

        if ($masked) {
            $header_len += 4;
        }

        return if length($self->{read_buffer}) < ($header_len + $len);

        my $payload = substr($self->{read_buffer}, $header_len, $len);
        
        if ($masked) {
            my $mask = substr($self->{read_buffer}, $header_len - 4, 4);
            my @m = unpack("C4", $mask);
            my @d = unpack("C*", $payload);
            for (my $i = 0; $i < @d; $i++) { $d[$i] ^= $m[$i % 4]; }
            $payload = pack("C*", @d);
        }

        $self->{read_buffer} = substr($self->{read_buffer}, $header_len + $len);


        if ($opcode == 1) { # Text
            my $data = eval { decode_json($payload) };
            if (!$@ && $data) {
                $self->_handle_message($data);
                # If we redirected, handle_message cleaned up and read_buffer might be invalid for old connection
                return unless $self->{socket} && $self->{current_state} != STATE_STATE_SERVICE;
            } else {
                $log->error("Ynison [" . $self->{client}->name() . "]: JSON decode failed: $@. Payload: $payload");
            }
        } elsif ($opcode == 8) {
            my $code = length($payload) >= 2 ? unpack("n", substr($payload, 0, 2)) : "No code";
            my $reason = length($payload) > 2 ? substr($payload, 2) : "No reason";
            $log->info("Ynison [" . $self->{client}->name() . "]: Close frame received. Code: $code, Reason: $reason");
            $self->_cleanup();
            return;
        } elsif ($opcode == 9) {
            if ($self->{socket}) {
                $log->debug("Ynison [" . $self->{client}->name() . "]: Ping received, sending Pong");
                $self->{socket}->syswrite(pack("CC", 0x8A, 0));
            }
        }
    }
}

sub _handle_message {
    my ($self, $msg) = @_;

    if ($self->{current_state} == STATE_REDIRECTOR) {
        if ($msg->{host} && $msg->{redirect_ticket}) {
            # Normalize host: remove wss:// or https:// prefixes (cf. Python reference)
            my $host = $msg->{host};
            $host =~ s{^(wss?|https?)://}{};
            $host =~ s{/+$}{};

            $log->info("Ynison [" . $self->{client}->name() . "]: Redirected to $host");
            my $ticket = $msg->{redirect_ticket};
            my $session_id = $msg->{session_id};

            $self->_cleanup();
            $self->{current_state} = STATE_STATE_SERVICE;
            $self->_open_ws($host, "/ynison_state.YnisonStateService/PutYnisonState", {
                "Ynison-Redirect-Ticket" => $ticket,
                "Ynison-Session-Id"      => $session_id
            });
        }
    } else {
        $self->_handle_ynison_message($msg);
    }
}

sub update_state {
    my ($self) = @_;
    my $client = $self->{client};
    return unless $self->{is_connected};

    # Skip sending state while syncing from Yandex to prevent echo loop
    if ($self->{syncing_from_yandex}) {
        $log->debug("Ynison [" . $client->name() . "]: Skipping update - syncing from Yandex");
        return;
    }

    # Don't send state during initial track load (not playing and not paused = still loading)
    # This prevents echo loop: LMS sends paused=true -> Yandex sends PAUSED back
    unless ($client->isPlaying() || $client->isPaused()) {
        return;
    }

    my $player_state = $self->_get_player_state();

    # CRITICAL: Don't send update_player_state with empty playable_list
    # Yandex requires: "Empty playable list is restricted"
    if (!$player_state->{player_queue}->{playable_list} ||
        @{$player_state->{player_queue}->{playable_list}} == 0) {
        $log->debug("Ynison [" . $self->{client}->name() . "]: Skipping update - playable_list is empty");
        return;
    }

    # Use one-off command for state updates to avoid 500 errors
    $self->_send_one_off_command('update_player_state', $player_state);
}

sub _send_full_state_msg {
    my $self = shift;
    my $player_state = $self->_get_player_state();
    my $ts = int(time() * 1000);

    # Fix #5: Send real volume instead of hardcoded 0
    my $current_vol = $self->{client}->volume() || 0;
    my $vol_fraction = $current_vol / 100.0;

    my $msg = {
        update_full_state => {
            player_state => $player_state,
            device => {
                capabilities => {
                    can_be_player => \1,
                    can_be_remote_controller => \0,
                    volume_granularity => 16
                },
                info => {
                    device_id => $self->{device_id},
                    type => "WEB",
                    title => $self->{client}->name() . " (LMS)",
                    app_name => "Chrome"
                },
                volume_info => {
                    volume => $vol_fraction
                },
                is_shadow => \0
            },
            is_currently_active => \0
        },
        rid => "ac281c26-a047-4419-ad00-e4fbfda1cba3",
        player_action_timestamp_ms => "$ts",
        activity_interception_type => "DO_NOT_INTERCEPT_BY_DEFAULT"
    };
    $self->_send_message($msg);
}

sub _on_readable {
    my ($self, $fh) = @_;
    my $bytes = $fh->sysread(my $buffer, 4096);
    if (!defined $bytes) {
        if ($! == EAGAIN || $! == EWOULDBLOCK) {
            return;
        }
        $log->error("Ynison [" . $self->{client}->name() . "]: Read error: $!");
        $self->_cleanup_with_reconnect();
        return;
    }
    if ($bytes == 0) {
        $log->debug("Ynison [" . $self->{client}->name() . "]: Connection closed by server.");
        if (length $self->{read_buffer}) {
            $self->_process_frames();
        }
        $self->_cleanup();
        return;
    }
    $self->{read_buffer} .= $buffer;
    $self->_process_frames();
}

sub _send_message {
    my ($self, $data) = @_;
    my $json = encode_json($data);
    my $frame = $self->_encode_ws_frame($json);
    push @{$self->{write_queue}}, $frame;
    Slim::Networking::IO::Select::addWrite($self->{socket}, sub { $self->_on_writable(@_) });
}

sub _on_writable {
    my ($self, $fh) = @_;
    while (@{$self->{write_queue}}) {
        my $buf = shift @{$self->{write_queue}};
        my $bytes = $fh->syswrite($buf);
        if (!defined $bytes) {
            if ($! == EAGAIN || $! == EWOULDBLOCK) {
                unshift @{$self->{write_queue}}, $buf;
                return;
            }
            $log->error("Ynison [" . $self->{client}->name() . "]: Write error: $!");
            $self->_cleanup();
            return;
        }
        if ($bytes < length($buf)) { unshift @{$self->{write_queue}}, substr($buf, $bytes); return; }
    }
    Slim::Networking::IO::Select::removeWrite($fh);
}

sub _encode_ws_frame {
    my ($self, $data) = @_;
    my $len = length($data);
    my $header;
    if ($len <= 125) { $header = pack("CC", 0x81, 0x80 | $len); }
    elsif ($len <= 65535) { $header = pack("CCn", 0x81, 0x80 | 126, $len); }
    else { return; }
    my $mask = pack("N", int(rand(0xffffffff)));
    $header .= $mask;
    my @m = unpack("C4", $mask);
    my @d = unpack("C*", $data);
    for (my $i = 0; $i < @d; $i++) { $d[$i] ^= $m[$i % 4]; }
    return $header . pack("C*", @d);
}

sub _send_one_off_command {
    my ($self, $command_type, $data) = @_;
    return unless $self->{is_connected};

    # Use nanoseconds for version - as string (Yandex expects string type)
    my $ts_num = int(time() * 1000000000);
    my $ts = "$ts_num";
    my $ts_ms = int(time() * 1000);

    my $msg = {
        rid => sprintf("%08x-%04x-%04x-%04x-%012x",
            int(rand(0xffffffff)), int(rand(0xffff)), int(rand(0xffff)),
            int(rand(0xffff)), int(rand(0xffffffffffff))),
        player_action_timestamp_ms => "$ts_ms",
        activity_interception_type => "DO_NOT_INTERCEPT_BY_DEFAULT"
    };

    my $version = {
        device_id    => $self->{device_id},
        version      => $ts,
        timestamp_ms => "0"
    };

    if ($command_type eq 'update_player_state') {
        my $player_state = $data;

        # CRITICAL FIX: If playable_list is empty, use cached list from Yandex
        # to avoid "Empty playable list is restricted" error
        if (!$player_state->{player_queue}->{playable_list} ||
            @{$player_state->{player_queue}->{playable_list}} == 0) {
            if ($self->{last_playable_list} && @{$self->{last_playable_list}} > 0) {
                $log->debug("Ynison [" . $self->{client}->name() . "]: Using cached playable_list");
                $player_state->{player_queue}->{playable_list} = $self->{last_playable_list};
            } else {
                $log->warn("Ynison [" . $self->{client}->name() . "]: Cannot send update - no playable_list available");
                return;
            }
        }

        # Fix #7: Convert duration_ms and progress_ms to strings before updating version
        if ($player_state->{status}) {
            $player_state->{status}->{duration_ms} = "$player_state->{status}->{duration_ms}" if defined $player_state->{status}->{duration_ms};
            $player_state->{status}->{progress_ms} = "$player_state->{status}->{progress_ms}" if defined $player_state->{status}->{progress_ms};
        }

        # Update version in both status and queue
        $player_state->{status}->{version} = $version;
        $player_state->{player_queue}->{version} = $version;

        $msg->{update_player_state} = {
            player_state => $player_state
        };
    } elsif ($command_type eq 'play') {
        my $dur = $data->{duration_ms} || 0;
        my $prog = $data->{progress_ms} || 0;
        $msg->{update_player_state} = {
            player_state => {
                status => {
                    paused => \0,
                    duration_ms => "$dur",
                    progress_ms => "$prog",
                    playback_speed => 1,
                    version => $version
                },
                player_queue => {
                    current_playable_index => $data->{current_playable_index} || 0,
                    entity_id => "",
                    entity_type => "VARIOUS",
                    playable_list => $data->{playable_list} || [],
                    options => { repeat_mode => "NONE" },
                    entity_context => "BASED_ON_ENTITY_BY_DEFAULT",
                    from_optional => "",
                    version => $version
                }
            }
        };
    } elsif ($command_type eq 'pause') {
        my $dur = $data->{duration_ms} || 0;
        my $prog = $data->{progress_ms} || 0;
        $msg->{update_player_state} = {
            player_state => {
                status => {
                    paused => \1,
                    duration_ms => "$dur",
                    progress_ms => "$prog",
                    playback_speed => 1,
                    version => $version
                },
                player_queue => {
                    current_playable_index => $data->{current_playable_index} || 0,
                    entity_id => "",
                    entity_type => "VARIOUS",
                    playable_list => $data->{playable_list} || [],
                    options => { repeat_mode => "NONE" },
                    entity_context => "BASED_ON_ENTITY_BY_DEFAULT",
                    from_optional => "",
                    version => $version
                }
            }
        };
    } elsif ($command_type eq 'volume') {
        # Volume update: use real device_id in version, strings for version fields
        my $vol_ver_num = int(rand(0x7fffffff));
        my $vol_ts = int(time() * 1000);
        my $volume_version = {
            device_id    => $self->{device_id},
            version      => "$vol_ver_num",
            timestamp_ms => "$vol_ts",
        };
        $msg->{update_volume_info} = {
            device_id => $self->{device_id},
            volume_info => {
                volume => $data->{volume},
                version => $volume_version
            }
        };
    }

    $self->_send_message($msg);
}

sub _get_player_state {
    my $self = shift;
    my $client = $self->{client};
    my $song = $client->playingSong();
    my $paused = ($client->isPaused() || !$client->isPlaying()) ? \1 : \0;

    # Fix #7: Use nanosecond timestamp for version - as string
    my $ts_num = int(time() * 1000000000);
    my $ts = "$ts_num";
    my $version = {
        device_id    => $self->{device_id},
        version      => $ts,
        timestamp_ms => "0"
    };

    my $state = {
        status => {
            duration_ms => "0",
            paused => $paused,
            playback_speed => 1.0,
            progress_ms => "0",
            version => $version
        },
        player_queue => {
            current_playable_index => -1,
            entity_id => "",
            entity_type => "VARIOUS",
            playable_list => [],
            options => { repeat_mode => "NONE" },
            entity_context => "BASED_ON_ENTITY_BY_DEFAULT",
            from_optional => "",
            version => $version
        }
    };

    if ($song && $song->track()) {
        my $url = $song->track()->url();
        if ($url =~ /yandexmusic:\/\/(\d+)/) {
            $state->{player_queue}->{current_playable_index} = 0;
            my $track = {
                playable_id => "$1",
                playable_type => "TRACK",
                from => "direct"
            };

            # Add cover art if available
            my $cover_url = $song->track()->cover();
            if ($cover_url) {
                $cover_url =~ s/%%/200x200/g;  # Replace %% with size
                if ($cover_url !~ m{^https?://}) {
                    $cover_url = "https://" . $cover_url;
                }
                $track->{cover_url_optional} = $cover_url;
            }

            # Add title if available
            if ($song->track()->title()) {
                $track->{title} = $song->track()->title();
            }

            $state->{player_queue}->{playable_list} = [$track];
        }
        my $dur_ms = int(($song->duration() || 0) * 1000);
        my $prog_ms = int((Slim::Player::Source::songTime($client) || 0) * 1000);
        $state->{status}->{duration_ms} = "$dur_ms";
        $state->{status}->{progress_ms} = "$prog_ms";
    }
    return $state;
}

sub _handle_ynison_message {
    my ($self, $msg) = @_;
    my $client = $self->{client};

    # Handle errors
    if (exists $msg->{error}) {
        $log->error("Ynison [" . $client->name() . "]: Error from server: " . $msg->{error}->{message});
        return;
    }

    # Extract player_state from update_full_state if present (server sends both on initial connection)
    my $player_state = $msg->{player_state};
    if (!$player_state && exists $msg->{update_full_state} && exists $msg->{update_full_state}->{player_state}) {
        $player_state = $msg->{update_full_state}->{player_state};
    }

    # Cache the playable_list from Yandex for later use in updates
    if ($player_state && exists $player_state->{player_queue} &&
        exists $player_state->{player_queue}->{playable_list}) {
        my $new_list = $player_state->{player_queue}->{playable_list};
        if (ref($new_list) eq 'ARRAY' && @$new_list > 0) {
            $self->{last_playable_list} = $new_list;
        }
    }

    # Fix #2 & #3: Extract active_device_id once (undefined/absent -> empty string)
    # Empty string won't match device_id, so sync safely skipped for unknown state
    my $active_id = $msg->{active_device_id_optional} // '';

    # Fix #2: Handle commands - only if WE are the active device
    if ($active_id eq $self->{device_id}) {
        if (exists $msg->{put_commands}) {
            foreach my $cmd_obj (@{$msg->{put_commands}}) {
                my $cmd = $cmd_obj->{command} // 'UNKNOWN';
                # Log compact command info
                my $active_dev_name = $self->_get_device_name_by_id($active_id, $msg->{devices});
                $log->info("Ynison [" . $client->name() . "]: Command $cmd from $active_dev_name");

                $self->_execute_lms_command($cmd, $cmd_obj);
            }
        }
    }

    # Process volume changes for our device from devices[] array
    if (exists $msg->{devices}) {
        foreach my $dev (@{$msg->{devices}}) {
            next unless $dev->{info} && $dev->{info}->{device_id} eq $self->{device_id};
            next unless $dev->{volume_info} && defined $dev->{volume_info}->{volume};

            my $volume_float = $dev->{volume_info}->{volume};  # 0.0-1.0
            my $lms_volume = int($volume_float * 100);          # Convert to 0-100
            my $current_volume = $self->{client}->volume() || 0;

            # Only set if changed significantly (avoid feedback loop)
            if (abs($lms_volume - $current_volume) >= 1) {
                $log->info("Ynison [" . $client->name() . "]: Volume update: $volume_float (0.0-1.0) -> $lms_volume (0-100)");

                # Fix #4: Kill old timer before setting new one to prevent accumulation
                Slim::Utils::Timers::killTimers($self, \&_clear_syncing_flag);
                $self->{syncing_from_yandex} = 1;
                Slim::Utils::Timers::setTimer($self, time() + 2, \&_clear_syncing_flag);

                $self->{client}->execute(['mixer', 'volume', $lms_volume]);
            }
            last;  # Found our device, stop searching
        }
    }

    # Process player state sync (using extracted player_state)
    if ($player_state) {
        my $ps = $player_state;

        # Log current track
        if (exists $ps->{player_queue}->{playable_list} && @{$ps->{player_queue}->{playable_list}} > 0) {
            my $idx = $ps->{player_queue}->{current_playable_index} // 0;
            if ($idx >= 0 && $idx < @{$ps->{player_queue}->{playable_list}}) {
                my $track = $ps->{player_queue}->{playable_list}->[$idx];
                my $paused = $ps->{status}->{paused} ? "PAUSED" : "PLAYING";
                # Handle progress_ms and duration_ms as strings (Fix #7)
                my $progress_ms = $ps->{status}->{progress_ms};
                my $duration_ms = $ps->{status}->{duration_ms};
                $progress_ms = 0 if !defined $progress_ms;
                $duration_ms = 0 if !defined $duration_ms;
                # Convert from string if needed
                $progress_ms =~ s/[^\d]//g;
                $duration_ms =~ s/[^\d]//g;
                my $progress = int($progress_ms / 1000);
                my $duration = int($duration_ms / 1000);
                my $track_id = $track->{playable_id};
                my $title = $track->{title} // 'Unknown';

                $log->info("Ynison [" . $client->name() . "]: Track: \"$title\" ($track_id) - $paused $progress/$duration sec");

                # Determine if we should sync based on active device
                if ($active_id eq $self->{device_id}) {
                    # LMS is the active playback device
                    my $current_url = $client->playingSong() ? $client->playingSong()->track()->url() : '';
                    my $new_url = "yandexmusic://$track_id";

                    if ($current_url ne $new_url) {
                        # Track changed - sync new track (NEXT/PREV or redirect from mobile)
                        my $source_dev = $self->_get_device_name_by_id($active_id, $msg->{devices});
                        $log->info("Ynison [" . $client->name() . "]: Active: $source_dev -> syncing new track");
                        $self->_sync_new_track($ps, $idx);
                    } else {
                        # Same track - just sync play/pause/seek
                        $self->_sync_player_commands($ps);
                    }
                } else {
                    # Fix #1: Another device is active - do NOT stop LMS (could be playing non-Yandex source)
                    $log->debug("Ynison [" . $client->name() . "]: Active device is $active_id, not syncing");
                }
            }
        }
    }
}

sub _execute_lms_command {
    my ($self, $command, $data) = @_;
    my $client = $self->{client};

    # Note: $data is the put_command object (only has {command} field), not player state
    # Use actual player state from LMS via _get_player_state() instead
    my $player_state = $self->_get_player_state();

    if ($command eq "PLAY") {
        $client->execute(['play']);
        $self->_send_one_off_command('play', {
            duration_ms => $player_state->{status}->{duration_ms} // 0,
            progress_ms => $player_state->{status}->{progress_ms} // 0,
            current_playable_index => $player_state->{player_queue}->{current_playable_index} // 0,
            playable_list => $player_state->{player_queue}->{playable_list} // []
        });
    }
    elsif ($command eq "PAUSE") {
        $client->execute(['pause', 1]);
        $self->_send_one_off_command('pause', {
            duration_ms => $player_state->{status}->{duration_ms} // 0,
            progress_ms => $player_state->{status}->{progress_ms} // 0,
            current_playable_index => $player_state->{player_queue}->{current_playable_index} // 0,
            playable_list => $player_state->{player_queue}->{playable_list} // []
        });
    }
    elsif ($command eq "STOP") {
        $client->execute(['stop']);
    }
    elsif ($command eq "NEXT") {
        $client->execute(['playlist', 'index', '+1']);
        # Sync will happen when player_state arrives from Yandex
    }
    elsif ($command eq "PREV") {
        $client->execute(['playlist', 'index', '-1']);
        # Sync will happen when player_state arrives from Yandex
    }
    elsif ($command eq "SEEK") {
        my $seek_pos = ($data->{progress_ms} || 0) / 1000;
        $client->execute(['time', $seek_pos]);
        # Sync will happen when player_state arrives from Yandex
    }
    else {
        $log->warn("Ynison [" . $client->name() . "]: Unknown command: $command");
    }
}

sub _get_device_name_by_id {
    my ($self, $device_id, $devices_array) = @_;
    return 'Unknown' unless $device_id && $devices_array;

    foreach my $dev (@$devices_array) {
        if ($dev->{info} && $dev->{info}->{device_id} eq $device_id) {
            my $title = $dev->{info}->{title} // 'Unknown';
            my $type = $dev->{info}->{type} // 'WEB';
            return "$title ($type)";
        }
    }
    return 'Unknown';
}

sub _sync_player_commands {
    my ($self, $player_state) = @_;
    my $client = $self->{client};
    return unless $player_state && $player_state->{status};

    # Fix #4: Kill old timer before setting new one to prevent accumulation
    Slim::Utils::Timers::killTimers($self, \&_clear_syncing_flag);
    # Set flag to prevent update_state() from interfering during sync
    $self->{syncing_from_yandex} = 1;
    Slim::Utils::Timers::setTimer($self, time() + 2, \&_clear_syncing_flag);

    my $status = $player_state->{status};
    my $remote_paused = $status->{paused} ? 1 : 0;

    # Get current LMS state
    my $current_paused = $client->isPaused() ? 1 : 0;
    my $is_playing = $client->isPlaying();

    # Sync pause/play state - but only if state actually differs
    # Do NOT seek - every seek causes stream restart in LMS every 2-3 sec (Yandex push interval)
    # LMS tracks position internally correctly; small drift is normal
    if ($remote_paused && $is_playing) {
        # Remote paused but LMS playing - pause LMS
        $client->execute(['pause', 1]);
    } elsif (!$remote_paused && !$is_playing && $current_paused) {
        # Remote playing but LMS paused - play LMS (not just buffering)
        $client->execute(['play']);
    }
    # No seek sync - prevents stream restart on every Yandex push
}

sub _sync_new_track {
    my ($self, $player_state, $track_idx) = @_;
    my $client = $self->{client};
    return unless $player_state && $player_state->{player_queue};

    my $queue = $player_state->{player_queue};
    return unless $queue->{playable_list} && @{$queue->{playable_list}} > 0;
    return unless $track_idx >= 0 && $track_idx < @{$queue->{playable_list}};

    my $current_track = $queue->{playable_list}->[$track_idx];
    return unless $current_track && $current_track->{playable_id};

    $log->debug("Ynison [" . $client->name() . "]: Syncing playlist with " . scalar(@{$queue->{playable_list}}) . " track(s)");

    # Fix #4: Kill old timer before setting new one to prevent accumulation
    Slim::Utils::Timers::killTimers($self, \&_clear_syncing_flag);
    # Set flag to prevent update_state() from interfering during sync
    $self->{syncing_from_yandex} = 1;
    Slim::Utils::Timers::setTimer($self, time() + 3, \&_clear_syncing_flag);

    # Clear playlist and load ALL tracks from Yandex (not just current one)
    $client->execute(['playlist', 'clear']);

    foreach my $track (@{$queue->{playable_list}}) {
        next unless $track && $track->{playable_id};
        my $track_url = "yandexmusic://" . $track->{playable_id};
        $client->execute(['playlist', 'insert', $track_url]);
    }

    # Set current track position based on current_playable_index
    # LMS uses 0-based indexing, so index directly
    $client->execute(['playlist', 'index', $track_idx]);

    # Start playback if remote device is playing
    if (!$player_state->{status}->{paused}) {
        $client->execute(['play']);
    }
}

sub _send_volume_update {
    my ($self, $volume_float) = @_;
    return unless $self->{is_connected};
    return unless defined $volume_float;

    # Ensure volume is in [0.0, 1.0] range
    $volume_float = 0 if $volume_float < 0;
    $volume_float = 1 if $volume_float > 1;

    my $ts = int(time() * 1000);
    my $vol_ver = int(rand(0x7fffffff));
    my $msg = {
        update_volume_info => {
            device_id => $self->{device_id},
            volume_info => {
                volume => $volume_float,
                version => {
                    device_id    => $self->{device_id},
                    version      => "$vol_ver",
                    timestamp_ms => "$ts",
                }
            }
        },
        rid => '',
        player_action_timestamp_ms => "$ts",
        activity_interception_type => 'DO_NOT_INTERCEPT_BY_DEFAULT',
    };

    $log->debug("Ynison [" . $self->{client}->name() . "]: Sending volume update: $volume_float");
    $self->_send_message($msg);
}

# Fix #4: Helper to clear syncing flag (used by killTimers + setTimer)
sub _clear_syncing_flag {
    my $self = shift;
    $self->{syncing_from_yandex} = 0;
}

1;
