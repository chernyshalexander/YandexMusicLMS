#!/usr/bin/perl
=encoding utf8

=head1 NAME

ynison_observer.pl - Passive Ynison event observer for debugging

=head1 SYNOPSIS

  perl ynison_observer.pl [options]

  Options:
    --token FILE   Path to OAuth token file (default: token.txt)
    --raw          Also dump full raw JSON (verbose)
    --log FILE     Also write JSONL log to file

=head1 DESCRIPTION

Connects to Yandex Ynison as a passive observer (non-player device).
Dumps all incoming messages with timestamps.

Designed to capture real event flows:
  - Initial state on connect
  - Cast events (active_device_id changes)
  - PLAY/PAUSE/NEXT/PREV commands
  - Queue changes
  - Device connect/disconnect

Use this BEFORE implementing new logic to understand what Yandex actually sends.

=cut

use strict;
use warnings;
use utf8;
use IO::Socket::SSL;
use JSON::PP;
use MIME::Base64;
use Time::HiRes qw(time gettimeofday);
use POSIX qw(strftime);
use Encode qw(encode decode);
use Getopt::Long;

binmode(STDOUT, ':utf8');

# --- Options ---
my $token_file = 'token.txt';
my $raw_mode   = 0;
my $log_file   = '';

GetOptions(
    'token=s' => \$token_file,
    'raw'     => \$raw_mode,
    'log=s'   => \$log_file,
) or die "Usage: $0 [--token FILE] [--raw] [--log FILE]\n";

# Read token
open(my $fh, '<', $token_file) or die "Cannot open token file '$token_file': $!\n";
my $token = <$fh>;
close($fh);
$token =~ s/\s+//g;
die "Token is empty in '$token_file'\n" unless $token;

# Open log file if requested
my $log_fh;
if ($log_file) {
    open($log_fh, '>', $log_file) or die "Cannot open log file '$log_file': $!\n";
    $log_fh->autoflush(1);
    print "Logging to: $log_file\n";
}

# --- State tracking (for diff display) ---
my $prev_state = {
    active_device_id => '',
    entity_id        => '',
    current_index    => -1,
    paused           => undef,
    track_id         => '',
    queue_size       => 0,
    device_ids       => [],
};

my $msg_count = 0;

# --- Helper: timestamp ---
sub ts {
    my ($sec, $usec) = gettimeofday();
    my $ms = int($usec / 1000);
    return strftime("%H:%M:%S", localtime($sec)) . sprintf(".%03d", $ms);
}

# --- Helper: colored output ---
sub color {
    my ($code, $text) = @_;
    return "\e[${code}m${text}\e[0m";
}

sub green  { color("32", $_[0]) }
sub yellow { color("33", $_[0]) }
sub red    { color("31", $_[0]) }
sub cyan   { color("36", $_[0]) }
sub bold   { color("1",  $_[0]) }
sub dim    { color("2",  $_[0]) }

# --- Message analysis ---
sub analyze_message {
    my ($msg, $raw_json) = @_;

    $msg_count++;
    my $ts = ts();

    print "\n" . ("─" x 70) . "\n";
    print bold("[$ts] MSG #$msg_count") . "\n";

    # Log to file
    if ($log_fh) {
        my $log_entry = {
            ts  => $ts,
            num => $msg_count,
            msg => $msg,
        };
        print $log_fh encode_json($log_entry) . "\n";
    }

    # --- Active device ---
    my $active_id = $msg->{active_device_id_optional} // '';
    if ($active_id ne $prev_state->{active_device_id}) {
        print yellow("  ACTIVE DEVICE CHANGED: ") .
              dim($prev_state->{active_device_id} || "(none)") .
              " → " . bold($active_id || "(none)") . "\n";
        $prev_state->{active_device_id} = $active_id;
    } else {
        print dim("  active_device_id: " . ($active_id || "(none)")) . "\n";
    }

    # --- Devices list ---
    if ($msg->{devices} && ref($msg->{devices}) eq 'ARRAY') {
        my @devs = @{$msg->{devices}};
        my @dev_ids = map { $_->{info}{device_id} // '' } @devs;

        print "  Devices (" . scalar(@devs) . "):\n";
        for my $dev (@devs) {
            my $info   = $dev->{info} // {};
            my $did    = $info->{device_id} // '?';
            my $title  = $info->{title}     // '?';
            my $type   = $info->{type}      // '?';
            my $vol    = $dev->{volume_info}{volume} // $dev->{volume} // '?';
            my $active = ($did eq $active_id) ? green(" ◄ ACTIVE") : "";
            printf("    %-40s  type=%-8s  vol=%.2f%s\n",
                "\"$title\" [$did]", $type, $vol, $active);
        }
    }

    # --- Player state ---
    my $ps = $msg->{player_state};
    if (!$ps && $msg->{update_full_state}) {
        $ps = $msg->{update_full_state}{player_state};
        print cyan("  [update_full_state]") . "\n";
    }

    if ($ps) {
        my $queue  = $ps->{player_queue} // {};
        my $status = $ps->{status}       // {};

        # Entity (album/playlist)
        my $entity_id   = $queue->{entity_id}   // '';
        my $entity_type = $queue->{entity_type} // '';
        if ($entity_id ne $prev_state->{entity_id}) {
            print yellow("  ENTITY CHANGED: ") .
                  dim($prev_state->{entity_id} || "(none)") .
                  " → " . bold("$entity_id ($entity_type)") . "\n";
            $prev_state->{entity_id} = $entity_id;
        } else {
            print dim("  entity_id: $entity_id ($entity_type)") . "\n";
        }

        # Queue
        my $list  = $queue->{playable_list} // [];
        my $idx   = $queue->{current_playable_index} // -1;
        my $qsize = scalar(@$list);

        if ($qsize != $prev_state->{queue_size}) {
            print yellow("  QUEUE SIZE CHANGED: ") .
                  $prev_state->{queue_size} . " → " . bold($qsize) . "\n";
            $prev_state->{queue_size} = $qsize;
        }

        if ($qsize > 0 && $idx >= 0 && $idx < $qsize) {
            my $track = $list->[$idx];
            my $tid   = $track->{playable_id} // '?';
            my $title = $track->{title}       // '?';
            my $from  = $track->{from}        // '?';

            if ($tid ne $prev_state->{track_id}) {
                print yellow("  TRACK CHANGED: ") .
                      dim($prev_state->{track_id} || "(none)") .
                      " → " . bold("\"$title\" [$tid]") . "\n";
                print "    from: $from\n";
                $prev_state->{track_id} = $tid;
            } else {
                print dim("  track: \"$title\" [$tid]  (idx=$idx/$qsize)") . "\n";
            }
        } elsif ($qsize == 0) {
            print dim("  track: (empty queue)") . "\n";
        }

        if ($idx != $prev_state->{current_index}) {
            print yellow("  INDEX CHANGED: ") .
                  $prev_state->{current_index} . " → " . bold($idx) .
                  " (of $qsize)\n";
            $prev_state->{current_index} = $idx;
        }

        # Play/pause status
        my $paused   = $status->{paused} ? 1 : 0;
        my $prog_ms  = $status->{progress_ms} // 0;
        my $dur_ms   = $status->{duration_ms} // 0;
        $prog_ms =~ s/[^\d]//g;
        $dur_ms  =~ s/[^\d]//g;
        my $prog_s = int(($prog_ms || 0) / 1000);
        my $dur_s  = int(($dur_ms  || 0) / 1000);

        my $state_str = $paused ? red("PAUSED") : green("PLAYING");

        if (!defined $prev_state->{paused} || $paused != $prev_state->{paused}) {
            print yellow("  STATE CHANGED: ") . bold($state_str) .
                  "  pos=${prog_s}s / ${dur_s}s\n";
            $prev_state->{paused} = $paused;
        } else {
            print dim("  state: $state_str  pos=${prog_s}s / ${dur_s}s") . "\n";
        }

        # Queue version (who last changed it)
        if ($queue->{version}) {
            my $qver = $queue->{version};
            print dim("  queue.version.device_id: " . ($qver->{device_id} // '?')) . "\n";
        }
        if ($status->{version}) {
            my $sver = $status->{version};
            print dim("  status.version.device_id: " . ($sver->{device_id} // '?')) . "\n";
        }
    }

    # --- put_commands ---
    if ($msg->{put_commands} && ref($msg->{put_commands}) eq 'ARRAY') {
        for my $cmd_obj (@{$msg->{put_commands}}) {
            my $cmd = $cmd_obj->{command} // 'UNKNOWN';
            print bold(red("  ► put_command: $cmd")) . "\n";
        }
    }

    # --- Other top-level keys (unknown/unexpected) ---
    my %known = map { $_ => 1 } qw(
        player_state update_full_state devices active_device_id_optional
        put_commands timestamp_ms rid error
    );
    for my $key (sort keys %$msg) {
        next if $known{$key};
        print cyan("  [unexpected key] $key: ") .
              substr(encode_json($msg->{$key}), 0, 120) . "\n";
    }

    # --- Raw JSON ---
    if ($raw_mode) {
        print dim("\n  RAW JSON:\n");
        # Pretty print
        my $json = JSON::PP->new->utf8->pretty->canonical;
        eval { print dim($json->encode($msg)) };
    }
}

# --- WebSocket frame encoder ---
sub encode_ws_frame {
    my ($data) = @_;
    my $len = length($data);
    my $header;
    if ($len <= 125)     { $header = pack("CC", 0x81, 0x80 | $len); }
    elsif ($len <= 65535){ $header = pack("CCn", 0x81, 0x80 | 126, $len); }
    else                 { die "Frame too large\n"; }
    my $mask = pack("N", int(rand(0xffffffff)));
    $header .= $mask;
    my @m = unpack("C4", $mask);
    my @d = unpack("C*", $data);
    for (my $i = 0; $i < @d; $i++) { $d[$i] ^= $m[$i % 4]; }
    return $header . pack("C*", @d);
}

# --- Read exactly N bytes (blocking) ---
sub read_exact {
    my ($sock, $n) = @_;
    my $buf = '';
    while (length($buf) < $n) {
        my $chunk;
        my $got = $sock->read($chunk, $n - length($buf));
        die "Connection closed\n" unless defined $got && $got > 0;
        $buf .= $chunk;
    }
    return $buf;
}

# --- Read one WebSocket frame (blocking) ---
sub read_ws_frame {
    my ($sock) = @_;
    my $header = read_exact($sock, 2);
    my ($b1, $b2) = unpack("CC", $header);
    my $opcode = $b1 & 0x0F;
    my $masked  = $b2 & 0x80;
    my $len     = $b2 & 0x7F;

    if ($len == 126) {
        $len = unpack("n", read_exact($sock, 2));
    } elsif ($len == 127) {
        my $ext = read_exact($sock, 8);
        $len = unpack("N", substr($ext, 4, 4));
    }

    my $mask_bytes = '';
    if ($masked) {
        $mask_bytes = read_exact($sock, 4);
    }

    my $payload = read_exact($sock, $len);

    if ($masked) {
        my @m = unpack("C4", $mask_bytes);
        my @d = unpack("C*", $payload);
        for (my $i = 0; $i < @d; $i++) { $d[$i] ^= $m[$i % 4]; }
        $payload = pack("C*", @d);
    }

    return ($opcode, $payload);
}

# --- Connect and run ---
sub connect_and_observe {
    my ($host, $path, $extra) = @_;

    my $device_id = sprintf("observer-%08x%08x", rand(0xffffffff), rand(0xffffffff));

    my $device_info_esc = '{\\"app_name\\":\\"Chrome\\",\\"type\\":1}';
    my $handshake = sprintf(
        '{"Ynison-Device-Info":"{\"app_name\":\"Chrome\",\"type\":1}","Ynison-Device-Id":"%s"',
        $device_id
    );

    if ($extra && $extra->{ticket}) {
        $handshake .= sprintf(',"Ynison-Redirect-Ticket":"%s"', $extra->{ticket});
    }
    if ($extra && $extra->{session_id}) {
        $handshake .= sprintf(',"Ynison-Session-Id":"%s"', $extra->{session_id});
    }
    $handshake .= sprintf(',"authorization":"OAuth %s"', $token);
    $handshake .= '}';

    my $protocol_header = "Bearer, v2, $handshake";

    my @hex = (0..9, 'a'..'f');
    my $ws_key = encode_base64(pack("H*", join('', map { $hex[rand @hex] } 1..32)), "");
    $ws_key =~ s/\s+//g;

    print dim("  Connecting to $host...\n");
    my $sock = IO::Socket::SSL->new(
        PeerHost        => $host,
        PeerPort        => 443,
        SSL_verify_mode => SSL_VERIFY_NONE,
        Timeout         => 15,
    ) or die "SSL connect failed: $!\n";

    my $request =
        "GET $path HTTP/1.1\r\n" .
        "Host: $host\r\n" .
        "Upgrade: websocket\r\n" .
        "Connection: Upgrade\r\n" .
        "Sec-WebSocket-Key: $ws_key\r\n" .
        "Sec-WebSocket-Version: 13\r\n" .
        "Sec-WebSocket-Protocol: $protocol_header\r\n" .
        "Authorization: OAuth $token\r\n" .
        "Origin: https://music.yandex.ru\r\n" .
        "\r\n";

    print $sock $request;

    # Read HTTP response headers
    my $response = '';
    while (1) {
        my $line;
        $sock->read($line, 1);
        $response .= $line;
        last if $response =~ /\r\n\r\n$/;
    }

    unless ($response =~ /HTTP\/1.1 101/) {
        my ($status) = $response =~ /^(HTTP\/1\.1 \d+ .+)/m;
        die "WebSocket upgrade failed: " . ($status // "unknown") . "\n";
    }

    return ($sock, $device_id);
}

# =====================================================================
# MAIN
# =====================================================================

print bold(green("Ynison Observer")) . " — passive debug listener\n";
print "Token: " . substr($token, 0, 8) . "...\n\n";

# Step 1: Redirector
print bold("[Step 1]") . " Connecting to redirector...\n";
my ($rsock) = connect_and_observe(
    "ynison.music.yandex.ru",
    "/redirector.YnisonRedirectService/GetRedirectToYnison"
);

my ($opcode, $payload) = read_ws_frame($rsock);
die "Expected text frame from redirector\n" unless $opcode == 1;

my $redirect = decode_json($payload);
die "No host in redirect response\n" unless $redirect->{host};

my $state_host   = $redirect->{host};
my $redirect_ticket = $redirect->{redirect_ticket};
my $session_id   = $redirect->{session_id};

$state_host =~ s{^(wss?|https?)://}{};
$state_host =~ s{/+$}{};

print green("  Redirected to: $state_host\n");
print dim("  ticket: " . substr($redirect_ticket, 0, 20) . "...\n");
print dim("  keep_alive: " . ($redirect->{keep_alive_params}{keep_alive_time_seconds} // '?') . "s\n");
$rsock->close();

# Step 2: State service
print bold("\n[Step 2]") . " Connecting to state service...\n";
my ($sock, $device_id) = connect_and_observe(
    $state_host,
    "/ynison_state.YnisonStateService/PutYnisonState",
    { ticket => $redirect_ticket, session_id => $session_id }
);
print green("  Connected! device_id=$device_id\n");

# Send UpdateFullState — register as passive (non-playing) observer
my $ts_ms = int(time() * 1000);
my $full_state_msg = {
    update_full_state => {
        player_state => {
            status => {
                paused          => JSON::PP::true,
                duration_ms     => "0",
                progress_ms     => "0",
                playback_speed  => 1,
                version => {
                    device_id    => $device_id,
                    version      => int(time() * 1000000),
                    timestamp_ms => "0",
                }
            },
            player_queue => {
                current_playable_index  => -1,
                entity_id               => "",
                entity_type             => "VARIOUS",
                playable_list           => [],
                options                 => { repeat_mode => "NONE" },
                entity_context          => "BASED_ON_ENTITY_BY_DEFAULT",
                from_optional           => "",
                version => {
                    device_id    => $device_id,
                    version      => int(time() * 1000000),
                    timestamp_ms => "0",
                }
            }
        },
        device => {
            capabilities => {
                can_be_player            => JSON::PP::false,
                can_be_remote_controller => JSON::PP::false,
                volume_granularity       => 0,
            },
            info => {
                device_id   => $device_id,
                type        => "WEB",
                title       => "Ynison Observer (debug)",
                app_name    => "Chrome",
            },
            volume_info => { volume => 0 },
            is_shadow   => JSON::PP::true,
        },
        is_currently_active => JSON::PP::false,
    },
    rid                        => sprintf("%08x-%04x-%04x-%04x-%06x%06x",
        int(rand(0xffffffff)), int(rand(0xffff)), int(rand(0xffff)),
        int(rand(0xffff)), int(rand(0xffffff)), int(rand(0xffffff))),
    player_action_timestamp_ms => "$ts_ms",
    activity_interception_type => "DO_NOT_INTERCEPT_BY_DEFAULT",
};

my $json_enc = JSON::PP->new->utf8->canonical;
my $frame = encode_ws_frame($json_enc->encode($full_state_msg));
$sock->print($frame);

print green("  Registered as passive observer. Waiting for events...\n");
print dim("  (Press Ctrl+C to stop)\n\n");
print "  " . bold("NOW: cast music to any device from Yandex app to see events\n");

# =====================================================================
# Event loop
# =====================================================================
$SIG{INT} = sub {
    print "\n\n" . bold("Stopped. Total messages: $msg_count\n");
    $sock->close() if $sock;
    close($log_fh) if $log_fh;
    exit 0;
};

while (1) {
    my ($op, $data) = eval { read_ws_frame($sock) };
    if ($@) {
        print red("\nConnection error: $@\n");
        last;
    }

    if ($op == 1) {  # Text frame
        my $msg = eval { decode_json($data) };
        if ($@) {
            print red("JSON decode error: $@\n");
            print dim("Raw: " . substr($data, 0, 200) . "\n");
            next;
        }
        analyze_message($msg, $data);

    } elsif ($op == 8) {  # Close
        my $code   = length($data) >= 2 ? unpack("n", substr($data, 0, 2)) : 0;
        my $reason = length($data) >  2 ? substr($data, 2) : '';
        print red("\nServer closed connection: code=$code reason=$reason\n");
        last;

    } elsif ($op == 9) {  # Ping
        print dim("[ping received, sending pong]\n");
        $sock->print(pack("CC", 0x8A, 0));

    } elsif ($op == 10) {  # Pong
        print dim("[pong]\n");
    }
}

$sock->close() if $sock;
close($log_fh) if $log_fh;
print bold("Session ended. $msg_count messages received.\n");
