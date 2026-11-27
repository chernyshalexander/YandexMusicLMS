package Plugins::yandex::Ynison::Message;

=encoding utf8

=head1 NAME

Plugins::yandex::Ynison::Message - builders and parsers of the Ynison protobuf-JSON protocol

=head1 DESCRIPTION

Builders for the requests the client sends, the request envelope, the
int64-as-string rules of the protobuf-JSON bridge, the handshake header and
request, and the parsers for the frames the server sends. Pure functions:
no I/O and no LMS here.

=cut

# Builders for the requests the client sends, the request envelope, the
# int64-as-string rules of the protobuf-JSON bridge, the handshake header and
# request, and the parsers for the frames the server sends. Pure functions:
# no I/O and no LMS here.

use strict;
use warnings;

use Exporter ();
use MIME::Base64 ();
use Time::HiRes qw(gettimeofday);

use Plugins::yandex::Ynison::Constants ();

our @ISA       = ('Exporter');
our @EXPORT_OK = qw(new_rid new_version now_ms i64 truth ws_key
                    envelope update_full_state update_player_state update_playing_status
                    update_active_device update_session_params update_volume_info
                    empty_player_state device_block clamp_progress normalize_player_state
                    protocol_header upgrade_request parse_frame error_details);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

my $C   = 'Plugins::yandex::Ynison::Constants';
my $SEQ = 0;

sub new_rid {
    my @hex  = ('0' .. '9', 'a' .. 'f');
    my $part = sub { join '', map { $hex[int(rand(16))] } 1 .. $_[0] };
    return sprintf('%s-%s-4%s-%s%s-%s',
        $part->(8), $part->(4), $part->(3), $hex[8 + int(rand(4))], $part->(3), $part->(12));
}

sub _now_parts { return gettimeofday() }

sub now_ms {
    my ($sec, $usec) = _now_parts();
    return sprintf('%d%03d', $sec, int($usec / 1000));
}

# {device_id, version, timestamp_ms}. The version has 19 digits: seconds,
# microseconds and a per-process counter, so it grows with time and the server
# takes a later edit for a newer one. Kept as a string: it does not fit a double.
sub new_version {
    my ($device_id) = @_;
    my ($sec, $usec) = _now_parts();
    $SEQ = ($SEQ + 1) % 1000;
    return {
        device_id    => "$device_id",
        version      => sprintf('%d%06d%03d', $sec, $usec, $SEQ),
        timestamp_ms => sprintf('%d%03d', $sec, int($usec / 1000)),
    };
}

# int64 on the wire: always a plain string of digits, never a Perl number.
sub i64 {
    my ($v) = @_;
    return "$v" if defined $v && !ref $v && ($v =~ /^[1-9]\d{0,18}$/ || $v eq '0');
    my $n = 0;
    {
        no warnings 'numeric';    # garbage in, zero out: perl's own conversion, silently
        $n = defined $v && !ref $v ? $v + 0 : 0;
    }
    $n = 0 if $n < 0;
    return $n < 1e15 ? int($n) . '' : sprintf('%.0f', $n);
}

# The JSON contract carries booleans as references (\1 / \0): JSON::XS::Boolean
# from the WebSocket gateway and plain \1 / \0 from the gRPC protobuf decoder.
# JSON booleans are false-aware, plain references are TRUE to Perl truth, so
# every consumer of an inbound boolean must unwrap it here - a bare
# `$status->{paused} ?` is always true under the gRPC transport (the cast-never
# -plays bug of 2026-11-27). Scalars pass through so LMS-side 0/1 works too.
sub truth {
    my ($v) = @_;
    return ref $v ? ($$v ? 1 : 0) : ($v ? 1 : 0);
}

sub ws_key {
    my $key = pack('C16', map { int(rand(256)) } 1 .. 16);
    return MIME::Base64::encode_base64($key, '');
}

sub _bool { $_[0] ? \1 : \0 }

# Every outbound message: one parameters key plus the envelope.
sub envelope {
    my ($payload, %o) = @_;
    return {
        %$payload,
        rid                        => new_rid(),
        player_action_timestamp_ms => now_ms(),
        activity_interception_type => $o{interception} // $C->INTERCEPT_NONE(),
    };
}

sub update_full_state {
    my (%a) = @_;
    return envelope({ update_full_state => {
        player_state        => $a{player_state} || empty_player_state($a{device}{info}{device_id}),
        device              => $a{device},
        is_currently_active => \0,
    } });
}

sub update_player_state { envelope({ update_player_state => { player_state => $_[0] } }) }

sub update_playing_status {
    my (%a) = @_;
    my $paused = $a{paused} ? 1 : 0;
    my $progress = clamp_progress($a{progress_ms}, $a{duration_ms});   # Constraint 5, enforced here
    my $status = {
        progress_ms    => i64($progress),
        duration_ms    => i64($a{duration_ms}),
        paused         => _bool($paused),
        playback_speed => 1.0,
    };
    $status->{version} = $a{version} if ref $a{version} eq 'HASH';
    my $interception = exists $a{interception} ? $a{interception}
        : ($paused ? $C->INTERCEPT_NONE() : $C->INTERCEPT_IF_FREE());
    return envelope({ update_playing_status => { playing_status => $status } }, interception => $interception);
}

sub update_active_device  { envelope({ update_active_device  => { device_id_optional => "$_[0]" } }) }
sub update_session_params { envelope({ update_session_params => { mute_events_if_passive => _bool($_[0]) } }) }

sub update_volume_info {
    my ($device_id, $volume, $version) = @_;
    return envelope({ update_volume_info => {
        device_id   => "$device_id",
        volume_info => { volume => 0 + $volume, version => $version },
    } });
}

sub empty_player_state {
    my ($device_id) = @_;
    return {
        status => {
            paused         => \1,
            progress_ms    => '0',
            duration_ms    => '0',
            playback_speed => 1.0,
            version        => new_version($device_id),
        },
        player_queue => {
            current_playable_index    => -1,
            playable_list             => [],
            options                   => { repeat_mode => 'NONE' },
            entity_id                 => '',
            entity_type               => 'VARIOUS',
            entity_context            => 'BASED_ON_ENTITY_BY_DEFAULT',
            from_optional             => '',
            version                   => new_version($device_id),
        },
    };
}

sub device_block {
    my (%a) = @_;
    return {
        info => {
            device_id   => "$a{device_id}",
            title       => "$a{title}",
            type        => $C->DEVICE_TYPE_WEB(),
            app_name    => defined $a{app_name} ? "$a{app_name}" : $C->APP_NAME(),
            app_version => defined $a{app_version} ? "$a{app_version}" : $C->APP_VERSION(),
        },
        capabilities => {
            can_be_player            => _bool(exists $a{can_be_player} ? $a{can_be_player} : 1),
            can_be_remote_controller => _bool($a{can_be_remote_controller}),
            volume_granularity       => 0 + ($a{volume_granularity} // $C->VOLUME_GRANULARITY()),
        },
        volume_info => { volume => 0 + ($a{volume} // 0) },
    };
}

sub clamp_progress {
    my ($progress, $duration) = @_;
    $progress = 0 + $progress;
    $progress = 0 if $progress < 0;
    $progress = 0 + $duration if $duration > 0 && $progress > $duration;
    return int $progress;
}

sub _stringify_version {
    my ($v) = @_;
    return unless ref $v eq 'HASH';
    $v->{$_} = i64($v->{$_}) for grep { exists $v->{$_} } qw(version timestamp_ms);
    return;
}

# Inbound state may carry int64 as JSON numbers; the bridge rejects numbers on
# the way out, so they are stringified once, at the ingestion boundary.
sub normalize_player_state {
    my ($ps) = @_;
    return $ps unless ref $ps eq 'HASH';
    my $s = $ps->{status};
    if (ref $s eq 'HASH') {
        $s->{$_} = i64($s->{$_}) for grep { exists $s->{$_} } qw(progress_ms duration_ms);
        _stringify_version($s->{version});
    }
    _stringify_version($ps->{player_queue}{version}) if ref $ps->{player_queue} eq 'HASH';
    return $ps;
}

# The JSON carried in the Sec-WebSocket-Protocol header, in the shape the
# legacy module uses (see constraint 6 and check V7).
sub protocol_header {
    my (%a) = @_;
    my %proto = (
        'Ynison-Device-Id'   => "$a{device_id}",
        'Ynison-Device-Info' => JSON::XS::VersionOneAndTwo::encode_json({
            app_name    => "$a{app_name}",
            app_version => "$a{app_version}",
            type        => $C->DEVICE_TYPE_WEB_NUM(),
        }),
    );
    $proto{'Ynison-Redirect-Ticket'} = "$a{ticket}"     if defined $a{ticket};
    $proto{'Ynison-Session-Id'}      = "$a{session_id}" if defined $a{session_id};
    $proto{authorization} = 'OAuth ' . $a{token};
    $proto{'X-Yandex-Music-Multi-Auth-User-Id'} = "$a{user_id}" if defined $a{user_id} && length $a{user_id};
    return 'Bearer, v2, ' . JSON::XS::VersionOneAndTwo::encode_json(\%proto);
}

# headers: arrayref of [name, value] pairs, sent in the given order.
sub upgrade_request {
    my (%a) = @_;
    my $req = "GET $a{path} HTTP/1.1\r\n"
            . "Host: $a{host}\r\n"
            . "Upgrade: websocket\r\n"
            . "Connection: Upgrade\r\n"
            . "Sec-WebSocket-Key: $a{key}\r\n"
            . "Sec-WebSocket-Version: 13\r\n";
    $req .= "$_->[0]: $_->[1]\r\n" for @{ $a{headers} };
    return $req . "\r\n";
}

# ('state', $frame) ('error', $error) ('ping', 1) ('other', $frame)
sub parse_frame {
    my ($frame) = @_;
    return ('other', undef) unless ref $frame eq 'HASH';
    return ('error', $frame->{error}) if exists $frame->{error};
    return ('ping',  1)                if exists $frame->{ping};
    return ('state', $frame)
        if exists $frame->{player_state} || exists $frame->{devices} || exists $frame->{active_device_id_optional};
    return ('other', $frame);
}

sub error_details {
    my ($error) = @_;
    $error = {} unless ref $error eq 'HASH';
    my $src = ref $error->{details} eq 'HASH' ? $error->{details}
            : ref $error->{extra_headers} eq 'HASH' ? $error->{extra_headers} : {};
    my $code = defined $src->{'ynison-error-code'} ? "$src->{'ynison-error-code'}" : '';
    my $go   = defined $src->{'ynison-go-away-for-seconds'}
            && $src->{'ynison-go-away-for-seconds'} =~ /^\s*(\d+(?:\.\d+)?)\s*$/ ? 0 + $1 : 0;
    my $num = sub { defined $_[0] && "$_[0]" =~ /^\d+$/ ? 0 + $_[0] : undef };
    return {
        code          => $code,
        go_away_s     => $go,
        backoff_millis => defined $src->{'ynison-backoff-millis'} && !ref $src->{'ynison-backoff-millis'}
                       ? "$src->{'ynison-backoff-millis'}" : undef,
        grpc_code     => $num->($error->{grpc_code}),
        http_status   => $num->($error->{http_code}),
        message       => defined $error->{message} && !ref $error->{message} ? "$error->{message}" : '',
    };
}

1;
