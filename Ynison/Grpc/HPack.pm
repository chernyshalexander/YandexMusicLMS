package Plugins::yandex::Ynison::Grpc::HPack;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Grpc::HPack - HPACK (RFC 7541) header compression for the gRPC transport

=head1 DESCRIPTION

The two halves of RFC 7541 the gRPC transport needs, with no HTTP/2 frame
logic inside: a stateless encoder for outbound header lists and a stateful
decoder for inbound HEADERS/CONTINUATION blocks.

    encode_header_list([[name, value], ...])   # -> bytes

always emits "literal header field without indexing" (0x00 prefix) with
non-Huffman literal names and values - legal for every field and accepted by
every server, at the cost of a few bytes per header. Names are sent as
given: keeping them lowercase is HTTP/2's rule, enforced by the H2 layer,
not here. Character strings are encoded as utf8 bytes, byte strings pass
through.

    my $dec = Plugins::yandex::Ynison::Grpc::HPack->new_decoder(4096);  # protocol max
    $dec->feed($chunk);                        # any number of calls, any chunk edges
    my $hdrs = $dec->finish;                   # -> [[name, value], ...]

The decoder holds one connection's dynamic table and the not-yet-decoded
block bytes: feed() the HEADERS payload and every CONTINUATION payload as
they arrive (chunk boundaries are invisible to the result) and call
finish() once END_HEADERS has been seen; it decodes the accumulated block
against the tables, returns the header list and keeps the table for the
next block. decode($bytes) is feed() + finish() for a block already in one
piece. dynamic_size()/dynamic_max() expose the table state for diagnostics.

The decoder understands the full RFC 7541 representation set: indexed
fields (static table of 61 entries, Appendix A, verbatim; dynamic table),
literal with incremental indexing, literal without indexing, literal never
indexed, dynamic table size updates, and Huffman-coded strings (Appendix B
code table, transcribed verbatim - our encoder never emits Huffman, but
Yandex's gRPC front Huffman-encodes header values, so the decoder must
speak it). Eviction follows RFC 7541 sections 4.3-4.4: entries leave from
the oldest end; an entry bigger than the table empties it and is not
stored, but still decodes.

decode dies with a terse "hpack: ..." reason (like the protobuf codec;
network callers wrap it in eval) on malformed input: index 0 or past the
table end, truncation anywhere inside the block, invalid Huffman padding or
an embedded EOS, an integer that would not fit 32 bits (nothing legal on
today's wires comes close; the cap also bounds hostile continuation-byte
runs), or a dynamic table size update above the protocol maximum given to
new_decoder (default 4096, the HTTP/2 default of SETTINGS_HEADER_TABLE_SIZE);
size updates may lower and raise the effective maximum within that ceiling.
A decoder that died is done for: the block buffer is left untouched
(deterministically), but the transport must drop the connection - HPACK
errors are COMPRESSION_ERROR, there is no recovery.

Only core Perl plus Encode; nothing loads Slim here.

=cut

# HPACK (RFC 7541) for the gRPC transport: a stateless encoder (literal
# without indexing, no Huffman) and a stateful decoder (static + dynamic
# tables, size updates, Huffman). No HTTP/2 frame logic in here.
#
#   encode_header_list([[name, value], ...]) -> bytes
#   HPack->new_decoder($max); $dec->feed($bytes); $dec->finish
#   $dec->decode($bytes); $dec->dynamic_size; $dec->dynamic_max
#
#   decode DIES with "hpack: ..." on malformed input; wrap in eval.

use strict;
use warnings;

use Exporter ();
use Encode ();

our @ISA       = ('Exporter');
our @EXPORT_OK = qw(encode_header_list);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

my $DEFAULT_TABLE_MAX = 4096;        # the HTTP/2 default of SETTINGS_HEADER_TABLE_SIZE
my $INT_MAX           = 4294967295;  # 2^32-1: longer integers on the wire are hostile
my $ENTRY_OVERHEAD    = 32;          # RFC 7541 4.1: entry size = name + value + 32

# static table, RFC 7541 Appendix A, Table 1, verbatim (entry 1 = :authority)
my @STATIC = (
    [ ':authority',                  ''             ],
    [ ':method',                     'GET'          ],
    [ ':method',                     'POST'         ],
    [ ':path',                       '/'            ],
    [ ':path',                       '/index.html'  ],
    [ ':scheme',                     'http'         ],
    [ ':scheme',                     'https'        ],
    [ ':status',                     '200'          ],
    [ ':status',                     '204'          ],
    [ ':status',                     '206'          ],
    [ ':status',                     '304'          ],
    [ ':status',                     '400'          ],
    [ ':status',                     '404'          ],
    [ ':status',                     '500'          ],
    [ 'accept-charset',              ''             ],
    [ 'accept-encoding',             'gzip, deflate'],
    [ 'accept-language',             ''             ],
    [ 'accept-ranges',               ''             ],
    [ 'accept',                      ''             ],
    [ 'access-control-allow-origin', ''             ],
    [ 'age',                         ''             ],
    [ 'allow',                       ''             ],
    [ 'authorization',               ''             ],
    [ 'cache-control',               ''             ],
    [ 'content-disposition',         ''             ],
    [ 'content-encoding',            ''             ],
    [ 'content-language',            ''             ],
    [ 'content-length',              ''             ],
    [ 'content-location',            ''             ],
    [ 'content-range',               ''             ],
    [ 'content-type',                ''             ],
    [ 'cookie',                      ''             ],
    [ 'date',                        ''             ],
    [ 'etag',                        ''             ],
    [ 'expect',                      ''             ],
    [ 'expires',                     ''             ],
    [ 'from',                        ''             ],
    [ 'host',                        ''             ],
    [ 'if-match',                    ''             ],
    [ 'if-modified-since',           ''             ],
    [ 'if-none-match',               ''             ],
    [ 'if-range',                    ''             ],
    [ 'if-unmodified-since',         ''             ],
    [ 'last-modified',               ''             ],
    [ 'link',                        ''             ],
    [ 'location',                    ''             ],
    [ 'max-forwards',                ''             ],
    [ 'proxy-authenticate',          ''             ],
    [ 'proxy-authorization',         ''             ],
    [ 'range',                       ''             ],
    [ 'referer',                     ''             ],
    [ 'refresh',                     ''             ],
    [ 'retry-after',                 ''             ],
    [ 'server',                      ''             ],
    [ 'set-cookie',                  ''             ],
    [ 'strict-transport-security',   ''             ],
    [ 'transfer-encoding',           ''             ],
    [ 'user-agent',                  ''             ],
    [ 'vary',                        ''             ],
    [ 'via',                         ''             ],
    [ 'www-authenticate',            ''             ],
);

# Huffman code, RFC 7541 Appendix B verbatim: [code as hex, length in bits]
# indexed by symbol 0..256; symbol 256 is EOS and never a legal output.
my @HUFFMAN = (
    [0x1ff8, 13], [0x7fffd8, 23], [0xfffffe2, 28], [0xfffffe3, 28],
    [0xfffffe4, 28], [0xfffffe5, 28], [0xfffffe6, 28], [0xfffffe7, 28],
    [0xfffffe8, 28], [0xffffea, 24], [0x3ffffffc, 30], [0xfffffe9, 28],
    [0xfffffea, 28], [0x3ffffffd, 30], [0xfffffeb, 28], [0xfffffec, 28],
    [0xfffffed, 28], [0xfffffee, 28], [0xfffffef, 28], [0xffffff0, 28],
    [0xffffff1, 28], [0xffffff2, 28], [0x3ffffffe, 30], [0xffffff3, 28],
    [0xffffff4, 28], [0xffffff5, 28], [0xffffff6, 28], [0xffffff7, 28],
    [0xffffff8, 28], [0xffffff9, 28], [0xffffffa, 28], [0xffffffb, 28],
    [0x14,  6], [0x3f8, 10], [0x3f9, 10], [0xffa, 12],
    [0x1ff9, 13], [0x15,  6], [0xf8,  8], [0x7fa, 11],
    [0x3fa, 10], [0x3fb, 10], [0xf9,  8], [0x7fb, 11],
    [0xfa,  8], [0x16,  6], [0x17,  6], [0x18,  6],
    [0x0,  5], [0x1,  5], [0x2,  5], [0x19,  6],
    [0x1a,  6], [0x1b,  6], [0x1c,  6], [0x1d,  6],
    [0x1e,  6], [0x1f,  6], [0x5c,  7], [0xfb,  8],
    [0x7ffc, 15], [0x20,  6], [0xffb, 12], [0x3fc, 10],
    [0x1ffa, 13], [0x21,  6], [0x5d,  7], [0x5e,  7],
    [0x5f,  7], [0x60,  7], [0x61,  7], [0x62,  7],
    [0x63,  7], [0x64,  7], [0x65,  7], [0x66,  7],
    [0x67,  7], [0x68,  7], [0x69,  7], [0x6a,  7],
    [0x6b,  7], [0x6c,  7], [0x6d,  7], [0x6e,  7],
    [0x6f,  7], [0x70,  7], [0x71,  7], [0x72,  7],
    [0xfc,  8], [0x73,  7], [0xfd,  8], [0x1ffb, 13],
    [0x7fff0, 19], [0x1ffc, 13], [0x3ffc, 14], [0x22,  6],
    [0x7ffd, 15], [0x3,  5], [0x23,  6], [0x4,  5],
    [0x24,  6], [0x5,  5], [0x25,  6], [0x26,  6],
    [0x27,  6], [0x6,  5], [0x74,  7], [0x75,  7],
    [0x28,  6], [0x29,  6], [0x2a,  6], [0x7,  5],
    [0x2b,  6], [0x76,  7], [0x2c,  6], [0x8,  5],
    [0x9,  5], [0x2d,  6], [0x77,  7], [0x78,  7],
    [0x79,  7], [0x7a,  7], [0x7b,  7], [0x7ffe, 15],
    [0x7fc, 11], [0x3ffd, 14], [0x1ffd, 13], [0xffffffc, 28],
    [0xfffe6, 20], [0x3fffd2, 22], [0xfffe7, 20], [0xfffe8, 20],
    [0x3fffd3, 22], [0x3fffd4, 22], [0x3fffd5, 22], [0x7fffd9, 23],
    [0x3fffd6, 22], [0x7fffda, 23], [0x7fffdb, 23], [0x7fffdc, 23],
    [0x7fffdd, 23], [0x7fffde, 23], [0xffffeb, 24], [0x7fffdf, 23],
    [0xffffec, 24], [0xffffed, 24], [0x3fffd7, 22], [0x7fffe0, 23],
    [0xffffee, 24], [0x7fffe1, 23], [0x7fffe2, 23], [0x7fffe3, 23],
    [0x7fffe4, 23], [0x1fffdc, 21], [0x3fffd8, 22], [0x7fffe5, 23],
    [0x3fffd9, 22], [0x7fffe6, 23], [0x7fffe7, 23], [0xffffef, 24],
    [0x3fffda, 22], [0x1fffdd, 21], [0xfffe9, 20], [0x3fffdb, 22],
    [0x3fffdc, 22], [0x7fffe8, 23], [0x7fffe9, 23], [0x1fffde, 21],
    [0x7fffea, 23], [0x3fffdd, 22], [0x3fffde, 22], [0xfffff0, 24],
    [0x1fffdf, 21], [0x3fffdf, 22], [0x7fffeb, 23], [0x7fffec, 23],
    [0x1fffe0, 21], [0x1fffe1, 21], [0x3fffe0, 22], [0x1fffe2, 21],
    [0x7fffed, 23], [0x3fffe1, 22], [0x7fffee, 23], [0x7fffef, 23],
    [0xfffea, 20], [0x3fffe2, 22], [0x3fffe3, 22], [0x3fffe4, 22],
    [0x7ffff0, 23], [0x3fffe5, 22], [0x3fffe6, 22], [0x7ffff1, 23],
    [0x3ffffe0, 26], [0x3ffffe1, 26], [0xfffeb, 20], [0x7fff1, 19],
    [0x3fffe7, 22], [0x7ffff2, 23], [0x3fffe8, 22], [0x1ffffec, 25],
    [0x3ffffe2, 26], [0x3ffffe3, 26], [0x3ffffe4, 26], [0x7ffffde, 27],
    [0x7ffffdf, 27], [0x3ffffe5, 26], [0xfffff1, 24], [0x1ffffed, 25],
    [0x7fff2, 19], [0x1fffe3, 21], [0x3ffffe6, 26], [0x7ffffe0, 27],
    [0x7ffffe1, 27], [0x3ffffe7, 26], [0x7ffffe2, 27], [0xfffff2, 24],
    [0x1fffe4, 21], [0x1fffe5, 21], [0x3ffffe8, 26], [0x3ffffe9, 26],
    [0xffffffd, 28], [0x7ffffe3, 27], [0x7ffffe4, 27], [0x7ffffe5, 27],
    [0xfffec, 20], [0xfffff3, 24], [0xfffed, 20], [0x1fffe6, 21],
    [0x3fffe9, 22], [0x1fffe7, 21], [0x1fffe8, 21], [0x7ffff3, 23],
    [0x3fffea, 22], [0x3fffeb, 22], [0x1ffffee, 25], [0x1ffffef, 25],
    [0xfffff4, 24], [0xfffff5, 24], [0x3ffffea, 26], [0x7ffff4, 23],
    [0x3ffffeb, 26], [0x7ffffe6, 27], [0x3ffffec, 26], [0x3ffffed, 26],
    [0x7ffffe7, 27], [0x7ffffe8, 27], [0x7ffffe9, 27], [0x7ffffea, 27],
    [0x7ffffeb, 27], [0xffffffe, 28], [0x7ffffec, 27], [0x7ffffed, 27],
    [0x7ffffee, 27], [0x7ffffef, 27], [0x7fffff0, 27], [0x3ffffee, 26],
    [0x3fffffff, 30],   # EOS (256)
);
my %HUFFMAN_SYMBOL = map { my ($code, $bits) = @{ $HUFFMAN[$_] }; "$bits:$code" => $_ } 0 .. 256;

# ---- public -----------------------------------------------------------------

sub new_decoder {
    my ($class, $max) = @_;
    $max = $DEFAULT_TABLE_MAX unless defined $max;
    die "hpack: dynamic table protocol maximum must be an integer in 0 .. $INT_MAX\n"
        if ref $max || "$max" !~ /^\d+$/ || $max > $INT_MAX;
    return bless { _protocol => 0 + $max, _max => 0 + $max, _table => [], _size => 0, _buf => '' },
        $class;
}

# [[name, value], ...] -> bytes: 0x00-prefixed literals, no Huffman, no state.
sub encode_header_list {
    my ($list) = @_;
    die "hpack: header list wants an arrayref of [name, value] pairs\n" unless ref $list eq 'ARRAY';
    my $out = '';
    for my $pair (@$list) {
        die "hpack: every header wants a [name, value] arrayref\n"
            unless ref $pair eq 'ARRAY' && @$pair == 2;
        my ($name, $value) = @$pair;
        die "hpack: header name wants a scalar, not a reference\n"  if !defined $name  || ref $name;
        die "hpack: header value wants a scalar, not a reference\n" if !defined $value || ref $value;
        $out .= "\x00" . _literal_bytes($name) . _literal_bytes($value);
    }
    return $out;
}

# Accumulate block bytes (HEADERS + CONTINUATION payloads, any chunk edges).
sub feed {
    my ($d, $bytes) = @_;
    die "hpack: feed wants a string of bytes\n" if !defined $bytes || ref $bytes;
    $d->{_buf} .= $bytes;
    return $d;
}

# Decode the accumulated bytes as one complete header block; -> [[name, value],...].
# The dynamic table persists across finish() calls, the block buffer does not.
sub finish {
    my ($d) = @_;
    my ($buf, $end, $pos, @out) = ($d->{_buf}, length $d->{_buf}, 0);
    while ($pos < $end) {
        my $b = ord(substr $buf, $pos, 1);
        if    ($b & 0x80)           { push @out, [ _indexed($d, $buf, \$pos, $end) ] }          # 1xxxxxxx
        elsif (($b & 0xC0) == 0x40) { push @out, [ _literal($d, $buf, \$pos, $end, 6, 1) ] }    # 01xxxxxx
        elsif (($b & 0xE0) == 0x20) { _size_update($d, _int($buf, \$pos, $end, 5)) }            # 001xxxxx
        else                        { push @out, [ _literal($d, $buf, \$pos, $end, 4, 0) ] }    # 000[01]xxxx
    }
    $d->{_buf} = '';
    return \@out;
}

# feed + finish for a block already in one piece.
sub decode { my ($d, $bytes) = @_; $d->feed($bytes); return $d->finish }

sub dynamic_size { $_[0]->{_size} }    # octets the dynamic table occupies now
sub dynamic_max  { $_[0]->{_max} }     # negotiated maximum (protocol max after size updates)

# ---- representations ---------------------------------------------------------

sub _indexed {
    my ($d, $buf, $pos, $end) = @_;
    my $idx = _int($buf, $pos, $end, 7);
    return _lookup($d, $idx);
}

sub _literal {    # -> (name, value); inserts into the dynamic table when $insert
    my ($d, $buf, $pos, $end, $prefix, $insert) = @_;
    my $idx = _int($buf, $pos, $end, $prefix);
    my ($name, $value) = $idx ? _lookup($d, $idx) : _string($buf, $pos, $end);
    $value = _string($buf, $pos, $end);
    _put($d, $name, $value) if $insert;
    return ($name, $value);
}

sub _size_update {
    my ($d, $new) = @_;
    die "hpack: dynamic table size update $new is above the protocol maximum $d->{_protocol}\n"
        if $new > $d->{_protocol};
    $d->{_max} = $new;    # the effective max: size updates may lower AND raise it,
    _evict($d);           # but never above the protocol maximum (RFC 7541 6.3)
    return $d;
}

# ---- the dynamic table: newest entry first, eviction from the old end --------

sub _lookup {
    my ($d, $idx) = @_;
    die "hpack: index 0 is not a valid header field index\n" unless $idx;
    return @{ $STATIC[$idx - 1] } if $idx <= @STATIC;
    my $i = $idx - 62;
    die "hpack: index $idx is out of range (the dynamic table holds @{[ scalar @{ $d->{_table} } ]} entries)\n"
        if $i < 0 || $i > $#{ $d->{_table} };
    my $e = $d->{_table}[$i];
    return ($e->[0], $e->[1]);
}

sub _put {    # RFC 7541 4.4: make room, then store - unless the entry dwarfs the table
    my ($d, $name, $value) = @_;
    my $entry = length($name) + length($value) + $ENTRY_OVERHEAD;
    while ($d->{_size} + $entry > $d->{_max} && @{ $d->{_table} }) {
        $d->{_size} -= pop(@{ $d->{_table} })->[2];
    }
    return $d if $entry > $d->{_max};    # table emptied above; the field itself still decodes
    unshift @{ $d->{_table} }, [$name, $value, $entry];
    $d->{_size} += $entry;
    return $d;
}

sub _evict {    # RFC 7541 4.3: size reductions evict from the old end
    my ($d) = @_;
    while ($d->{_size} > $d->{_max} && @{ $d->{_table} }) {
        $d->{_size} -= pop(@{ $d->{_table} })->[2];
    }
    return $d;
}

# ---- primitives: prefixed integers (5.1) and string literals (5.2) -----------

sub _int {    # (buf, \$pos, $end, $prefix_bits) -> value; dies when cut short or oversized
    my ($buf, $pos, $end, $n) = @_;
    die "hpack: truncated header block (an integer prefix is cut short)\n" if $$pos >= $end;
    my $mask = (1 << $n) - 1;
    my $i = ord(substr $buf, $$pos++, 1) & $mask;
    return $i if $i < $mask;
    my $mult = 1;
    while (1) {
        die "hpack: truncated header block (an integer continuation is cut short)\n" if $$pos >= $end;
        die "hpack: integer too large (above $INT_MAX)\n" if $mult > 2 ** 28;    # >5 continuation bytes
        my $b = ord(substr $buf, $$pos++, 1);
        $i += ($b & 0x7F) * $mult;
        die "hpack: integer too large (above $INT_MAX)\n" if $i > $INT_MAX;
        $mult *= 128;
        last unless $b & 0x80;
    }
    return $i;
}

sub _string {    # (buf, \$pos, $end) -> decoded value, Huffman or plain
    my ($buf, $pos, $end) = @_;
    die "hpack: truncated header block (a string length prefix is cut short)\n" if $$pos >= $end;
    my $huff = ord(substr $buf, $$pos, 1) & 0x80;
    my $len = _int($buf, $pos, $end, 7);
    die "hpack: truncated header block (a string literal is cut short)\n" if $$pos + $len > $end;
    my $raw = substr $buf, $$pos, $len;
    $$pos += $len;
    return $huff ? _huffman($raw) : $raw;
}

sub _huffman {   # Appendix B code walk: MSB-first bits through a (length, code) lookup
    my ($bytes) = @_;
    my ($out, $code, $len) = ('', 0, 0);
    for my $b (unpack 'C*', $bytes) {
        for my $bit (reverse 0 .. 7) {
            $code = ($code << 1) | (($b >> $bit) & 1);
            $len++;
            my $sym = $HUFFMAN_SYMBOL{"$len:$code"};
            if (defined $sym) {
                die "hpack: EOS symbol inside a Huffman string\n" if $sym == 256;
                $out .= chr $sym;
                ($code, $len) = (0, 0);
            }
            elsif ($len >= 30) {    # the longest code is 30 bits: nothing matches any more
                die "hpack: invalid Huffman code (no symbol within 30 bits)\n";
            }
        }
    }
    die "hpack: invalid Huffman padding (the trailing bits must be all ones)\n"
        if $len && $code != (1 << $len) - 1;
    return $out;
}

# ---- encoder helpers ----------------------------------------------------------

sub _literal_bytes {    # a string literal on the wire: H = 0, 7-bit-prefixed length
    my ($s) = @_;
    $s = Encode::encode_utf8($s) if utf8::is_utf8($s);
    return _int_octets(length $s) . $s;
}

sub _int_octets {       # encoder side of RFC 7541 5.1 on a full 7-bit prefix
    my ($v) = @_;
    return chr($v) if $v < 127;
    my $out = chr(127);
    my $rest = $v - 127;
    while ($rest >= 128) { $out .= chr(($rest & 0x7F) | 0x80); $rest = int($rest / 128) }
    return $out . chr($rest);
}

1;
