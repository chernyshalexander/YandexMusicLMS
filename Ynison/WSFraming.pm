package Plugins::yandex::Ynison::WSFraming;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::WSFraming - RFC 6455 codec for the Ynison WebSocket bridge

=head1 DESCRIPTION

Pure functions and an incremental decoder: no I/O and no LMS here. Replaces the
hand-rolled framing inside the transport; the Protocol::WebSocket shipped with
LMS is used only in a cross-check test, never by the plugin itself.

    encode_*             client -> server frames (masked, as RFC 6455 requires)
    encode_*_unmasked    server -> client frames; only the local test stand uses them
    parse_upgrade        splits the HTTP 101 response from the frames that follow it
    Decoder->feed        turns arbitrary byte chunks into events

=cut

# RFC 6455 codec for the Ynison WebSocket bridge. Pure functions and an
# incremental decoder: no I/O and no LMS here.
#
#   encode_*             client → server frames (masked, as RFC 6455 requires)
#   encode_*_unmasked    server → client frames; only the local test stand uses them
#   parse_upgrade        splits the HTTP 101 response from the frames that follow it
#   Decoder->feed        turns arbitrary byte chunks into events

use strict;
use warnings;

use Exporter ();

use Plugins::yandex::Ynison::Constants ();

our @ISA       = ('Exporter');
our @EXPORT_OK = qw(encode_text encode_ping encode_pong encode_close
                    encode_text_unmasked encode_ping_unmasked encode_close_unmasked
                    parse_upgrade);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

# File-scoped lexicals: visible in both packages declared below.
my ($OP_CONT, $OP_TEXT, $OP_BIN, $OP_CLOSE, $OP_PING, $OP_PONG) = (0, 1, 2, 8, 9, 10);

sub _xor_mask {
    my ($data, $mask) = @_;
    use bytes;
    my $key = $mask x (int(length($data) / 4) + 1);
    return $data ^ substr($key, 0, length $data);
}

sub _frame {
    my ($opcode, $payload, $masked) = @_;
    use bytes;
    my $len    = length $payload;
    my $flag   = $masked ? 0x80 : 0x00;
    my $header = pack('C', 0x80 | $opcode);
    if    ($len < 126)    { $header .= pack('C',   $flag | $len) }
    elsif ($len < 65_536) { $header .= pack('Cn',  $flag | 126, $len) }
    else                  { $header .= pack('CNN', $flag | 127, 0, $len) }
    return $header . $payload unless $masked;
    my $mask = pack('C4', map { int(rand(256)) } 1 .. 4);
    return $header . $mask . _xor_mask($payload, $mask);
}

sub encode_text           { _frame($OP_TEXT,  $_[0], 1) }
sub encode_ping           { _frame($OP_PING,  '',    1) }
sub encode_pong           { _frame($OP_PONG,  '',    1) }
sub encode_close          { my ($code, $reason) = @_; _frame($OP_CLOSE, pack('n', $code || 1000) . ($reason // ''), 1) }
sub encode_text_unmasked  { _frame($OP_TEXT,  $_[0], 0) }
sub encode_ping_unmasked  { _frame($OP_PING,  '',    0) }
sub encode_close_unmasked { my ($code, $reason) = @_; _frame($OP_CLOSE, pack('n', $code || 1000) . ($reason // ''), 0) }

# ($status, \%headers, $remainder); the empty list while the header block is incomplete.
sub parse_upgrade {
    my ($buf) = @_;
    my $i = index($buf, "\r\n\r\n");
    return () if $i < 0;
    my $head = substr($buf, 0, $i);
    my $rest = substr($buf, $i + 4);
    my ($status) = $head =~ m{^HTTP/1\.[01] (\d{3})};
    my %headers;
    for my $line (split /\r\n/, $head) {
        next unless $line =~ /^([!#$%&'*+\-.^_`|~0-9A-Za-z]+)[ \t]*:[ \t]*(.*)$/;
        $headers{ lc $1 } = $2;
    }
    return (defined $status ? $status + 0 : 0, \%headers, $rest);
}

package Plugins::yandex::Ynison::WSFraming::Decoder;

# Incremental frame decoder. feed($bytes) returns the events that became
# complete; anything partial stays buffered until the next call.
sub new {
    my ($class, %opts) = @_;
    return bless {
        max_size => $opts{max_size} || Plugins::yandex::Ynison::Constants::MAX_FRAME_SIZE_IN(),
        buf      => '',
        frag_op  => undef,    # opcode of the message being assembled
        frags    => '',
    }, $class;
}

sub feed {
    my ($self, $bytes) = @_;
    use bytes;
    $self->{buf} .= $bytes if defined $bytes && length $bytes;
    my @events;

    while (1) {
        my $buf = $self->{buf};
        last if length $buf < 2;

        my ($b1, $b2) = unpack('CC', $buf);
        my $fin    = ($b1 & 0x80) ? 1 : 0;
        my $opcode = $b1 & 0x0F;
        my $masked = ($b2 & 0x80) ? 1 : 0;
        my $len    = $b2 & 0x7F;
        my $hlen   = 2;

        if ($len == 126) {
            last if length $buf < 4;
            $len = unpack('n', substr($buf, 2, 2));
            $hlen += 2;
        }
        elsif ($len == 127) {
            last if length $buf < 10;
            my ($hi, $lo) = unpack('NN', substr($buf, 2, 8));
            if ($hi) {
                $self->{buf} = '';
                push @events, { type => 'error', reason => 'frame length above 4 GiB' };
                last;
            }
            $len = $lo;
            $hlen += 8;
        }
        $hlen += 4 if $masked;

        if ($opcode >= 8 && (!$fin || $len > 125)) {
            $self->{buf} = '';
            push @events, { type => 'error', reason => 'invalid control frame' };
            last;
        }
        if ($len > $self->{max_size}) {
            $self->{buf} = '';
            push @events, { type => 'error', reason => "frame of $len bytes exceeds max_size" };
            last;
        }
        my $total = $hlen + $len;
        last if length $buf < $total;

        $self->{buf} = substr($buf, $total);
        my $payload = substr($buf, $hlen, $len);
        $payload = Plugins::yandex::Ynison::WSFraming::_xor_mask($payload, substr($buf, $hlen - 4, 4)) if $masked;

        if    ($opcode == $OP_PONG) { push @events, { type => 'pong' }; next }
        elsif ($opcode == $OP_PING) { push @events, { type => 'ping' }; next }
        elsif ($opcode == $OP_CLOSE) {
            my $code   = length $payload >= 2 ? unpack('n', substr($payload, 0, 2)) : 1005;
            my $reason = length $payload > 2 ? substr($payload, 2) : '';
            push @events, { type => 'close', code => $code, reason => $reason };
            next;
        }
        elsif ($opcode == $OP_CONT) {
            unless (defined $self->{frag_op}) {
                $self->{buf} = '';
                push @events, { type => 'error', reason => 'continuation without a fragmented message' };
                last;
            }
            $self->{frags} .= $payload;
        }
        elsif ($opcode == $OP_TEXT || $opcode == $OP_BIN) {
            if (defined $self->{frag_op}) {
                $self->{buf} = '';
                push @events, { type => 'error', reason => 'data frame inside a fragmented message' };
                last;
            }
            $self->{frag_op} = $opcode;
            $self->{frags}   = $payload;
        }
        else {
            $self->{buf} = '';
            push @events, { type => 'error', reason => "reserved opcode $opcode" };
            last;
        }

        next unless $fin;
        $opcode          = $self->{frag_op};
        $payload         = $self->{frags};
        $self->{frag_op} = undef;
        $self->{frags}   = '';
        push @events, { type => $opcode == $OP_TEXT ? 'text' : 'binary', payload => $payload };
    }
    return @events;
}

1;
