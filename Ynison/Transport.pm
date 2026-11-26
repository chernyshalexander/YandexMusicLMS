package Plugins::yandex::Ynison::Transport;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Transport - non-blocking WebSocket client of the Ynison engine

=head1 DESCRIPTION

The only Slim-aware module of the client: a non-blocking WebSocket over
Slim::Networking::Async with the WSFraming codec, a write queue, an optional
heartbeat through the injected scheduler, and fetch_one() for the
redirector's one-message sessions. Carries the lessons of the live LMS runs:
L2 (the 101 and the first frames may ride in one TCP chunk), L4 (timers go
through the injected scheduler with the canonical Slim signature), L13 (no
frame is lost right after the handshake) and L14 (frame size caps).

=head1 EVENTS

    on_open
    on_text($msg)                 decoded JSON-HASH; non-HASH frames are skipped
    on_close($code, $reason)      a server close frame or an EOF (code 1006)
    on_error($reason, $status)    $status is the HTTP status on a failed handshake

Not fired by close(): the caller knows about its own close, and a callback
here would feed the reconnect loop.

=cut

# The only Slim-aware module of the client: a non-blocking WebSocket over
# Slim::Networking::Async with the WSFraming codec, a write queue, an optional
# heartbeat through the injected scheduler, and fetch_one() for the
# redirector's one-message sessions.

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo ();
use Slim::Networking::Async ();
use Slim::Networking::IO::Select ();

use Plugins::yandex::Ynison::Constants ();
use Plugins::yandex::Ynison::WSFraming ();
use Plugins::yandex::Ynison::Message ();

my $C = 'Plugins::yandex::Ynison::Constants';

# Slim::Networking::Async::new_socket always returns a PLAIN HTTP socket
# ("Default to an HTTP socket..."), even with https => 1 — TLS needs a
# subclass overriding new_socket (the legacy Ynison.pm did the same).
{
    package Plugins::yandex::Ynison::Transport::Async;
    use base qw(Slim::Networking::Async);

    sub new_socket {
        my ($self, %args) = @_;
        if ($args{https}) {
            require Slim::Networking::Async::Socket::HTTPS;
            return Slim::Networking::Async::Socket::HTTPS->new(%args);
        }
        return $self->SUPER::new_socket(%args);
    }
}

sub new {
    my ($class, %o) = @_;
    return bless {
        logger    => $o{logger} // sub { },
        scheduler => $o{scheduler},
        handlers  => {},
        headers   => [],
        socket    => undef,
        async     => undef,
        read_buf  => '',
        write_q   => [],
        decoder   => Plugins::yandex::Ynison::WSFraming::Decoder->new,
        heartbeat => undef,          # scheduler handle
        hb_sec    => 0,
        pong_wait => undef,          # liveness timer handle
        pong_sec  => Plugins::yandex::Ynison::Constants::WS_PING_TIMEOUT_DEFAULT(),
        open      => 0,
        closed    => 0,
    }, $class;
}

sub _log { my ($self, $level, $msg) = @_; $self->{logger}->($level, $msg); return }

sub is_open { $_[0]->{open} ? 1 : 0 }

# open(host =>, path =>, port =>, https =>, headers => [[name, value], ...],
#      on_open =>, on_text =>, on_close =>, on_error => [, socket => $fh for tests])
sub open {
    my ($self, %o) = @_;
    $self->{handlers} = { map { $_ => $o{$_} } qw(on_open on_text on_close on_error) };
    $self->{headers}  = $o{headers} || [];
    $self->{conn}     = { host => $o{host}, path => $o{path}, port => $o{port} // $C->YNISON_PORT(), https => $o{https} // 1 };
    $self->{test_sock} = $o{socket};

    my $async = Plugins::yandex::Ynison::Transport::Async->new();
    $self->{async} = $async;
    unless ($self->{test_sock}) {
        eval {
            $async->open({
                Host      => $self->{conn}{host},
                PeerPort  => $self->{conn}{port},
                https     => $self->{conn}{https},
                Timeout   => $C->WS_CONNECT_TIMEOUT(),
                onConnect => sub { $self->_on_connect($async) },
                onError   => sub { my (undef, $err) = @_; $self->_fail("connection error: $err") },
            });
        };
        $self->_fail("exception during open(): $@") if $@;
        return $self;
    }
    # A test supplied the socket: skip the real connect (the test stub does
    # not connect by itself).
    $self->_on_connect($async);
    return $self;
}

sub _on_connect {
    my ($self, $async) = @_;
    my $fh = $self->{test_sock} // ($async ? $async->socket() : undef);
    unless ($fh && (!$fh->can('opened') || $fh->opened)) {
        $self->_fail('no socket after connect');
        return;
    }
    $fh->blocking(0) if $fh->can('blocking');
    $self->{socket}   = $fh;
    $self->{read_buf} = '';
    $self->{write_q}  = [];
    $self->{decoder}  = Plugins::yandex::Ynison::WSFraming::Decoder->new;
    $self->{closed}   = 0;

    unshift @{ $self->{write_q} }, {
        data => Plugins::yandex::Ynison::Message::upgrade_request(
            host    => $self->{conn}{host},
            path    => $self->{conn}{path},
            key     => Plugins::yandex::Ynison::Message::ws_key(),
            headers => $self->{headers},
        ),
        sent_at  => time(),
        attempts => 0,
    };
    Slim::Networking::IO::Select::addWrite($fh, sub { $self->_on_writable(@_) });
    Slim::Networking::IO::Select::addRead($fh,  sub { $self->_on_handshake(@_) });
    return;
}

sub _fail {
    my ($self, $reason, $status) = @_;
    return if $self->{closed};
    $self->{closed} = 1;
    $self->_teardown;
    my $cb = $self->{handlers}{on_error};
    $cb->($self, $reason, $status) if $cb;
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
    if (my $fh = delete $self->{socket}) {
        Slim::Networking::IO::Select::removeRead($fh);
        Slim::Networking::IO::Select::removeWrite($fh);
        eval { $fh->close } if $fh->can('close');
    }
    $self->{async}     = undef;
    $self->{test_sock} = undef;
    $self->{write_q}   = [];
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

# set_heartbeat($seconds): a WS ping every $seconds while open.
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
    $self->_log('info', sprintf('heartbeat: ping sent; last inbound frame %s s ago',
        defined $self->{last_rx} ? int(time() - $self->{last_rx}) : -1));
    # Liveness: a ping must be answered (pong or any frame) within pong_sec,
    # or the channel is half-open and the server already dropped us (plan 3.1).
    if (my $s = $self->{scheduler}) {
        $self->{pong_wait} = $s->{set}->($self->{pong_sec}, sub {
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

# send_text($json) -> bool. Queues the masked frame; refuses frames above the
# outbound limit (constraint 19).
sub send_text {
    my ($self, $json) = @_;
    return 0 unless $self->{open};
    use bytes;
    if (length($json) > $C->MAX_FRAME_SIZE_OUT()) {
        $self->_log('warn', 'outgoing frame above MAX_FRAME_SIZE_OUT, refused');
        return 0;
    }
    my $frame = Plugins::yandex::Ynison::WSFraming::encode_text($json);
    if (@{ $self->{write_q} } >= $C->MAX_WRITE_QUEUE()) {
        shift @{ $self->{write_q} };
        $self->_log('warn', 'write queue overflow, dropped the oldest frame');
    }
    push @{ $self->{write_q} }, { data => $frame, sent_at => time(), attempts => 0 };
    Slim::Networking::IO::Select::addWrite($self->{socket}, sub { $self->_on_writable(@_) })
        if $self->{socket};
    return 1;
}

sub send_ping { $_[0]->_queue_ctrl(Plugins::yandex::Ynison::WSFraming::encode_ping()) }
sub send_pong { $_[0]->_queue_ctrl(Plugins::yandex::Ynison::WSFraming::encode_pong()) }

sub _queue_ctrl {
    my ($self, $frame) = @_;
    return unless $self->{socket};
    push @{ $self->{write_q} }, { data => $frame, sent_at => time(), attempts => 0 };
    Slim::Networking::IO::Select::addWrite($self->{socket}, sub { $self->_on_writable(@_) });
    return;
}

sub _on_writable {
    my ($self, $fh) = @_;
    return unless @{ $self->{write_q} };
    my $job  = $self->{write_q}[0];
    my $data = $job->{data};

    if (time() - $job->{sent_at} > $C->WS_CONNECT_TIMEOUT()) {
        shift @{ $self->{write_q} };
        $self->_log('warn', 'frame delivery timeout, dropped');
        return;
    }
    my $n = $fh->syswrite($data);
    if (!defined $n) {
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

sub _on_handshake {
    my ($self, $fh) = @_;
    # method call: the fake sockets in tests are not IO::Handles
    my $n = $fh->sysread(my $buf, 65_536);
    if (!defined $n) {
        return if $!{EAGAIN} || $!{EWOULDBLOCK};
        $self->_fail("read error during handshake: $!");
        return;
    }
    if ($n == 0) {
        $self->_fail('server closed during handshake');
        return;
    }
    $self->{read_buf} .= $buf;
    my ($status, $headers, $rest) = Plugins::yandex::Ynison::WSFraming::parse_upgrade($self->{read_buf});
    return unless defined $status;                     # header block incomplete

    if ($status != 101) {
        # Diagnostic: the edge writes the rejection reason into the body; log
        # the remainder of the buffer (up to 300 bytes) with the status.
        my $body = substr($self->{read_buf}, 0, 300) // '';
        $body =~ s/[^\x20-\x7e]/./g;
        $self->_log('warn', "handshake $status body: $body");
        $self->_fail("handshake failed: $status", $status);
        return;
    }
    $self->{read_buf} = $rest;
    Slim::Networking::IO::Select::removeRead($fh);
    Slim::Networking::IO::Select::addRead($fh, sub { $self->_on_readable(@_) });
    $self->{open} = 1;
    $self->_log('info', "websocket open: $self->{conn}{host}$self->{conn}{path}");
    $self->{heartbeat} = $self->{scheduler}{set}->($self->{hb_sec}, sub { $self->_hb_tick })
        if $self->{hb_sec} && $self->{scheduler};
    $self->{handlers}{on_open}->($self) if $self->{handlers}{on_open};
    # The first frames may ride in the same TCP chunk as the 101 (lessons L2, L13).
    $self->_pump_frames;
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
    $self->{read_buf} .= $buf;
    $self->_pump_frames;
    return;
}

sub _pump_frames {
    my ($self) = @_;
    my $buf = delete $self->{read_buf};
    if (defined $buf && length $buf) {
        $self->{last_rx} = time();
        $self->_alive;
    }
    for my $ev ($self->{decoder}->feed($buf)) {
        my $type = $ev->{type};
        if ($type eq 'text') {
            my $msg = eval { JSON::XS::VersionOneAndTwo::decode_json($ev->{payload}) };
            if ($@ || !defined $msg) {
                $self->_log('debug', 'skipping an undecodable frame (' . length($ev->{payload}) . ' bytes)');
                next;
            }
            if (ref $msg eq 'HASH') {
                $self->{handlers}{on_text}->($self, $msg) if $self->{handlers}{on_text};
            }
            else {
                $self->_log('debug', 'skipping a non-object JSON frame');
            }
        }
        elsif ($type eq 'ping')      { $self->send_pong }
        elsif ($type eq 'pong')      { }
        elsif ($type eq 'close') {
            my $cb = $self->{handlers}{on_close};
            $self->{closed} = 1;
            $self->_teardown;
            $cb->($self, $ev->{code}, $ev->{reason}) if $cb;
            return;
        }
        elsif ($type eq 'binary') { $self->_log('debug', 'binary frame ignored') }
        else                      { $self->_log('warn', "frame error: $ev->{reason}") }
    }
    return;
}

# fetch_one(host =>, path =>, headers =>, cb => cb($data|undef, $status|undef)):
# one JSON message from the redirector, then close. %o may carry socket and
# scheduler for tests, logger as usual.
sub fetch_one {
    my ($class, %o) = @_;
    my $self = ref $class ? $class : $class->new(logger => $o{logger} // sub { }, scheduler => $o{scheduler});
    my $cb     = $o{cb};
    my $done   = 0;
    my $finish = sub { $done ||= 1; $cb->(@_) };

    $self->{scheduler}{set}->($C->REDIRECT_TIMEOUT(), sub {
        return if $done;
        $finish->(undef, undef);
        $self->close;
    }) if $self->{scheduler};

    $self->open(
        host => $o{host}, path => $o{path}, port => $o{port}, https => $o{https},
        headers => $o{headers}, socket => $o{socket},
        on_text => sub {
            my ($t, $msg) = @_;
            return if $done;
            $done = 1;
            $finish->($msg, undef);
            $t->close;
        },
        on_close => sub {
            my ($t) = @_;
            return if $done;
            $done = 1;
            $finish->(undef, undef);
        },
        on_error => sub {
            my ($t, $reason, $status) = @_;
            return if $done;
            $done = 1;
            $finish->(undef, $status);
        },
    );
    return $self;
}

# fetch_redirect(host, path, headers, cb, port => N, https => 0|1):
# cb->($transport, $data|undef, $status|undef).
sub fetch_redirect {
    my ($self, $host, $path, $headers, $cb, %o) = @_;
    return $self->fetch_one(
        host => $host, path => $path,
        https => $o{https} // 1, port => $o{port} // $C->YNISON_PORT(),
        headers => $headers, logger => $self->{logger}, scheduler => $self->{scheduler},
        cb => sub { my ($data, $status) = @_; $cb->($self, $data, $status) },
    );
}

1;
