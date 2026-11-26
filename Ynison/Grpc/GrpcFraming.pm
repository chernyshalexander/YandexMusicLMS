package Plugins::yandex::Ynison::Grpc::GrpcFraming;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Grpc::GrpcFraming - gRPC message framing and trailer status for the gRPC transport

=head1 DESCRIPTION

The last protocol layer between the HTTP/2 engine and the JSON contract: the
5-byte gRPC message prefix (1 byte compressed flag + 4-byte big-endian
length, gRPC-over-HTTP/2 spec) and the trailer handling. Pure functions, no
I/O and no Slim.

    encode_message($payload)        # -> "\x00" . pack('N', length) . $payload
    parse_messages(\$buf)           # -> list of complete payloads, consumed
    trailer_status([[n, v], ...])   # -> { ok => 1 } | { ok => 0, code, message,
                                    #             details => { ynison-* } } | undef
    gateway_error([[n, v], ...])    # -> { error => { details => {...},
                                    #              grpc_code => N, message => $m } }

parse_messages() pulls every complete message out of an inbound accumulator
(the transport feeds it the DATA bytes of the one stream) and leaves any
partial tail in place, so message boundaries survive chunk edges. A message
with the compressed flag set is refused by name: the client never advertises
a compressor, so a server that sends one is broken - the bytes are still
consumed, keeping the stream aligned.

trailer_status() reads the gRPC status out of a decoded HEADERS block (the
final trailers, or a "Trailers-Only" response where grpc-status rides the
first block): grpc-status 0 is healthy; anything else fails with the numeric
code, the percent-decoded grpc-message, and every ynison-* trailer collected
under its lowercase name. No grpc-status at all is undef (the caller decides).
gateway_error() turns a failing trailer list into exactly the JSON error hash
the WS gateway would have sent, so Message::error_details and the Client's
reconnect policy consume gRPC failures unchanged.

Only core Perl; nothing loads Slim here.

=cut

# The last protocol layer between the HTTP/2 engine and the JSON contract:
# the 5-byte gRPC message prefix and the trailer status. Pure functions.
#
#   encode_message($payload) / parse_messages(\$buf)
#   trailer_status([[n,v],...])  -> { ok => 1 } | { ok => 0, code, message,
#                                      details => { ynison-* } } | undef
#   gateway_error([[n,v],...])   -> { error => { details, grpc_code, message } }
#
# A compressed message (flag 1) is refused by name but still consumed, so the
# byte stream stays aligned. grpc-message arrives percent-encoded per the
# gRPC spec; %XX escapes are decoded here.

use strict;
use warnings;

use Exporter ();

our @ISA       = ('Exporter');
our @EXPORT_OK = qw(encode_message parse_messages trailer_status gateway_error);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

# ---- the 5-byte message prefix -------------------------------------------------

# $payload -> "\x00" + 4-byte big-endian length + $payload
sub encode_message {
    my ($payload) = @_;
    die "grpc: message payload wants a string of bytes\n" if !defined $payload || ref $payload;
    return "\x00" . pack('N', length $payload) . $payload;
}

# (\$buf) -> the complete payloads, in order; the buffer ref keeps any partial
# tail (message boundaries survive chunk edges).
sub parse_messages {
    my ($buf) = @_;
    die "grpc: parse_messages wants a buffer scalarref\n" unless ref $buf eq 'SCALAR';
    my @out;
    while (length($$buf) >= 5) {
        my ($flag, $len) = unpack('C N', substr($$buf, 0, 5));
        last if length($$buf) < 5 + $len;
        substr($$buf, 0, 5, '');
        my $payload = substr($$buf, 0, $len, '');
        die "grpc: compressed message (flag 1) not supported - no compressor is advertised\n"
            if $flag != 0;
        push @out, $payload;
    }
    return @out;
}

# ---- trailer status --------------------------------------------------------------

# ([[name, value], ...]) -> { ok => 1 }
#                         | { ok => 0, code => N, message => $str,
#                             details => { 'ynison-*' => value } }
#                         | undef when the block carries no grpc-status
sub trailer_status {
    my ($list) = @_;
    my ($status, $message, %details);
    for my $pair (@$list) {
        my ($name, $value) = @$pair;
        $status  = 0 + $value if $name eq 'grpc-status' && !defined $status;
        $message = $value      if $name eq 'grpc-message' && !defined $message;
        $details{$name} = $value if $name =~ /^ynison-/;
    }
    return undef unless defined $status;
    return { ok => 1 } if $status == 0;
    return {
        ok      => 0,
        code    => $status,
        message => _percent_decode(defined $message ? $message : ''),
        details => \%details,
    };
}

# The JSON error hash the WS gateway would have sent for this trailer list -
# the shape Message::error_details parses (details, grpc_code, message).
sub gateway_error {
    my ($list) = @_;
    my $st = trailer_status($list);
    return undef unless $st && !$st->{ok};
    return {
        error => {
            details   => $st->{details},
            grpc_code => $st->{code},
            message   => $st->{message},
        }
    };
}

sub _percent_decode {    # the gRPC spec percent-encodes grpc-message; %XX only
    my ($s) = @_;
    $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $s;
}

1;
