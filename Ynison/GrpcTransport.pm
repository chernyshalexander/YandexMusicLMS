package Plugins::yandex::Ynison::GrpcTransport;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::GrpcTransport - non-blocking native-gRPC transport of the Ynison engine

=head1 DESCRIPTION

A drop-in replacement for L<Plugins::yandex::Ynison::Transport>: the same
constructor and surface (C<new(logger, scheduler)>, C<open(...)>, C<is_open>,
C<send_text($json)>, C<set_heartbeat>, C<set_ping_timeout>, C<close>,
C<fetch_redirect>), but the wire is a native gRPC stream instead of
WebSocket. JSON in, JSON out - the protobuf, HPACK, HTTP/2 and gRPC framing
happen inside (Grpc/Proto, Grpc/HPack, Grpc/H2, Grpc/GrpcFraming), so
Ynison::Client runs unchanged when the C<ynison_transport> pref says C<grpc>.

=head2 The two phases

=over

=item redirect (unary)

C<fetch_redirect> opens a throwaway HTTP/2 connection to
C<GRPC_REDIRECT_HOST> (the WS host/path arguments are ignored - the gRPC
endpoints live in Constants), POSTs an empty RedirectRequest and converts the
RedirectResponse into the WS-gateway hash
C<{host, redirect_ticket, session_id, keep_alive_params}>. A gRPC rejection
(trailers with grpc-status != 0) calls back with no data; grpc-status 16
(UNAUTHENTICATED) maps to HTTP 401 so the Client's token-refresh path keeps
working. The REDIRECT_TIMEOUT guard matches Transport::fetch_one.

=item state stream (bidi)

C<open> dials the redirected host, sends the HEADERS (:method POST, :path
C<GRPC_STATE_METHOD>, :scheme https, :authority, content-type
application/grpc, te trailers) plus the gRPC metadata REBUILT from the
WS-style header pairs the Client passes: the Sec-WebSocket-Protocol JSON
(Message::protocol_header shape) becomes ynison-device-id, ynison-device-info
(base64 of YnisonDeviceInfoHeader, no padding), ynison-session-id and
ynison-redirect-ticket; authorization comes from the Authorization pair.
Sec-WebSocket-Protocol and Origin are dropped - gRPC has no use for them.
C<send_text($json)> encodes PutYnisonStateRequest and frames it as DATA;
inbound DATA frames decode PutYnisonStateResponse and fire C<on_text>.

=back

=head2 Events (WS parity)

    on_open
    on_text($msg)                 decoded JSON-HASH
    on_close($code, $reason)      EOF, GOAWAY, an h2 connection error, a stream
                                  reset, error trailers, or a server-side
                                  healthy end of the stream (1006 parity)
    on_error($reason, $status)    dial/write failures; $status is undefined on
                                  the gRPC path (no HTTP handshake exists)

Error trailers with grpc-status != 0 first deliver
C<{error => {details => {ynison-*}, grpc_code, message}}> through on_text -
exactly the shape the WS gateway sends - and then fire on_close, so the
Client's reconnect policy consumes gRPC errors unchanged. Healthy trailers
(grpc-status 0) on the state stream are a server-initiated end of the RPC
just the same - a long-lived Ynison bidi stream never ends healthily
server-side - so any final data is delivered first and the channel then
closes with on_close(1006, 'stream ended by healthy trailers'): an immediate,
orderly reconnect instead of a stalled passive device waiting for the pong
timeout.

=head2 Deliberate deviations from Transport.pm (the h2 byte stream is not WS)

=over

=item The bootstrap waits for the peer's SETTINGS before any request bytes
(preface+SETTINGS go out at once; HEADERS/body fire on the first settings
event, our SETTINGS ACK riding just before them). The Ynison front refuses
streams created before its SETTINGS with RST_STREAM(REFUSED_STREAM) +
GOAWAY(PROTOCOL_ERROR); grpc-core never trips that gate because it always
waits for the server SETTINGS - the Task 6 live differential proved the same
bytes ACCEPTED when held and REFUSED when sent immediately. The wait is
bounded: a peer that never sends SETTINGS fails the channel with
C<no server SETTINGS within FIRST_FRAME_TIMEOUT seconds>.

=item A NO_ERROR GOAWAY from the front (it opens every connection with
GOAWAY(NO_ERROR, last_stream=1) before serving the request) is a peer-driven
drain, a deliberate deviation from RFC 7540 6.8 that the front requires - not
conformance: the covered stream keeps being served (live evidence: the GOAWAY
NO_ERROR arrives before the response and stream 1 is still served); only an
error-code GOAWAY - or one that skips our live stream - closes the channel as
before.

=item A stalled flush fails the connection instead of dropping the oldest
frame: h2 bytes cannot be dropped mid-stream (a hole corrupts the framing for
everything that follows).

=item MAX_WRITE_QUEUE backpressure refuses new sends instead of dropping
queued bytes, for the same reason.

=back

The heartbeat is an h2 PING per tick with the identical liveness semantics of
Transport::_hb_tick (any inbound traffic counts as alive; a silent pong wait
fails the channel). Connection: one blocking IO::Socket::SSL dial with ALPN
h2 (the documented MVP simplification), then non-blocking I/O through
Slim::Networking::IO::Select with the Transport write-queue discipline
(EAGAIN tolerance, per-job delivery timeout).

=cut

# A drop-in replacement for Ynison::Transport: same constructor and surface,
# but the wire is a native gRPC stream. JSON in, JSON out - protobuf, HPACK,
# HTTP/2 and gRPC framing happen inside. The redirector is a unary POST to
# GRPC_REDIRECT_HOST; the state channel is one long-lived POST stream with
# metadata rebuilt from the Sec-WebSocket-Protocol JSON the Client passes.
#
# Deviations from the WS transport (an h2 byte stream cannot spare bytes):
# a stalled flush fails the connection instead of dropping the oldest frame,
# and MAX_WRITE_QUEUE refuses new sends instead of dropping queued bytes.
# Heartbeat = h2 PING + pong wait, same liveness semantics as _hb_tick.

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo ();
use MIME::Base64 ();
use Slim::Networking::IO::Select ();

use Plugins::yandex::Ynison::Constants ();
use Plugins::yandex::Ynison::Grpc::GrpcFraming ();
use Plugins::yandex::Ynison::Grpc::H2 ();
use Plugins::yandex::Ynison::Grpc::HPack ();
use Plugins::yandex::Ynison::Grpc::Proto ();
use Plugins::yandex::Ynison::Grpc::Schema ();

my $C      = 'Plugins::yandex::Ynison::Constants';
my $SCHEMA = Plugins::yandex::Ynison::Grpc::Schema::MESSAGES();

sub new {
    my ($class, %o) = @_;
    return bless {
        logger    => $o{logger} // sub { },
        scheduler => $o{scheduler},
        handlers  => {},
        headers   => [],
        conn      => undef,
        socket    => undef,
        test_sock => undef,
        h2        => undef,
        stream_id => undef,
        unary     => 0,
        unary_finish => undef,
        unary_msg => undef,
        grpc_buf  => '',
        write_q   => [],
        awaiting_settings => 0,      # the bootstrap holds the request until then
        bootstrap_timer  => undef,   # the SETTINGS deadline handle
        heartbeat => undef,          # scheduler handle
        hb_sec    => 0,
        pong_wait => undef,          # liveness timer handle
        pong_sec  => Plugins::yandex::Ynison::Constants::WS_PING_TIMEOUT_DEFAULT(),
        open      => 0,
        closed    => 0,
        last_rx   => undef,
    }, $class;
}

sub _log { my ($self, $level, $msg) = @_; $self->{logger}->($level, $msg); return }

sub is_open { $_[0]->{open} ? 1 : 0 }

# open(host =>, path =>, port =>, https =>, headers => [[name, value], ...],
#      on_open =>, on_text =>, on_close =>, on_error =>
#      [, socket => $fh for tests] [, unary => 1, unary_finish => $cb — the
#      fetch_redirect internals]). The WS path/path arguments are accepted for
# drop-in parity; the gRPC method paths come from Constants.
sub open {
    my ($self, %o) = @_;
    $self->{handlers} = { map { $_ => $o{$_} } qw(on_open on_text on_close on_error) };
    $self->{headers}  = $o{headers} || [];
    $self->{conn}     = { host => $o{host}, path => $o{path}, port => $o{port} // $C->YNISON_PORT(), https => $o{https} // 1 };
    $self->{test_sock} = $o{socket};
    $self->{unary}    = $o{unary} ? 1 : 0;
    $self->{unary_finish} = $o{unary_finish};

    my $fh;
    unless ($self->{test_sock}) {
        # Documented MVP dial (controller decision): one short BLOCKING TLS
        # handshake with ALPN h2 inside the event callback, like the legacy
        # engine; the I/O below is non-blocking as usual.
        $fh = eval {
            require IO::Socket::SSL;
            IO::Socket::SSL->new(
                PeerHost           => $self->{conn}{host},
                PeerPort           => $self->{conn}{port},
                SSL_alpn_protocols => [ $C->GRPC_ALPN() ],
                Timeout            => $C->WS_CONNECT_TIMEOUT(),
            );
        };
        if ($@ || !$fh) {
            my $why = $@ ne '' ? $@ : ($! || 'unknown error');
            $self->_fail("connect failed: $why");
            return $self;
        }
        $self->_log('info', "grpc: blocking TLS dial to $self->{conn}{host}:$self->{conn}{port} (MVP)");
    }
    else {
        $fh = $self->{test_sock};
    }
    return $self->_on_connect($fh);
}

sub _on_connect {
    my ($self, $fh) = @_;
    unless ($fh && (!$fh->can('opened') || $fh->opened)) {
        $self->_fail('no socket after connect');
        return;
    }
    $fh->blocking(0) if $fh->can('blocking');
    $self->{socket}    = $fh;
    $self->{write_q}   = [];
    $self->{grpc_buf}  = '';
    $self->{unary_msg} = undef;
    $self->{closed}    = 0;

    my $c = Plugins::yandex::Ynison::Grpc::H2->new;
    $self->{h2} = $c;
    # The bootstrap waits for the peer's SETTINGS before any request bytes: the
    # Ynison front refuses streams that arrive before its SETTINGS with
    # RST_STREAM(REFUSED_STREAM) + GOAWAY(PROTOCOL_ERROR) on stream 1. grpc-core
    # never trips this gate - it sends HEADERS only after the server's SETTINGS
    # have arrived (Task 6 differential: same bytes later = ACCEPTED, same
    # bytes immediately = REFUSED). _send_request below fires on the settings
    # event; the SETTINGS ACK rides out just before our HEADERS, exactly the
    # accepted grpcio choreography.
    $self->{awaiting_settings} = 1;
    $c->pause_after_settings(1);   # split a SETTINGS+response flight on settings
    push @{ $self->{write_q} }, { data => $c->initial_bytes, sent_at => time(), attempts => 0 };
    # The bootstrap waits with a deadline: a peer that completes the TLS dial
    # but never sends SETTINGS must not leave the state channel silent forever
    # (on_open/the Client's first-frame watchdog only arm once the request
    # exists). Fail the channel by name when the deadline passes.
    if ($self->{scheduler}) {
        $self->{bootstrap_timer} = $self->{scheduler}{set}->($C->FIRST_FRAME_TIMEOUT(), sub {
            return unless $self->{awaiting_settings} && $self->{open};
            $self->_fail('no server SETTINGS within ' . $C->FIRST_FRAME_TIMEOUT() . 's');
        });
    }
    Slim::Networking::IO::Select::addWrite($fh, sub { $self->_on_writable(@_) });
    Slim::Networking::IO::Select::addRead($fh, sub { $self->_on_readable(@_) });
    $self->{open} = 1;
    return;
}

# The request stream: fired when the peer's SETTINGS arrive (the bootstrap
# holds every request until then - see _on_connect). Opens the stream, sends
# the HEADERS block and, for the unary redirect, the empty body with END_STREAM.
# The liveness heartbeat arms here too: the Client calls set_heartbeat before
# open, so it stays dormant until the request exists and no PING precedes our
# HEADERS. An external set_heartbeat between open and the server SETTINGS
# would still arm immediately (the transport is already open) and PING first.
sub _send_request {
    my ($self) = @_;
    my $c  = $self->{h2};
    my $st = $c->open_stream;
    return $self->_fail("h2 stream open failed: $st->{error}") unless $st->{ok};
    $self->{stream_id} = $st->{stream_id};
    my ($method, $authority) = $self->{unary}
        ? ($C->GRPC_REDIRECT_METHOD(), $C->GRPC_REDIRECT_HOST())
        : ($C->GRPC_STATE_METHOD(), $self->_authority);
    my $hs = $c->send_headers($self->{stream_id}, $self->_grpc_headers($method, $authority), 0);
    return $self->_fail("h2 HEADERS failed: $hs->{error}") unless $hs->{ok};
    if ($self->{unary}) {    # the redirect body: one empty RedirectRequest
        my $ds = $c->send_data($self->{stream_id},
            Plugins::yandex::Ynison::Grpc::GrpcFraming::encode_message(''), 1);
        return $self->_fail("h2 DATA failed: $ds->{error}") unless $ds->{ok};
    }
    $self->_queue_write;
    $self->{heartbeat} = $self->{scheduler}{set}->($self->{hb_sec}, sub { $self->_hb_tick })
        if $self->{hb_sec} && $self->{scheduler} && !$self->{heartbeat};
    if ($self->{unary}) {
        $self->_log('info', "grpc redirect request sent to $authority");
        return;
    }
    $self->_log('info', "grpc state stream open: $authority $method");
    $self->{handlers}{on_open}->($self) if $self->{handlers}{on_open};
    return;
}

# The request header list: the gRPC pseudo-headers plus the metadata rebuilt
# from the WS-style pairs the Client passes.
sub _grpc_headers {
    my ($self, $method, $authority) = @_;
    my @hdr = (
        [ ':method',      'POST' ],
        [ ':path',        $method ],
        [ ':scheme',      'https' ],
        [ ':authority',   $authority ],
        [ 'content-type', 'application/grpc' ],
        [ 'te',           'trailers' ],
    );
    my $meta = $self->_grpc_metadata($self->{headers});
    push @hdr, [ $_, $meta->{$_} ] for sort keys %$meta;
    return \@hdr;
}

# Sec-WebSocket-Protocol carries 'Bearer, v2, {JSON}' (Message::protocol_header
# shape); gRPC speaks lowercase metadata instead. The Authorization pair rides
# as-is; Sec-WebSocket-Protocol and Origin are dropped.
sub _grpc_metadata {
    my ($self, $pairs) = @_;
    my ($swsp, $auth);
    for my $p (@$pairs) {
        my ($n, $v) = @$p;
        $swsp = $v if $n eq 'Sec-WebSocket-Protocol' && !defined $swsp;
        $auth = $v if $n eq 'Authorization' && !defined $auth;
    }
    my %meta;
    my $json;
    if (defined $swsp && $swsp =~ /(\{.*\})/s) {
        $json = eval { JSON::XS::VersionOneAndTwo::decode_json($1) };
        $self->_log('warn', 'grpc: undecodable Sec-WebSocket-Protocol JSON') if ref $json ne 'HASH';
    }
    if (ref $json eq 'HASH') {
        $meta{'ynison-device-id'} = "$json->{'Ynison-Device-Id'}"
            if defined $json->{'Ynison-Device-Id'};
        my $info = eval { JSON::XS::VersionOneAndTwo::decode_json($json->{'Ynison-Device-Info'} // '') };
        if (ref $info eq 'HASH') {
            my $bytes = eval {
                Plugins::yandex::Ynison::Grpc::Proto::encode($SCHEMA, 'YnisonDeviceInfoHeader', {
                    type        => $info->{type} // 'WEB',   # a name or a number
                    app_name    => $info->{app_name} // $C->APP_NAME(),
                    app_version => $info->{app_version} // $C->APP_VERSION(),
                });
            };
            if (defined $bytes) {
                my $b64 = MIME::Base64::encode_base64($bytes, '');
                $b64 =~ s/=+\z//;                        # base64, standard alphabet, no padding
                $meta{'ynison-device-info'} = $b64;
            }
        }
        $meta{'ynison-session-id'}      = "$json->{'Ynison-Session-Id'}"
            if defined $json->{'Ynison-Session-Id'};
        $meta{'ynison-redirect-ticket'} = "$json->{'Ynison-Redirect-Ticket'}"
            if defined $json->{'Ynison-Redirect-Ticket'};
        $auth = $json->{authorization} if !defined $auth && defined $json->{authorization};
    }
    $meta{authorization} = $auth if defined $auth;
    return \%meta;
}

sub _authority {
    my ($self) = @_;
    return $self->{conn}{host} if !$self->{conn}{port} || $self->{conn}{port} == 443;
    return "$self->{conn}{host}:$self->{conn}{port}";
}

sub _fail {    # on_error($reason, $status) parity with the WS transport
    my ($self, $reason, $status) = @_;
    return if $self->{closed};
    $self->{closed} = 1;
    $self->_teardown;
    my $cb = $self->{handlers}{on_error};
    $cb->($self, $reason, $status) if $cb;
    return;
}

# GOAWAY, h2 connection errors, stream resets and gRPC error trailers close
# the channel like a vanished WS peer: on_close(1006, reason).
sub _fail_close {
    my ($self, $code, $reason) = @_;
    return if $self->{closed};
    $self->{closed} = 1;
    $self->_teardown;
    my $cb = $self->{handlers}{on_close};
    $cb->($self, $code, $reason) if $cb;
    return;
}

sub _teardown {
    my ($self) = @_;
    $self->{open} = 0;
    if (my $h = $self->{heartbeat}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
        $self->{heartbeat} = undef;
    }
    if (my $h = delete $self->{pong_wait}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
    }
    if (my $h = delete $self->{bootstrap_timer}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
    }
    if (my $fh = delete $self->{socket}) {
        Slim::Networking::IO::Select::removeRead($fh);
        Slim::Networking::IO::Select::removeWrite($fh);
        eval { $fh->close } if $fh->can('close');
    }
    $self->{h2}        = undef;
    $self->{test_sock} = undef;
    $self->{write_q}   = [];
    $self->{grpc_buf}  = '';
    $self->{awaiting_settings} = 0;
    return;
}

# close(): local close; on_close is deliberately not fired — the client knows
# about its own close, and a callback here would feed the reconnect loop.
sub close {
    my ($self) = @_;
    $self->{closed} = 1;
    $self->_teardown;
    return;
}

# set_heartbeat($seconds): an h2 PING every $seconds while open.
sub set_heartbeat {
    my ($self, $sec) = @_;
    if (my $h = delete $self->{heartbeat}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
    }
    return unless $sec && $sec > 0 && $self->{scheduler};
    $self->{hb_sec} = $sec;
    $self->{heartbeat} = $self->{scheduler}{set}->($sec, sub { $self->_hb_tick }) if $self->{open};
    return;
}

sub set_ping_timeout { $_[0]->{pong_sec} = $_[1] if $_[1] && $_[1] > 0; return }

sub _hb_tick {
    my ($self) = @_;
    return unless $self->{open};
    $self->send_ping;
    $self->_log('info', sprintf('heartbeat: ping sent; last inbound frame %s s ago; pong_sec=%s sched=%s',
        defined $self->{last_rx} ? int(time() - $self->{last_rx}) : -1,
        defined $self->{pong_sec} ? $self->{pong_sec} : 'UNDEF',
        $self->{scheduler} ? 'yes' : 'NO'));
    # Liveness: a ping must be answered (pong or any frame) within pong_sec,
    # or the channel is half-open and the server already dropped us (plan 3.1).
    if (my $s = $self->{scheduler}) {
        $self->{pong_wait} = $s->{set}->($self->{pong_sec}, sub {
            $self->_log('info', 'liveness timer fired; open=' . ($self->{open} ? 1 : 0));
            return unless $self->{open};
            $self->_fail('no pong within ' . $self->{pong_sec} . 's');
        });
    }
    $self->{heartbeat} = $self->{scheduler}{set}->($self->{hb_sec}, sub { $self->_hb_tick });
    return;
}

sub _alive {
    my ($self) = @_;
    if (my $h = delete $self->{pong_wait}) {
        $self->{scheduler}{kill}->($h) if $self->{scheduler};
    }
    return;
}

sub send_ping {
    my ($self) = @_;
    return unless $self->{open} && $self->{h2};
    my $st = $self->{h2}->send_ping('ynison');
    $self->_queue_write if $st->{ok};
    return;
}

# send_text($json) -> bool. JSON -> PutYnisonStateRequest -> one gRPC message
# of DATA (the stream stays open). Guards mirror the WS transport: the size
# cap before encoding, the write-queue cap before queueing.
sub send_text {
    my ($self, $json) = @_;
    return 0 unless $self->{open};
    use bytes;
    if (length($json) > $C->MAX_FRAME_SIZE_OUT()) {
        $self->_log('warn', 'outgoing frame above MAX_FRAME_SIZE_OUT, refused');
        return 0;
    }
    if (@{ $self->{write_q} } >= $C->MAX_WRITE_QUEUE()) {
        # Backpressure instead of the WS drop-oldest: h2 bytes cannot be
        # dropped mid-stream (see the POD deviations).
        $self->_log('warn', 'write queue over MAX_WRITE_QUEUE, refusing the message');
        return 0;
    }
    my $hash = eval { JSON::XS::VersionOneAndTwo::decode_json($json) };
    if ($@ || ref $hash ne 'HASH') {
        $self->_log('warn', 'send_text: not a JSON object, refused');
        return 0;
    }
    my $proto = eval { Plugins::yandex::Ynison::Grpc::Proto::encode($SCHEMA, 'PutYnisonStateRequest', $hash) };
    if ($@ || !defined $proto) {
        $self->_log('warn', 'send_text: protobuf encode failed' . (length $@ ? ": $@" : ''));
        return 0;
    }
    my $st = $self->{h2}->send_data($self->{stream_id},
        Plugins::yandex::Ynison::Grpc::GrpcFraming::encode_message($proto), 0);
    if (!$st->{ok}) {
        $self->_log('warn', "send_text: h2 refused the DATA: $st->{error}");
        return 0;
    }
    $self->_queue_write;
    return 1;
}

# Drain whatever the h2 engine has queued (frames for sends, SETTINGS ACKs,
# WINDOW_UPDATEs, PING ACKs) into the write queue.
sub _queue_write {
    my ($self) = @_;
    return unless $self->{h2};
    my $out = $self->{h2}->take_output;
    return unless length $out;
    push @{ $self->{write_q} }, { data => $out, sent_at => time(), attempts => 0 };
    Slim::Networking::IO::Select::addWrite($self->{socket}, sub { $self->_on_writable(@_) })
        if $self->{socket};
    return;
}

sub _on_writable {
    my ($self, $fh) = @_;
    return unless @{ $self->{write_q} };
    my $job  = $self->{write_q}[0];
    my $data = $job->{data};

    if (time() - $job->{sent_at} > $C->WS_CONNECT_TIMEOUT()) {
        # The WS transport would drop the oldest frame here; h2 bytes cannot
        # be dropped mid-stream, so a stalled flush fails the connection.
        $self->_log('warn', 'frame delivery timeout: the h2 byte stream cannot spare its bytes');
        $self->_fail('frame delivery timeout');
        return;
    }
    my $n = $fh->syswrite($data);
    if (!defined $n) {
        $self->_log('info', sprintf('write: %s (queued %d)', $!, scalar @{ $self->{write_q} }))
            if $!{EAGAIN} || $!{EWOULDBLOCK};
        return if $!{EAGAIN} || $!{EWOULDBLOCK};
        $self->_fail("write error: $!");
        return;
    }
    if ($n == length $data) {
        shift @{ $self->{write_q} };
        Slim::Networking::IO::Select::removeWrite($fh) unless @{ $self->{write_q} };
    }
    else {
        $job->{data} = substr($data, $n);              # partial write: keep going,
    }                                                  # the delivery timeout protects us
    return;
}

sub _on_readable {
    my ($self, $fh) = @_;
    # method call: the fake sockets in tests are not IO::Handles
    my $n = $fh->sysread(my $buf, 65_536);
    if (!defined $n) {
        return if $!{EAGAIN} || $!{EWOULDBLOCK};
        $self->_fail("read error: $!");
        return;
    }
    if ($n == 0) {
        my $cb = $self->{handlers}{on_close};
        $self->{closed} = 1;
        $self->_teardown;
        $cb->($self, 1006, 'connection EOF') if $cb;
        return;
    }
    $self->{last_rx} = time();
    $self->_alive;
    while (1) {    # the bootstrap pause may split a flight: after the request
                   # opens on the settings event, resume the buffered rest
        my @ev = $self->{h2}->feed($buf);
        last unless @ev;
        for my $ev (@ev) {
            last if $self->{closed};
            $self->_on_h2_event($ev);
        }
        last if $self->{closed};
        $buf = '';    # the next pass parses what stayed in the h2's buffer
    }
    return if $self->{closed};
    $self->_queue_write;     # SETTINGS ACKs, WINDOW_UPDATEs, PING ACKs
    return;
}

sub _on_h2_event {
    my ($self, $ev) = @_;
    my $type = $ev->{type};
    return $self->_on_headers($ev) if $type eq 'headers';
    return $self->_on_data($ev)    if $type eq 'data';
    if ($type eq 'settings') {
        if (delete $self->{awaiting_settings}) {
            if (my $h = delete $self->{bootstrap_timer}) {
                $self->{scheduler}{kill}->($h) if $self->{scheduler};
            }
            $self->_send_request;    # the request exists before the buffered rest parses
            $self->{h2}->pause_after_settings(0) if $self->{h2};
        }
        return;
    }
    if ($type eq 'goaway') {
        # The front's NO_ERROR GOAWAY covering our stream is a peer-driven
        # drain: a deliberate deviation from RFC 7540 6.8 (which forbids
        # streams after a GOAWAY; the front nonetheless serves the covered
        # stream), so the request keeps being served and no NEW stream starts.
        if ($ev->{draining}) {
            # Wording note: LMS logs carry no level field, and viewers color by
            # substring - spelling the code as "NO_ERROR" made every healthy
            # connection look like an error. "code 0" says the same thing.
            $self->_log('info', "grpc: connection draining"
                . " (GOAWAY code 0, last stream $ev->{last_stream_id}): the open"
                . " stream keeps being served");
            return;
        }
        my $debug = defined $ev->{debug} && length $ev->{debug} ? ": $ev->{debug}" : '';
        return $self->_fail_close(1006, "server sent GOAWAY (" . ($ev->{error} // '?') . ")$debug");
    }
    if ($type eq 'rst_stream') {
        return $self->_fail_close(1006, "stream reset ($ev->{error})");
    }
    if ($type eq 'error') {
        return $self->_fail_close(1006, $ev->{reason});
    }
    # settings_ack / ping / ping_ack / window_update: the h2 engine answered
    # what needed answering; the read path marked liveness.
    return;
}

sub _on_headers {
    my ($self, $ev) = @_;
    my ($status, $has_grpc_status) = (undef, 0);
    for my $p (@{ $ev->{headers} }) {
        $status = $p->[1] if $p->[0] eq ':status' && !defined $status;
        $has_grpc_status = 1 if $p->[0] eq 'grpc-status';
    }
    # gRPC "Trailers-Only": the final status may ride the first block.
    return $self->_on_trailers($ev->{headers}) if $ev->{trailer} || $has_grpc_status;
    $self->_log('warn', "grpc: response status $status (a grpc-status trailer should follow)")
        if defined $status && $status != 200;
    return;
}

sub _on_data {
    my ($self, $ev) = @_;
    $self->{grpc_buf} .= $ev->{data};
    my @msgs = eval { Plugins::yandex::Ynison::Grpc::GrpcFraming::parse_messages(\$self->{grpc_buf}) };
    if ($@) {
        $self->_log('warn', 'grpc: frame parse failed (a compressed message?)');
        return;
    }
    $self->_on_grpc_message($_) for @msgs;
    return;
}

sub _on_grpc_message {
    my ($self, $msg) = @_;
    if ($self->{unary}) {
        $self->{unary_msg} = $msg;      # a unary RPC carries one message
        return;
    }
    my $hash = eval { Plugins::yandex::Ynison::Grpc::Proto::decode($SCHEMA, 'PutYnisonStateResponse', $msg) };
    if ($@ || ref $hash ne 'HASH') {
        $self->_log('warn', 'grpc: skipping an undecodable state message');
        return;
    }
    my $cb = $self->{handlers}{on_text};
    $cb->($self, $hash) if $cb;
    return;
}

sub _on_trailers {
    my ($self, $list) = @_;
    my $st = Plugins::yandex::Ynison::Grpc::GrpcFraming::trailer_status($list);
    if ($self->{unary}) {
        my $finish = delete $self->{unary_finish};
        $self->close;
        return unless $finish;
        if (!$st) {
            $self->_log('warn', 'grpc redirect: trailers without grpc-status');
            $finish->($self, undef, undef);
            return;
        }
        if ($st->{ok}) {
            my $data = eval {
                Plugins::yandex::Ynison::Grpc::Proto::decode($SCHEMA, 'RedirectResponse', $self->{unary_msg} // '');
            };
            if ($@ || ref $data ne 'HASH') {
                $self->_log('warn', 'grpc redirect: undecodable RedirectResponse');
                $finish->($self, undef, undef);
                return;
            }
            $self->_log('info', "grpc redirect: host=$data->{host} session=$data->{session_id}");
            $finish->($self, $data, undef);
            return;
        }
        $self->_log('warn', "grpc redirect rejected: status $st->{code} $st->{message}");
        # UNAUTHENTICATED maps to HTTP 401 so the Client's refresh path works.
        $finish->($self, undef, $st->{code} == 16 ? 401 : undef);
        return;
    }
    # The state channel.
    if (!$st) {
        return $self->_fail_close(1006, 'trailers without grpc-status');
    }
    if ($st->{ok}) {
        # A long-lived Ynison bidi stream never ends healthily server-side:
        # healthy trailers mean the RPC is over (half-closed remote), so they
        # are a restart directive, not a quiet continuation. WS parity: any
        # final data was delivered before the trailers; now hand the Client an
        # immediate, orderly reconnect instead of stalling a passive device
        # until the pong timeout.
        return $self->_fail_close(1006, 'stream ended by healthy trailers');
    }
    my $err = Plugins::yandex::Ynison::Grpc::GrpcFraming::gateway_error($list);
    my $reason = "grpc status $st->{code}" . (length $st->{message} ? ": $st->{message}" : '');
    my $cb = $self->{handlers}{on_text};
    $cb->($self, $err) if $cb && $err;      # the Client's reconnect policy consumes the JSON...
    return $self->_fail_close(1006, $reason);    # ...then the 1006 close parity
}

# fetch_redirect(host, path, headers, cb, %o): cb->($transport, $data|undef,
# $status|undef) — the Transport callback shape. The WS host/path arguments
# are ignored: the gRPC redirector is GRPC_REDIRECT_HOST + GRPC_REDIRECT_METHOD.
# A throwaway h2 connection on this same instance (the fetch_one pattern).
sub fetch_redirect {
    my ($self, $host, $path, $headers, $cb, %o) = @_;
    my $done   = 0;
    my $finish = sub { $done ||= 1; $cb->(@_) };
    $self->{scheduler}{set}->($C->REDIRECT_TIMEOUT(), sub {
        return if $done;
        $finish->($self, undef, undef);
        $self->close;
    }) if $self->{scheduler};
    $self->open(
        host    => $C->GRPC_REDIRECT_HOST(),
        path    => $C->GRPC_REDIRECT_METHOD(),
        port    => $o{port} // $C->YNISON_PORT(),
        https   => $o{https} // 1,
        headers => $headers,
        socket  => $o{socket},
        unary   => 1,
        unary_finish => $finish,
        on_close => sub {
            my ($t) = @_;
            return if $done;
            $done = 1;
            $finish->($t, undef, undef);
        },
        on_error => sub {
            my ($t, $reason, $status) = @_;
            return if $done;
            $done = 1;
            $finish->($t, undef, $status);
        },
    );
    return $self;
}

1;
