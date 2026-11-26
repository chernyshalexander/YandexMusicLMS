package Plugins::yandex::Ynison::Grpc::Proto;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Grpc::Proto - pure protobuf wire codec driven by a schema

=head1 DESCRIPTION

encode(schema, message, hash) turns the JSON-contract hash (proto field names
in snake_case, int64 as digit-strings, booleans as \1/\0) into protobuf bytes;
decode(schema, message, bytes) turns bytes back into such a hash. No schema
knowledge here: the first argument is the message map from
L<Plugins::yandex::Ynison::Grpc::Schema/MESSAGES> (name -> field table), the
second names the message whose table to use; enum names and numbers are
resolved through that Schema package.

    encode($schema, 'PutYnisonStateRequest', $hash)   # -> bytes
    decode($schema, 'PutYnisonStateResponse', $bytes) # -> hashref

Rules (proto3 semantics, the JSON contract of the WS gateway):

    missing/zero scalars    omitted on encode (0, '0', '', \0, enum 0)
    missing scalars         filled on decode (0, '0', '', \0, enum-0 name);
                            repeated fields decode to listrefs ([] when absent)
    varint_i64              digit-strings in and out, exact past 2^53; negative
                            wire values decode to '-N' strings, negative input
                            clamps to 0 like Message.pm i64()
    bool                    \1 / \0 on decode, any nonzero varint is true
    string_value            plain string in JSON, StringValue{value=1} on the
                            wire; presence is kept for '' on encode
    message / string_value  absent stays absent (presence semantics);
                            a repeated singular message: the last one wins
    repeated varints        packed on encode; packed AND unpacked on decode
    unknown field numbers   skipped by wire type (wt0/1/2/5); fields whose
                            message table is out of the schema are skipped too
    malformed input         decode DIES with a terse reason (truncated, group
                            wire type, field number 0 or above 2^29-1, varint
                            too long, wire-type mismatch) - network callers
                            wrap it in eval
    encode strictness       unknown keys, wrong shapes and unknown enum names
                            die, so typos surface at the call site

Only core Perl plus Encode; nothing loads Slim here.

=cut

# Pure protobuf wire codec driven by a schema. encode(schema, message, hash)
# turns the JSON-contract hash into protobuf bytes, decode(schema, message,
# bytes) turns bytes back. The schema is just the message map (Schema::MESSAGES);
# enum names/numbers are resolved through the Schema package.
#
#   missing/zero scalars  omitted on encode, filled on decode (0, '0', '', \0)
#   varint_i64            digit-strings in and out, exact past 2^53
#   string_value          plain string in JSON, StringValue{1} on the wire
#   repeated lists        decode to listrefs; packed and unpacked both accepted
#   unknown fields        skipped by wire type
#   malformed input       decode DIES deterministically; wrap in eval

use strict;
use warnings;

use Exporter ();
use Encode ();
use Scalar::Util qw(looks_like_number);

use Plugins::yandex::Ynison::Message ();    # i64: the int64-as-string convention
use Plugins::yandex::Ynison::Grpc::Schema ();

our @ISA       = ('Exporter');
our @EXPORT_OK = qw(encode decode);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

my $I64_MAX   = '9223372036854775807';
my $TWO64     = '18446744073709551616';      # 2**64, exact as a string
my $NUM_GUARD = 72057594037927936;           # 2**56: IV-safe varint arithmetic ends here
my $MAX_FIELD = 536870911;                   # 2**29 - 1, per the protobuf spec

# wire types of the kinds the schema may declare
my %WIRE_TYPE = map { $_ => 0 } qw(varint varint_i64 bool varint_enum);
$WIRE_TYPE{$_} = 1 for 'double';
$WIRE_TYPE{$_} = 2 for qw(string bytes string_value message message_list packed_varint string_list);

# ---- public -----------------------------------------------------------------

sub encode {
    my ($schema, $msg, $hash) = @_;
    return _enc($schema, _table($schema, $msg), $hash, $msg);
}

sub decode {
    my ($schema, $msg, $bytes) = @_;
    my $table = _table($schema, $msg);
    my ($out) = _dec($schema, $table, defined $bytes ? $bytes : '', 0, length($bytes // ''), $msg);
    return $out;
}

# ---- encoding ----------------------------------------------------------------

sub _table {
    my ($schema, $msg) = @_;
    my $t = $schema->{$msg};
    die "protobuf: no table for message '$msg'\n" unless $t;
    return $t;
}

sub _enc {
    my ($schema, $table, $hash, $msg) = @_;
    die "encode $msg: hashref expected\n" unless ref $hash eq 'HASH';
    my %by_name = map { $_->[0] => 1 } @$table;
    for my $key (keys %$hash) {
        next if $by_name{$key};
        die "encode $msg: unknown field name '$key'\n";
    }
    my $out = '';
    for my $f (@$table) {
        my ($name, $num, $kind, $ref) = @$f;
        next unless exists $hash->{$name};
        my $v = $hash->{$name};
        next if !defined $v;
        if    ($kind eq 'varint')        { $out .= _enc_scalar_varint($num, $v, $name, $msg) }
        elsif ($kind eq 'varint_i64')    { $out .= _enc_i64($num, $v, $name, $msg) }
        elsif ($kind eq 'bool')          { $out .= _enc_scalar_varint($num, _truth($v) ? 1 : 0, $name, $msg) }
        elsif ($kind eq 'double')        { $out .= _enc_double($num, $v, $name, $msg) }
        elsif ($kind eq 'string')        { $out .= _enc_ld($num, _enc_string($v, $name, $msg)) unless $v eq '' }
        elsif ($kind eq 'bytes')         { $out .= _enc_ld($num, _enc_bytes($v, $name, $msg)) unless $v eq '' }
        elsif ($kind eq 'varint_enum')   { $out .= _enc_scalar_varint($num, _enum_num($v, $ref), $name, $msg) }
        elsif ($kind eq 'string_value')  { $out .= _enc_ld($num, _enc_string_value($v, $name, $msg)) }
        elsif ($kind eq 'message')       { $out .= _enc_ld($num, _enc_msg($schema, $ref, $v, $msg)) }
        elsif ($kind eq 'message_list')  { $out .= _enc_msg_list($schema, $num, $ref, $v, $name, $msg) }
        elsif ($kind eq 'packed_varint') { $out .= _enc_packed($num, $ref, $v, $name, $msg) }
        elsif ($kind eq 'string_list')   { $out .= _enc_strings($num, $v, $name, $msg) }
        else                             { die "encode $msg: unknown wire kind '$kind'\n" }
    }
    return $out;
}

sub _enc_msg {
    my ($schema, $ref, $v, $caller) = @_;
    die "encode $caller: message wants a hashref\n" unless ref $v eq 'HASH';
    return _enc($schema, _table($schema, $ref), $v, $ref);
}

sub _enc_msg_list {
    my ($schema, $num, $ref, $v, $name, $caller) = @_;
    die "encode $caller: repeated message '$name' wants an arrayref\n" unless ref $v eq 'ARRAY';
    my $out = '';
    for my $el (@$v) { $out .= _enc_ld($num, _enc_msg($schema, $ref, $el, $caller)) }
    return $out;
}

sub _enc_strings {
    my ($num, $v, $name, $caller) = @_;
    die "encode $caller: repeated string '$name' wants an arrayref\n" unless ref $v eq 'ARRAY';
    my $out = '';
    for my $el (@$v) { $out .= _enc_ld($num, _enc_string($el, $name, $caller)) }
    return $out;
}

sub _enc_packed {
    my ($num, $ref, $v, $name, $caller) = @_;
    die "encode $caller: packed '$name' wants an arrayref\n" unless ref $v eq 'ARRAY';
    my $payload = '';
    for my $el (@$v) {
        my $u = defined $ref ? _enum_num($el, $ref) : _num($el, $name, $caller);
        $payload .= _varint_of($u, $name, $caller);
    }
    return _enc_ld($num, $payload);
}

# Scalars equal to the proto3 default contribute no bytes: nothing for 0.
sub _enc_scalar_varint {
    my ($num, $v, $name, $caller) = @_;
    die "encode $caller: '$name' wants a number\n" if ref $v || !looks_like_number($v);
    return '' if $v == 0;
    return _tag($num, 0) . _varint_of($v, $name, $caller);
}

sub _enc_i64 {
    my ($num, $v, $name, $caller) = @_;
    die "encode $caller: '$name' wants a scalar, not a reference\n" if ref $v;
    my $s = $v =~ /^\d+$/ ? $v : Plugins::yandex::Ynison::Message::i64($v);
    return '' if $s eq '0';
    return _tag($num, 0) . _dec_to_varint($s);
}

sub _enc_double {
    my ($num, $v, $name, $caller) = @_;
    die "encode $caller: '$name' wants a number\n" if ref $v || !looks_like_number($v);
    return '' if $v == 0;
    return _tag($num, 1) . pack('d<', 0 + $v);
}

sub _enc_string {
    my ($v, $name, $caller) = @_;
    die "encode $caller: '$name' wants a scalar, not a reference\n" if ref $v;
    return utf8::is_utf8($v) ? Encode::encode_utf8($v) : $v;    # bytes pass, chars get utf8
}

# The JSON-contract booleans are \1 / \0 - and \0 is a reference, hence TRUE
# to plain Perl truth. Unwrap references before judging.
sub _truth {
    my ($v) = @_;
    return ref $v ? $$v : $v;
}

sub _enc_bytes {    # bytes pass through verbatim, no utf8 handling
    my ($v, $name, $caller) = @_;
    die "encode $caller: '$name' wants a scalar, not a reference\n" if ref $v;
    return $v;
}

sub _enc_string_value {    # StringValue{value = 1}; '' keeps presence as an empty wrapper
    my ($v, $name, $caller) = @_;
    my $inner = _enc_string($v, $name, $caller);
    return $inner eq '' ? '' : "\x0A" . _varint_bytes(length $inner) . $inner;
}

sub _enc_ld {
    my ($num, $payload) = @_;
    return _tag($num, 2) . _varint_bytes(length $payload) . $payload;
}

sub _enum_num {
    my ($v, $table) = @_;
    return 0 + $v if !ref $v && $v =~ /^\d+$/;    # numbers pass through
    if (ref $v || $v !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        die "protobuf: enum value '$v' is not a name or number\n";
    }
    return Plugins::yandex::Ynison::Grpc::Schema::enum_num($table, $v);
}

sub _num {
    my ($v, $name, $caller) = @_;
    die "encode $caller: '$name' wants a number\n" if ref $v || !looks_like_number($v);
    return 0 + $v;
}

# ---- varints: IV-exact below 2**56, exact decimal-string math above ----------

sub _varint_of {
    my ($v, $name, $caller) = @_;
    die "encode $caller: '$name' wants a number\n" if ref $v || !looks_like_number($v);
    return _varint_bytes(0 + $v) if $v >= 0 && $v < $NUM_GUARD;
    my $s = $v >= 0 ? sprintf('%.0f', $v) : _dec_sub($TWO64, sprintf('%.0f', abs $v));
    return _dec_to_varint($s);
}

sub _varint_bytes {
    my ($u) = @_;
    my $out = '';
    while ($u >= 128) { $out .= chr(($u & 0x7F) | 0x80); $u = int($u / 128) }
    return $out . chr($u);
}

sub _tag {
    my ($num, $wt) = @_;
    return _varint_bytes(($num << 3) | $wt);
}

# ($decimal_string, $next_pos); the string is the exact unsigned value.
sub _varint_dec {
    my ($buf, $pos, $end) = @_;
    my $acc   = 0;
    my $shift = 0;
    my $count = 0;
    while (1) {
        die "protobuf: truncated varint\n" if $pos >= $end;
        my $b = ord(substr $buf, $pos++, 1);
        $count++;
        if ($shift > 55) {                       # past the IV-safe range: exact string math
            $acc = _shift_add("$acc", $b & 0x7F, $shift / 7);
        }
        else {
            $acc += ($b & 0x7F) << $shift;
        }
        die "protobuf: varint too long\n" if $count == 10 && ($b & 0x80);
        last unless $b & 0x80;
        $shift += 7;
    }
    return ("$acc", $pos);
}

# ---- decimal-string helpers: only reached for values past IV-safe range ------

sub _dec_add {   # x + y for canonical digit strings
    my ($x, $y) = @_;
    my @a = reverse split //, $x;
    my @b = reverse split //, $y;
    my (@out, $carry);
    for my $i (0 .. (@a > @b ? $#a : $#b)) {
        my $s = ($a[$i] // 0) + ($b[$i] // 0) + ($carry // 0);
        push @out, $s % 10;
        $carry = int($s / 10);
    }
    while ($carry) { push @out, $carry % 10; $carry = int($carry / 10) }
    my $s = join '', reverse @out;
    $s =~ s/^0+//;
    return $s eq '' ? '0' : $s;
}

sub _dec_mul_small {    # digit string * small non-negative int
    my ($dec, $m) = @_;
    return '0' if $dec eq '0' || $m == 0;
    my $carry = 0;
    my @out;
    for my $d (reverse split //, $dec) {
        $carry += $d * $m;
        push @out, $carry % 10;
        $carry = int($carry / 10);
    }
    while ($carry) { push @out, $carry % 10; $carry = int($carry / 10) }
    return join '', reverse @out;
}

sub _shift_add {    # dec + chunk * 128**pow, exact decimal strings
    my ($dec, $chunk, $pow) = @_;
    my $term = '1';
    $term = _dec_mul_small($term, 128) for 1 .. $pow;
    return _dec_add($dec, _dec_mul_small($term, $chunk));
}

sub _dec_sub {   # x - y for canonical digit strings with x >= y
    my ($x, $y) = @_;
    my @a = reverse split //, $x;
    my @b = reverse split //, $y;
    my (@out, $borrow);
    for my $i (0 .. $#a) {
        my $d = ($a[$i] // 0) - ($b[$i] // 0) - ($borrow // 0);
        $borrow = $d < 0 ? 1 : 0;
        $d += 10 if $borrow;
        push @out, $d;
    }
    die "protobuf: decimal underflow\n" if $borrow;
    my $s = join '', reverse @out;
    $s =~ s/^0+//;
    return $s eq '' ? '0' : $s;
}

sub _dec_to_varint {    # canonical decimal string -> varint bytes
    my ($dec) = @_;
    my $s = $dec;
    my @bytes;
    while ($s ne '0') {
        my ($rem, $q) = (0, '');
        for my $ch (split //, $s) {
            my $cur = $rem * 10 + $ch;
            $q .= int($cur / 128);
            $rem = $cur % 128;
        }
        $q =~ s/^0+//;
        push @bytes, $rem;
        $s = $q eq '' ? '0' : $q;
    }
    return "\x00" unless @bytes;
    my $out = '';
    $out .= chr($bytes[$_ ] | 0x80) for 0 .. $#bytes - 1;
    return $out . chr($bytes[-1]);
}

sub _to_number {    # unsigned decimal string -> IV (signed 64 interpretation past 2^63)
    my ($dec) = @_;
    return 0 + $dec if length($dec) < 19 || (length($dec) == 19 && $dec le $I64_MAX);
    return -(0 + _dec_sub($TWO64, $dec));
}

sub _to_i64_string {    # same, but the digit-string the JSON contract wants
    my ($dec) = @_;
    return $dec if length($dec) < 19 || (length($dec) == 19 && $dec le $I64_MAX);
    return '-' . _dec_sub($TWO64, $dec);
}

sub _enum_name {
    my ($table, $num) = @_;
    return Plugins::yandex::Ynison::Grpc::Schema::enum_name($table, $num);
}

# ---- decoding ----------------------------------------------------------------

sub _dec {
    my ($schema, $table, $buf, $pos, $end, $msg) = @_;
    my %by_num = map { $_->[1] => $_ } @$table;
    my $out = {};
    while ($pos < $end) {
        my ($tag, $next) = _varint_dec($buf, $pos, $end);
        my $num = $tag >> 3;
        my $wt  = $tag & 7;
        die "protobuf: field number 0\n" if $num == 0;
        die "protobuf: field number $num above $MAX_FIELD\n" if $num > $MAX_FIELD;
        $pos = $next;
        my $f = $by_num{$num};
        if (!$f) { $pos = _skip($buf, $pos, $wt, $end); next }
        my ($name, undef, $kind, $ref) = @$f;
        unless ($kind eq 'packed_varint' ? ($wt == 2 || $wt == 0) : $wt == ($WIRE_TYPE{$kind} // -1)) {
            die "protobuf: field $name got wire type $wt, expected $WIRE_TYPE{$kind}\n";
        }
        if ($kind eq 'varint' || $kind eq 'varint_i64' || $kind eq 'bool' || $kind eq 'varint_enum') {
            my ($dec, $after) = _varint_dec($buf, $pos, $end);
            $pos = $after;
            if    ($kind eq 'varint')      { $out->{$name} = _to_number($dec) }
            elsif ($kind eq 'varint_i64')  { $out->{$name} = _to_i64_string($dec) }
            elsif ($kind eq 'bool')        { $out->{$name} = $dec eq '0' ? \0 : \1 }
            else                           { $out->{$name} = _enum_name($ref, _to_number($dec)) }
        }
        elsif ($kind eq 'double') {
            die "protobuf: truncated double\n" if $pos + 8 > $end;
            $out->{$name} = unpack('d<', substr($buf, $pos, 8));
            $pos += 8;
        }
        elsif ($kind eq 'string') {
            (my $payload, $pos) = _ld($buf, $pos, $end);
            $out->{$name} = Encode::decode_utf8($payload);
        }
        elsif ($kind eq 'bytes') {
            (my $payload, $pos) = _ld($buf, $pos, $end);
            $out->{$name} = $payload;
        }
        elsif ($kind eq 'string_value') {
            (my $payload, $pos) = _ld($buf, $pos, $end);
            $out->{$name} = _dec_string_value($payload);
        }
        elsif ($kind eq 'message' || $kind eq 'message_list') {
            (my $payload, $pos) = _ld($buf, $pos, $end);
            my $sub = $schema->{$ref};
            next unless $sub;    # out-of-scope table: skipped like an unknown field
            my ($decoded) = _dec($schema, $sub, $payload, 0, length($payload), $ref);
            if    ($kind eq 'message')      { $out->{$name} = $decoded }   # last one wins
            else                            { push @{ $out->{$name} }, $decoded }
        }
        elsif ($kind eq 'packed_varint') {
            if ($wt == 2) {
                (my $payload, $pos) = _ld($buf, $pos, $end);
                my $p = 0;
                my $e = length $payload;
                while ($p < $e) {
                    my ($dec, $after) = _varint_dec($payload, $p, $e);
                    $p = $after;
                    push @{ $out->{$name} }, defined $ref ? _enum_name($ref, _to_number($dec)) : _to_number($dec);
                }
            }
            else {    # the unpacked form: one value per occurrence
                my ($dec, $after) = _varint_dec($buf, $pos, $end);
                $pos = $after;
                push @{ $out->{$name} }, defined $ref ? _enum_name($ref, _to_number($dec)) : _to_number($dec);
            }
        }
        elsif ($kind eq 'string_list') {
            (my $payload, $pos) = _ld($buf, $pos, $end);
            push @{ $out->{$name} }, Encode::decode_utf8($payload);
        }
        else {
            die "protobuf: unknown wire kind '$kind'\n";
        }
    }
    _fill_defaults($table, $out);
    return ($out, $pos);
}

# proto3 defaults for the scalars the schema knows; presence-typed fields
# (message, string_value) stay absent.
sub _fill_defaults {
    my ($table, $out) = @_;
    for my $f (@$table) {
        my ($name, undef, $kind, $ref) = @$f;
        next if exists $out->{$name};
        if    ($kind eq 'varint')      { $out->{$name} = 0 }
        elsif ($kind eq 'varint_i64')  { $out->{$name} = '0' }
        elsif ($kind eq 'double')      { $out->{$name} = 0 }
        elsif ($kind eq 'bool')        { $out->{$name} = \0 }
        elsif ($kind eq 'string')      { $out->{$name} = '' }
        elsif ($kind eq 'bytes')       { $out->{$name} = '' }
        elsif ($kind eq 'varint_enum') { $out->{$name} = _enum_name($ref, 0) }
        elsif ($kind eq 'message_list' || $kind eq 'packed_varint' || $kind eq 'string_list') {
            $out->{$name} = [];
        }
    }
    return $out;
}

sub _dec_string_value {
    my ($payload) = @_;
    my ($value, $p, $e) = ('', 0, length $payload);
    while ($p < $e) {
        my ($tag, $next) = _varint_dec($payload, $p, $e);
        my $num = $tag >> 3;
        my $wt  = $tag & 7;
        $p = $next;
        if ($num == 1 && $wt == 2) {
            (my $s, $p) = _ld($payload, $p, $e);
            $value = Encode::decode_utf8($s);
        }
        else {
            $p = _skip($payload, $p, $wt, $e);
        }
    }
    return $value;
}

sub _ld {
    my ($buf, $pos, $end) = @_;
    my ($len, $next) = _varint_dec($buf, $pos, $end);
    my $n = _to_number($len);
    die "protobuf: truncated message (length $len overruns the buffer)\n" if $n < 0 || $next + $n > $end;
    return (substr($buf, $next, $n), $next + $n);
}

sub _skip {    # unknown field: jump over it by wire type
    my ($buf, $pos, $wt, $end) = @_;
    my $junk;
    if ($wt == 0) {
        ($junk, $pos) = _varint_dec($buf, $pos, $end);
    }
    elsif ($wt == 1) {
        die "protobuf: truncated fixed64\n" if $pos + 8 > $end;
        $pos += 8;
    }
    elsif ($wt == 2) {
        ($junk, $pos) = _ld($buf, $pos, $end);
    }
    elsif ($wt == 5) {
        die "protobuf: truncated fixed32\n" if $pos + 4 > $end;
        $pos += 4;
    }
    else {
        die "protobuf: group wire type is not supported\n";
    }
    return $pos;
}

1;
