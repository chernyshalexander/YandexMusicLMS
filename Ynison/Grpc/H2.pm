package Plugins::yandex::Ynison::Grpc::H2;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Grpc::H2 - minimal HTTP/2 client engine (RFC 7540) for the gRPC transport

=head1 DESCRIPTION

One connection object for one gRPC connection: the client preface, our
SETTINGS, the HPACK decode context, flow-control state and AT MOST ONE active
RPC stream (the Ynison usage). There is no socket and no timer in here - the
transport owns I/O and clocks: it syswrites what take_output() accumulates
and sysreads into feed(). Tests drive the byte pump directly.

    my $c = Plugins::yandex::Ynison::Grpc::H2->new;
    syswrite($sock, $c->initial_bytes);          # preface + SETTINGS + WINDOW_UPDATE(+1MB)
    my $st = $c->open_stream;                    # { ok => 1, stream_id => 1 }
    $c->send_headers($id, [[name, value], ...], $end_stream);
    my $st = $c->send_data($id, $bytes, $end_stream);  # { ok, sent, queued, end_stream_sent }
    $c->send_ping($octets);                      # -> { ok => 1 }
    $c->send_rst_stream($id, 'CANCEL');
    $c->send_goaway('NO_ERROR', 'bye');
    my $out = $c->take_output;                   # every frame queued since the last call
    my @events = $c->feed($bytes_in);            # inbound byte pump -> typed events

Every outbound op returns a status hashref: { ok => 1, ... } on success or
{ ok => 0, error => 'h2: ...' } when the state machine, the peer's windows or
a dead connection says no (the reason is always named). H2 NEVER dies across
the API boundary for protocol situations; dies are reserved for caller
argument mistakes, exactly like the Proto.pm split (encode strictness vs
network input wrapped in eval).

Events from feed() are plain hashrefs with a 'type' key:

    { type => 'settings', peer => { header_table_size, enable_push,
                                    max_concurrent_streams, initial_window_size,
                                    max_frame_size, max_header_list_size } }
    { type => 'settings_ack' }
    { type => 'ping',      opaque => 8-octets }     # the ACK is queued automatically
    { type => 'ping_ack',  opaque => 8-octets }
    { type => 'headers',   stream_id, headers => [[n, v], ...],
                           end_stream => 0|1, trailer => 0|1 }   # trailer = a later block
    { type => 'data',      stream_id, data => octets, end_stream => 0|1 }
    { type => 'window_update', stream_id, delta }   # 0 = the connection level
    { type => 'rst_stream',    stream_id, code, error }          # error = the code name
    { type => 'goaway',    last_stream_id, code, error, debug }
    { type => 'error',     level => 'connection'|'stream', error => the code name,
                           code => number, reason => 'h2: ...' }

A connection-level error (or a received GOAWAY) ends the connection: is_dead()
turns true, dead_reason() explains it, feed() yields nothing further and every
outbound op answers { ok => 0, error => 'h2: no connection: ...' }.

Flow control, per the plan: we advertise SETTINGS_INITIAL_WINDOW_SIZE 1MB and
open the connection window by +1MB (the WINDOW_UPDATE in initial_bytes); every
inbound DATA is replenished immediately on both the connection and the stream.
Outbound, the peer's windows gate us: DATA beyond their connection or stream
window queues up and releases on WINDOW_UPDATE, split into frames no larger
than the peer's SETTINGS_MAX_FRAME_SIZE (16384 until their SETTINGS arrive;
the split also defers the END_STREAM frame behind the queue). Our own
SETTINGS_MAX_FRAME_SIZE is 4MB (the h2 legal ceiling is 16777215) so a whole
Ynison state message travels as one frame.

Header blocks ride on L<Plugins::yandex::Ynison::Grpc::HPack>: outbound lists
are encoded statelessly (literal-without-indexing; names must be lowercase,
HTTP/2's rule) and must fit ONE frame under the peer's max frame size - a
bigger block is refused by name, the MVP emits no CONTINUATION frames;
inbound HEADERS/CONTINUATION payloads feed the one decoder,
END_HEADERS finishes it. The decoder is created with OUR advertised
SETTINGS_HEADER_TABLE_SIZE (that is what bounds the tables peers use to
encode to us; their own setting only concerns our stateless encoder). A
decoder that died is abandoned with the connection - HPACK errors map to a
COMPRESSION_ERROR connection error and there is no recovery. Header chains
must arrive unbroken: a frame interlaced into an open block, or a
CONTINUATION without a preceding HEADERS, is a connection protocol error
(RFC 7540 4.3). PADDED frames and PUSH_PROMISE are likewise refused with a
named protocol error (the Yandex gRPC front sends neither).

Implemented frames (encode + decode): SETTINGS, HEADERS, CONTINUATION, DATA,
WINDOW_UPDATE, PING, RST_STREAM, GOAWAY. Unknown frame types and PRIORITY are
skipped length-bounded per RFC 7540. Frames that must carry a stream id never
appear with id 0, and vice versa - violations are connection protocol errors.
Stream states run idle -> open -> half-closed (local by our END_STREAM,
remote by the peer's END_STREAM on DATA or HEADERS) -> closed; a peer
RST_STREAM, or one of ours, closes at once, and frames in flight for a
stream we reset are silently ignored.

Only core Perl plus HPack; nothing loads Slim here.

=cut

# Minimal HTTP/2 client engine (RFC 7540) for the gRPC transport: preface +
# SETTINGS, frame encode/decode, one active stream's state machine, flow
# control, HPACK behind the H2 boundary. No socket, no timers - the transport
# syswrites take_output() and sysreads into feed().
#
#   initial_bytes() -> preface + SETTINGS + WINDOW_UPDATE(+1MB)
#   open_stream / send_headers / send_data / send_ping / send_rst_stream /
#   send_goaway     -> { ok => 1, ... } | { ok => 0, error => 'h2: ...' }
#   take_output()   -> all frame bytes queued since the last call
#   feed(bytes)     -> list of typed events (hashrefs with a 'type' key)
#   is_dead / dead_reason
#
# Connection-level errors (bad frames, HPACK failures, GOAWAY) end the
# connection; ops on it answer ok => 0 with a named reason. Nothing dies
# across the API boundary except caller argument mistakes. An outbound header
# block bigger than the peer's max frame size is refused (no CONTINUATION in
# the MVP); an empty inbound DATA frame gets no WINDOW_UPDATE (a 0 increment
# would be a protocol error).

use strict;
use warnings;

use Exporter ();

use Plugins::yandex::Ynison::Grpc::HPack ();

our @ISA         = ('Exporter');
our @EXPORT_OK   = qw(error_code);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

# ---- wire constants (RFC 7540) ------------------------------------------------

my $PREFACE = 'PRI * HTTP/2.0' . "\x0D\x0A\x0D\x0A" . 'SM' . "\x0D\x0A\x0D\x0A";

my $DEFAULT_MAX_FRAME = 16384;       # h2 default until the peer's SETTINGS arrive
my $DEFAULT_WINDOW    = 65535;       # h2 default for both flow-control windows
my $OUR_HEADER_TABLE  = 4096;        # SETTINGS_HEADER_TABLE_SIZE we advertise
my $OUR_WINDOW        = 1048576;    # 1MB: our SETTINGS_INITIAL_WINDOW_SIZE + the connection bump
my $OUR_MAX_FRAME     = 4194304;    # 4MB so a whole Ynison state message fits one frame
my $WINDOW_MAX        = 2147483647; # 2^31-1: flow-control windows must never exceed this
my $MAX_FRAME_CEILING = 16777215;    # the largest SETTINGS_MAX_FRAME_SIZE a peer may send

use constant {
    FLAG_END_STREAM  => 0x1,    # DATA, HEADERS
    FLAG_ACK         => 0x1,    # SETTINGS, PING
    FLAG_END_HEADERS => 0x4,    # HEADERS, CONTINUATION
    FLAG_PADDED      => 0x8,    # refused: the Yandex front never pads
    FLAG_PRIORITY    => 0x20,   # refused on HEADERS, ditto
};

my %FRAME = (
    DATA => 0x0, HEADERS => 0x1, PRIORITY => 0x2, RST_STREAM => 0x3, SETTINGS => 0x4,
    PUSH_PROMISE => 0x5, PING => 0x6, GOAWAY => 0x7, WINDOW_UPDATE => 0x8, CONTINUATION => 0x9,
);
my %FRAME_BY_ID = reverse %FRAME;

my %ERROR = (
    NO_ERROR => 0, PROTOCOL_ERROR => 1, INTERNAL_ERROR => 2, FLOW_CONTROL_ERROR => 3,
    SETTINGS_TIMEOUT => 4, STREAM_CLOSED => 5, FRAME_SIZE_ERROR => 6, REFUSED_STREAM => 7,
    CANCEL => 8, COMPRESSION_ERROR => 9, CONNECT_ERROR => 10, ENHANCE_YOUR_CALM => 11,
    INADEQUATE_SECURITY => 12, HTTP_1_1_REQUIRED => 13,
);
my %ERROR_BY_ID = reverse %ERROR;

sub error_code {    # ('CANCEL' | 8) -> the numeric code; the mirror of $event->{code}
    my ($code) = @_;
    return $ERROR{$code} if !ref $code && exists $ERROR{$code};
    return 0 + $code if !ref $code && "$code" =~ /^\d+$/;
    die "h2: error code wants a name (NO_ERROR .. HTTP_1_1_REQUIRED) or a number\n";
}

# ---- public -----------------------------------------------------------------

sub new {
    my ($class) = @_;
    return bless {
        _out          => '',                 # outbound frame bytes awaiting take_output
        _in           => '',                 # inbound bytes awaiting a whole frame
        _tx_max_frame => $DEFAULT_MAX_FRAME, # the peer's SETTINGS_MAX_FRAME_SIZE
        _tx_win_conn  => $DEFAULT_WINDOW,    # only WINDOW_UPDATE frames change this
        _tx_win_init  => $DEFAULT_WINDOW,    # the peer's SETTINGS_INITIAL_WINDOW_SIZE
        _rx_win_conn  => $DEFAULT_WINDOW + $OUR_WINDOW,    # initial_bytes() emits the matching bump
        _decoder      => Plugins::yandex::Ynison::Grpc::HPack->new_decoder($OUR_HEADER_TABLE),
        _hdr_block    => undef,              # { stream => id } while a HEADERS chain is open
        _stream       => undef,              # the one stream record, once opened
        _next_sid     => 1,
        _last_sid     => 0,                  # the highest id we opened (for GOAWAY)
        _dead         => undef,              # undef | why the connection ended
    }, $class;
}

sub initial_bytes {    # call once, before anything else: the bytes to syswrite first
    my ($c) = @_;
    return $PREFACE
        . _frame($FRAME{SETTINGS}, 0, 0,
                 pack('nN', 1, $OUR_HEADER_TABLE)    # SETTINGS_HEADER_TABLE_SIZE
               . pack('nN', 4, $OUR_WINDOW)          # SETTINGS_INITIAL_WINDOW_SIZE: 1MB streams
               . pack('nN', 5, $OUR_MAX_FRAME))      # SETTINGS_MAX_FRAME_SIZE: 4MB (ceiling 16777215)
        . _frame($FRAME{WINDOW_UPDATE}, 0, 0, pack('N', $OUR_WINDOW));  # conn window +1MB
}

sub open_stream {
    my ($c) = @_;
    if (my $dead = _dead_err($c)) { return _err($dead) }
    if (my $live = _live_stream($c)) {
        return _err("h2: stream $live->{id} is still active (one stream at a time)\n");
    }
    my $id = $c->{_next_sid};
    $c->{_stream} = {
        id          => $id,
        state       => 'open',                       # idle -> open -> half_* -> closed
        tx_window   => $c->{_tx_win_init},           # granted by the peer's SETTINGS
        rx_window   => $OUR_WINDOW,                  # granted by our SETTINGS
        queue       => [],                           # DATA chunks waiting for the peer's window
        pending_end => 0,                            # END_STREAM deferred behind the queue
        headers_in  => 0,                            # inbound header blocks seen
        headers_out => 0,                            # HEADERS sent (exactly one per MVP stream)
        rst_sent    => 0,                            # peer frames for a stream we reset: junk
    };
    $c->{_next_sid} += 2;
    $c->{_last_sid}  = $id;
    return { ok => 1, stream_id => $id };
}

sub send_headers {
    my ($c, $sid, $list, $end) = @_;
    die "h2: header list wants an arrayref of [name, value] pairs\n"
        unless ref $list eq 'ARRAY';
    for my $pair (@$list) {
        die "h2: every header wants a [name, value] arrayref\n"
            unless ref $pair eq 'ARRAY' && @$pair == 2;
    }
    if (my $dead = _dead_err($c)) { return _err($dead) }
    if (my $bad = _stream_guard($c, $sid, 'HEADERS')) { return _err($bad) }
    my $st = $c->{_stream};
    return _err("h2: stream $sid is half-closed: HEADERS after END_STREAM\n")
        if $st->{state} eq 'half_local' || $st->{state} eq 'closed';
    return _err("h2: stream $sid already has headers (the MVP sends exactly one block)\n")
        if $st->{headers_out};
    for my $pair (@$list) {
        my ($name) = @$pair;
        return _err("h2: header name '$name' must be lowercase (RFC 7540 8.1.2)\n")
            if $name =~ /[A-Z]/;
    }
    my $block = eval { Plugins::yandex::Ynison::Grpc::HPack::encode_header_list($list) };
    return _err("h2: header encoding failed: $@") if !defined $block;
    return _err("h2: header block of @{[length $block]} octets exceeds the peer's max frame "
                . "size $c->{_tx_max_frame} (no outbound CONTINUATION in the MVP)\n")
        if length($block) > $c->{_tx_max_frame};
    $st->{headers_out} = 1;
    $st->{state} = $st->{state} eq 'half_remote' ? 'closed' : 'half_local' if $end;
    $c->{_out} .= _frame($FRAME{HEADERS}, FLAG_END_HEADERS | ($end ? FLAG_END_STREAM : 0),
                         $sid, $block);
    return { ok => 1, bytes => length $block };
}

sub send_data {
    my ($c, $sid, $bytes, $end) = @_;
    die "h2: DATA payload wants a string of bytes\n" if !defined $bytes || ref $bytes;
    if (my $dead = _dead_err($c)) { return _err($dead) }
    if (my $bad = _stream_guard($c, $sid, 'DATA')) { return _err($bad) }
    my $st = $c->{_stream};
    return _err("h2: DATA after END_STREAM (stream $sid is $st->{state})\n")
        if $st->{state} eq 'half_local' || $st->{state} eq 'closed';
    my $sent = 0;
    push @{ $st->{queue} }, $bytes if length $bytes;
    $st->{pending_end} = 1 if $end;    # rides on the final flushed frame when it completes the queue
    $sent = _drain($c, $st);
    return { ok           => 1,
             sent         => $sent,
             queued       => _queued($st),
             end_stream_sent => ($end && !$st->{pending_end}) ? 1 : 0 };
}

sub send_ping {
    my ($c, $opaque) = @_;
    die "h2: PING opaque wants a string of at most 8 octets\n"
        if !defined $opaque || ref $opaque || length($opaque) > 8;
    if (my $dead = _dead_err($c)) { return _err($dead) }
    $c->{_out} .= _frame($FRAME{PING}, 0, 0, $opaque . ("\0" x (8 - length $opaque)));
    return { ok => 1 };
}

sub send_rst_stream {
    my ($c, $sid, $code) = @_;
    my $num = error_code($code);
    if (my $dead = _dead_err($c)) { return _err($dead) }
    if (my $bad = _stream_guard($c, $sid, 'RST_STREAM')) { return _err($bad) }
    my $st = $c->{_stream};
    $st->{state}       = 'closed';
    $st->{rst_sent}    = 1;
    $st->{queue}       = [];
    $st->{pending_end} = 0;
    $c->{_out} .= _frame($FRAME{RST_STREAM}, 0, $sid, pack('N', $num));
    return { ok => 1 };
}

sub send_goaway {
    my ($c, $code, $debug) = @_;
    my $num = error_code($code);
    $debug = '' unless defined $debug;
    die "h2: GOAWAY debug wants a string of bytes\n" if ref $debug;
    if (my $dead = _dead_err($c)) { return _err($dead) }
    $c->{_out} .= _frame($FRAME{GOAWAY}, 0, 0, pack('N N', $c->{_last_sid}, $num) . $debug);
    $c->{_dead} = "connection is closing (GOAWAY sent, $ERROR_BY_ID{$num})";
    return { ok => 1 };
}

sub take_output {
    my ($c) = @_;
    my $out = $c->{_out};
    $c->{_out} = '';
    return $out;
}

sub feed {
    my ($c, $bytes) = @_;
    die "h2: feed wants a string of bytes\n" if !defined $bytes || ref $bytes;
    return () if $c->{_dead};
    $c->{_in} .= $bytes;
    my @events;
    until ($c->{_dead}) {
        last if length($c->{_in}) < 9;
        my ($b0, $b1, $b2, $type, $flags, $sid) = unpack('C C C C C N', substr($c->{_in}, 0, 9));
        my $len = ($b0 << 16) | ($b1 << 8) | $b2;
        $sid &= 0x7FFFFFFF;                      # the reserved bit is ignored on receipt
        last if length($c->{_in}) < 9 + $len;
        my $payload = substr($c->{_in}, 9, $len);
        substr($c->{_in}, 0, 9 + $len, '');

        if ($len > $OUR_MAX_FRAME) {             # our advertised SETTINGS_MAX_FRAME_SIZE
            push @events, _conn_err($c, 'FRAME_SIZE_ERROR',
                "h2: frame of $len octets exceeds our advertised max $OUR_MAX_FRAME\n");
            last;
        }
        if (my $bad = _chain_violation($c, $type, $sid)) {
            push @events, _conn_err($c, 'PROTOCOL_ERROR', $bad);
            last;
        }
        push @events, _dispatch($c, $type, $flags, $sid, $payload);
    }
    return @events;
}

sub is_dead     { defined $_[0]{_dead} }
sub dead_reason { $_[0]{_dead} }

# ---- outbound internals -------------------------------------------------------

sub _err { my ($msg) = @_; chomp $msg; return { ok => 0, error => $msg } }

sub _dead_err { return $_[0]{_dead} ? "h2: no connection: $_[0]{_dead}\n" : '' }

# '' when the op may proceed, otherwise the named error text
sub _stream_guard {
    my ($c, $sid, $what) = @_;
    return "h2: $what wants a stream id\n" if !defined $sid || ref $sid;
    my $st = $c->{_stream};
    return "h2: stream $sid is not open (no stream was opened)\n" if !$st;
    return '' if $st->{id} == $sid;
    return "h2: stream $sid is not ours (the active stream is $st->{id})\n";
}

sub _live_stream {
    my ($c) = @_;
    my $st = $c->{_stream} or return undef;
    return $st->{state} ne 'closed' ? $st : undef;
}

sub _queued { my $n = 0; $n += length for @{ $_[0]{queue} }; return $n }

# Release queued DATA while the peer's windows and max frame size allow it.
sub _drain {
    my ($c, $st) = @_;
    my $sent = 0;
    while (@{ $st->{queue} }) {
        last if $st->{tx_window} <= 0 || $c->{_tx_win_conn} <= 0;
        my $chunk = $st->{queue}[0];
        my $take = $st->{tx_window} < $c->{_tx_win_conn} ? $st->{tx_window} : $c->{_tx_win_conn};
        $take = $c->{_tx_max_frame} if $take > $c->{_tx_max_frame};
        $take = length($chunk) if $take > length($chunk);
        # the deferred END_STREAM rides on the frame that completes the whole queue
        my $final = $st->{pending_end} && @{ $st->{queue} } == 1 && $take == length($chunk);
        $c->{_out} .= _frame($FRAME{DATA}, $final ? FLAG_END_STREAM : 0, $st->{id},
                             substr($chunk, 0, $take));
        substr($st->{queue}[0], 0, $take, '');     # in place: the queue head shrinks
        shift @{ $st->{queue} } if $st->{queue}[0] eq '';
        $st->{tx_window}   -= $take;
        $c->{_tx_win_conn} -= $take;
        $sent              += $take;
        next unless $final;
        $st->{pending_end} = 0;
        $st->{state} = $st->{state} eq 'half_remote' ? 'closed' : 'half_local';
        last;
    }
    _emit_end($c, $st) if $st->{pending_end} && !@{ $st->{queue} };
    return $sent;
}

sub _emit_end {    # the deferred END_STREAM with nothing left to send: a zero-length DATA frame
    my ($c, $st) = @_;
    $st->{pending_end} = 0;
    $st->{state} = $st->{state} eq 'half_remote' ? 'closed' : 'half_local';
    $c->{_out} .= _frame($FRAME{DATA}, FLAG_END_STREAM, $st->{id}, '');
    return 1;
}

# ---- the HEADERS chain rule (RFC 7540 4.3) -------------------------------------

sub _chain_violation {
    my ($c, $type, $sid) = @_;
    my $chain = $c->{_hdr_block};
    if ($chain && $type != $FRAME{CONTINUATION}) {
        return "h2: a $FRAME_BY_ID{$type} frame is interlaced into the header block of stream "
             . "$chain->{stream} (the block must finish first)\n";
    }
    if ($chain && $chain->{stream} != $sid) {
        return "h2: CONTINUATION for stream $sid does not continue the header block of stream "
             . "$chain->{stream}\n";
    }
    return '' unless $type == $FRAME{CONTINUATION};
    return "h2: CONTINUATION without a preceding HEADERS on stream $sid\n" unless $chain;
    return '';
}

# ---- inbound internals --------------------------------------------------------

sub _dispatch {
    my ($c, $type, $flags, $sid, $payload) = @_;
    return _recv_data($c, $flags, $sid, $payload)         if $type == $FRAME{DATA};
    return _recv_headers($c, $flags, $sid, $payload)      if $type == $FRAME{HEADERS};
    return _recv_continuation($c, $flags, $sid, $payload) if $type == $FRAME{CONTINUATION};
    return _recv_settings($c, $flags, $sid, $payload)     if $type == $FRAME{SETTINGS};
    return _recv_ping($c, $flags, $sid, $payload)         if $type == $FRAME{PING};
    return _recv_goaway($c, $sid, $payload)               if $type == $FRAME{GOAWAY};
    return _recv_window_update($c, $sid, $payload)        if $type == $FRAME{WINDOW_UPDATE};
    return _recv_rst($c, $sid, $payload)                  if $type == $FRAME{RST_STREAM};
    return _conn_err($c, 'PROTOCOL_ERROR',
        "h2: PUSH_PROMISE on a client connection (push is not enabled)\n")
        if $type == $FRAME{PUSH_PROMISE};
    return ();                                            # PRIORITY and unknown types: skipped
}

# '' or the named connection-error text when the frame's stream id is wrong
sub _id_guard {
    my ($name, $sid, $want_nonzero) = @_;
    return '' if $want_nonzero ? $sid != 0 : $sid == 0;
    return sprintf("h2: %s frame with stream id %d%s\n", $name, $sid,
                   $want_nonzero ? '' : ' (this frame belongs on stream 0)');
}

sub _recv_data {
    my ($c, $flags, $sid, $payload) = @_;
    if (my $bad = _id_guard('DATA', $sid, 1)) { return _conn_err($c, 'PROTOCOL_ERROR', $bad) }
    return _conn_err($c, 'PROTOCOL_ERROR', "h2: padded DATA is not supported\n")
        if $flags & FLAG_PADDED;
    my $st = $c->{_stream};
    return () if $st && $st->{rst_sent};                  # in-flight junk for a stream we reset
    return _conn_err($c, 'PROTOCOL_ERROR', "h2: DATA on idle stream $sid\n")
        if !$st || $st->{id} != $sid;
    return _conn_err($c, 'STREAM_CLOSED', "h2: DATA on closed stream $sid\n")
        if $st->{state} eq 'closed' || $st->{state} eq 'half_remote';
    my $n = length $payload;
    return _conn_err($c, 'FLOW_CONTROL_ERROR',
        "h2: DATA of $n octets exceeds our connection window (a peer must respect it)\n")
        if $n > $c->{_rx_win_conn};
    return _conn_err($c, 'FLOW_CONTROL_ERROR',
        "h2: DATA of $n octets exceeds our stream $sid window\n")
        if $n > $st->{rx_window};
    if ($n > 0) {                        # an empty DATA frame consumes no window and gets no update
        $c->{_rx_win_conn} -= $n;
        $st->{rx_window}   -= $n;
        # replenish what arrived, aggressively (the plan: never throttle the Ynison push)
        $c->{_out} .= _frame($FRAME{WINDOW_UPDATE}, 0, 0, pack('N', $n));
        $c->{_rx_win_conn} += $n;
        if ($st->{state} ne 'closed') {                   # a closed stream gets no window updates
            $c->{_out} .= _frame($FRAME{WINDOW_UPDATE}, 0, $sid, pack('N', $n));
            $st->{rx_window} += $n;
        }
    }
    if ($flags & FLAG_END_STREAM) {
        $st->{state} = $st->{state} eq 'half_local' ? 'closed' : 'half_remote';
    }
    return { type => 'data', stream_id => $sid, data => $payload,
             end_stream => ($flags & FLAG_END_STREAM) ? 1 : 0 };
}

sub _recv_headers {
    my ($c, $flags, $sid, $payload) = @_;
    return _conn_err($c, 'PROTOCOL_ERROR', "h2: HEADERS with stream id 0\n") if $sid == 0;
    return _conn_err($c, 'PROTOCOL_ERROR', "h2: padded HEADERS are not supported\n")
        if $flags & FLAG_PADDED;
    return _conn_err($c, 'PROTOCOL_ERROR', "h2: HEADERS with priority data are not supported\n")
        if $flags & FLAG_PRIORITY;
    my $st = $c->{_stream};
    return _conn_err($c, 'PROTOCOL_ERROR', "h2: HEADERS on unknown stream $sid\n")
        if !$st || $st->{id} != $sid;
    return _conn_err($c, 'STREAM_CLOSED', "h2: HEADERS on closed stream $sid\n")
        if $st->{state} eq 'closed';
    $st->{headers_in}++;
    if ($st->{headers_in} > 1 && !($flags & FLAG_END_STREAM)) {   # a trailer must end the stream
        return _conn_err($c, 'PROTOCOL_ERROR',
            "h2: trailer block on stream $sid without END_STREAM (RFC 7540 8.1)\n");
    }
    $st->{state} = $st->{state} eq 'half_local' ? 'closed' : 'half_remote'
        if $flags & FLAG_END_STREAM;
    $c->{_decoder}->feed($payload);
    return _finish_headers($c, $flags, $sid) if $flags & FLAG_END_HEADERS;
    $c->{_hdr_block} = { stream => $sid };
    return ();
}

sub _recv_continuation {
    my ($c, $flags, $sid, $payload) = @_;
    $c->{_decoder}->feed($payload);
    return _finish_headers($c, $flags, $sid) if $flags & FLAG_END_HEADERS;
    return ();
}

sub _finish_headers {
    my ($c, $flags, $sid) = @_;
    $c->{_hdr_block} = undef;
    my $st = $c->{_stream};
    my $block = eval { $c->{_decoder}->finish };
    if (!$block) {
        my $why = $@;                                     # an hpack: ... reason
        $c->{_decoder} = undef;                           # a dead decoder is never reused
        return _conn_err($c, 'COMPRESSION_ERROR', "h2: HPACK: $why");
    }
    return { type      => 'headers',
             stream_id => $sid,
             headers   => $block,
             end_stream => ($flags & FLAG_END_STREAM) ? 1 : 0,
             trailer    => ($st && $st->{headers_in} > 1) ? 1 : 0 };
}

my %SETTING_NAMES = (
    1 => 'header_table_size', 2 => 'enable_push', 3 => 'max_concurrent_streams',
    4 => 'initial_window_size', 5 => 'max_frame_size', 6 => 'max_header_list_size',
);

sub _recv_settings {
    my ($c, $flags, $sid, $payload) = @_;
    if (my $bad = _id_guard('SETTINGS', $sid, 0)) { return _conn_err($c, 'PROTOCOL_ERROR', $bad) }
    if ($flags & FLAG_ACK) {
        return _conn_err($c, 'FRAME_SIZE_ERROR', "h2: SETTINGS ACK with a payload\n")
            if length $payload;
        return { type => 'settings_ack' };
    }
    return _conn_err($c, 'FRAME_SIZE_ERROR',
        "h2: SETTINGS of @{[length $payload]} octets is not a multiple of 6\n")
        if length($payload) % 6;
    my (%peer, $new_max_frame, $new_init_win, $bad);
    for (my $p = 0; $p < length $payload; $p += 6) {
        my ($id, $val) = unpack('nN', substr($payload, $p, 6));
        $peer{ $SETTING_NAMES{$id} } = $val if $SETTING_NAMES{$id};    # unknown ids: ignored
        $bad = ['PROTOCOL_ERROR',
                "h2: SETTINGS_MAX_FRAME_SIZE $val is outside $DEFAULT_MAX_FRAME..$MAX_FRAME_CEILING\n"]
            if $id == 5 && ($val < $DEFAULT_MAX_FRAME || $val > $MAX_FRAME_CEILING);
        $bad = ['FLOW_CONTROL_ERROR',
                "h2: SETTINGS_INITIAL_WINDOW_SIZE $val is above $WINDOW_MAX\n"]
            if $id == 4 && $val > $WINDOW_MAX;
        $new_max_frame = $val if $id == 5;
        $new_init_win  = $val if $id == 4;
    }
    return _conn_err($c, @$bad) if $bad;
    $c->{_tx_max_frame} = $new_max_frame if defined $new_max_frame;
    if (defined $new_init_win) {                          # adjusts the live stream too (RFC 7540 6.5.2)
        my $delta = $new_init_win - $c->{_tx_win_init};
        $c->{_tx_win_init} = $new_init_win;
        my $st = $c->{_stream};
        $st->{tx_window} += $delta if $st && $st->{state} ne 'closed';
    }
    $c->{_out} .= _frame($FRAME{SETTINGS}, FLAG_ACK, 0, '');          # the automatic ACK
    return { type => 'settings', peer => \%peer };
}

sub _recv_ping {
    my ($c, $flags, $sid, $payload) = @_;
    if (my $bad = _id_guard('PING', $sid, 0)) { return _conn_err($c, 'PROTOCOL_ERROR', $bad) }
    return _conn_err($c, 'FRAME_SIZE_ERROR', "h2: PING of @{[length $payload]} octets, wants 8\n")
        unless length($payload) == 8;
    return { type => 'ping_ack', opaque => $payload } if $flags & FLAG_ACK;
    $c->{_out} .= _frame($FRAME{PING}, FLAG_ACK, 0, $payload);        # the automatic ACK
    return { type => 'ping', opaque => $payload };
}

sub _recv_goaway {
    my ($c, $sid, $payload) = @_;
    if (my $bad = _id_guard('GOAWAY', $sid, 0)) { return _conn_err($c, 'PROTOCOL_ERROR', $bad) }
    return _conn_err($c, 'FRAME_SIZE_ERROR',
        "h2: GOAWAY of @{[length $payload]} octets, wants at least 8\n")
        unless length($payload) >= 8;
    my ($last, $code) = unpack('N N', substr($payload, 0, 8));
    my $name = $ERROR_BY_ID{$code} // "ERROR_$code";
    $c->{_dead} = "GOAWAY received (last stream $last, $name)";
    $c->{_in}   = '';
    return { type => 'goaway', last_stream_id => $last, code => $code, error => $name,
             debug => substr($payload, 8) };
}

sub _recv_window_update {
    my ($c, $sid, $payload) = @_;
    return _conn_err($c, 'FRAME_SIZE_ERROR',
        "h2: WINDOW_UPDATE of @{[length $payload]} octets, wants 4\n")
        unless length($payload) == 4;
    my $delta = unpack 'N', $payload;
    return _conn_err($c, 'PROTOCOL_ERROR', "h2: WINDOW_UPDATE with a 0 increment\n") unless $delta;
    if ($sid == 0) {
        $c->{_tx_win_conn} += $delta;
        return _conn_err($c, 'FLOW_CONTROL_ERROR',
            "h2: the connection window would rise above $WINDOW_MAX\n")
            if $c->{_tx_win_conn} > $WINDOW_MAX;
        _drain_all($c);
        return { type => 'window_update', stream_id => 0, delta => $delta };
    }
    my $st = $c->{_stream};
    return () if !$st || $st->{id} != $sid || $st->{state} eq 'closed';    # RFC 7540 5.1: ignore
    $st->{tx_window} += $delta;
    return _stream_err_event($c, $st, 'FLOW_CONTROL_ERROR',
        "h2: the stream $sid window would rise above $WINDOW_MAX\n")
        if $st->{tx_window} > $WINDOW_MAX;
    _drain($c, $st);
    return { type => 'window_update', stream_id => $sid, delta => $delta };
}

sub _recv_rst {
    my ($c, $sid, $payload) = @_;
    if (my $bad = _id_guard('RST_STREAM', $sid, 1)) { return _conn_err($c, 'PROTOCOL_ERROR', $bad) }
    return _conn_err($c, 'FRAME_SIZE_ERROR',
        "h2: RST_STREAM of @{[length $payload]} octets, wants 4\n")
        unless length($payload) == 4;
    my $st = $c->{_stream};
    return () if !$st || $st->{id} != $sid || $st->{state} eq 'closed';
    my $code = unpack 'N', $payload;
    $st->{state}       = 'closed';
    $st->{queue}       = [];
    $st->{pending_end} = 0;
    return { type => 'rst_stream', stream_id => $sid, code => $code,
             error => ($ERROR_BY_ID{$code} // "ERROR_$code") };
}

sub _drain_all {
    my ($c) = @_;
    my $st = $c->{_stream};
    _drain($c, $st) if $st && $st->{state} ne 'closed';
    return;
}

# ---- error plumbing -------------------------------------------------------------

sub _conn_err {    # record the death, then hand the event back for the feed() list
    my ($c, $name, $reason) = @_;
    chomp $reason;
    $c->{_dead}     = $reason =~ s/^h2: //r;    # dead_reason speaks without the prefix
    $c->{_in}       = '';
    $c->{_hdr_block} = undef;
    return { type => 'error', level => 'connection', error => $name,
             code => $ERROR{$name}, reason => $reason };
}

sub _stream_err_event {
    my ($c, $st, $name, $reason) = @_;
    chomp $reason;
    $st->{state} = 'closed';
    $st->{queue} = [];
    return { type => 'error', level => 'stream', error => $name,
             code => $ERROR{$name}, reason => $reason };
}

sub _frame {    # (type, flags, stream id, payload) -> frame bytes
    my ($type, $flags, $sid, $payload) = @_;
    my $len = length $payload;
    return pack('C C C C C N', ($len >> 16) & 0xFF, ($len >> 8) & 0xFF, $len & 0xFF,
                $type, $flags, $sid & 0x7FFFFFFF) . $payload;
}

1;
