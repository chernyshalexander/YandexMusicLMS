#!/usr/bin/perl

use strict;
use warnings;
use IO::Socket::SSL;
use JSON::PP;
use MIME::Base64;
use Time::HiRes qw(time);

# Usage: perl test_ynison.pl <token> <uid>
my $token = $ARGV[0] or die "Usage: $0 <token> <uid>\n";
my $uid = $ARGV[1] or die "Usage: $0 <token> <uid>\n";

my $device_id = sprintf("%08x%08x", rand(0xffffffff), rand(0xffffffff));
print "Device ID: $device_id\n";

# 1. Redirector Stage
my $redirect_host = "ynison.music.yandex.ru";
my $redirect_path = "/redirector.YnisonRedirectService/GetRedirectToYnison";

my $redirect_data = connect_and_handshake($redirect_host, $redirect_path, $token, $uid, $device_id);

if ($redirect_data && $redirect_data->{host} && $redirect_data->{redirect_ticket}) {
    print "SUCCESS! Host: $redirect_data->{host}, Ticket: $redirect_data->{redirect_ticket}\n";
    
    # 2. State Service Stage
    my $state_host = $redirect_data->{host};
    my $state_path = "/ynison_state.YnisonStateService/PutYnisonState";
    
    connect_and_handshake($state_host, $state_path, $token, $uid, $device_id, $redirect_data);
} else {
    print "Failed to get redirect data.\n";
}

sub connect_and_handshake {
    my ($host, $path, $token, $uid, $device_id, $extra) = @_;

    print "\nConnecting to $host...\n";
    my $socket = IO::Socket::SSL->new(
        PeerHost => $host,
        PeerPort => 443,
        SSL_verify_mode => SSL_VERIFY_NONE,
    ) or die "Failed to connect to $host: $!\n";

    my $ws_key = encode_base64(pack("H*", join('', map { sprintf("%02x", rand(256)) } 1..16)), "");
    $ws_key =~ s/\s+//g;

    my $device_info = '{"app_name":"Chrome","type":1}';
    my $handshake_data = {
        "Ynison-Device-Info" => $device_info,
        "Ynison-Device-Id" => $device_id,
        "authorization" => "OAuth $token",
        "X-Yandex-Music-Multi-Auth-User-Id" => $uid
    };

    if ($extra) {
        $handshake_data->{"Ynison-Redirect-Ticket"} = $extra->{redirect_ticket};
        $handshake_data->{"Ynison-Session-Id"} = $extra->{session_id} if $extra->{session_id};
    }

    my $handshake_json = encode_json($handshake_data);
    my $protocol_header = "Bearer, v2, $handshake_json";

    my $request = "GET $path HTTP/1.1\r\n" .
                  "Host: $host\r\n" .
                  "Upgrade: websocket\r\n" .
                  "Connection: Upgrade\r\n" .
                  "Sec-WebSocket-Key: $ws_key\r\n" .
                  "Sec-WebSocket-Version: 13\r\n" .
                  "Sec-WebSocket-Protocol: $protocol_header\r\n" .
                  "Authorization: OAuth $token\r\n" .
                  "Origin: https://music.yandex.ru\r\n" .
                  "\r\n";

    print "Sending Upgrade request...\n";
    print $socket $request;

    my $response = "";
    while (<$socket>) {
        $response .= $_;
        last if $_ =~ /^\r?\n$/;
    }

    if ($response =~ /HTTP\/1.1 101/) {
        print "Upgrade Successful! Waiting for JSON message...\n";
        
        # Read WebSocket frame
        my $frame_header;
        $socket->read($frame_header, 2);
        my ($b1, $b2) = unpack("CC", $frame_header);
        my $opcode = $b1 & 0x0F;
        my $masked = $b2 & 0x80;
        my $len = $b2 & 0x7F;

        if ($len == 126) {
            $socket->read(my $extended_len, 2);
            $len = unpack("n", $extended_len);
        } elsif ($len == 127) {
            $socket->read(my $extended_len, 8);
            # We only need the lower 4 bytes for JSON payloads usually
            $len = unpack("N", substr($extended_len, 4, 4));
        }

        my $mask;
        if ($masked) {
            $socket->read($mask, 4);
        }

        my $payload;
        $socket->read($payload, $len);

        if ($masked) {
            my @m = unpack("C4", $mask);
            my @d = unpack("C*", $payload);
            for (my $i = 0; $i < @d; $i++) {
                $d[$i] ^= $m[$i % 4];
            }
            $payload = pack("C*", @d);
        }

        print "Payload Length: $len\n";
        print "Received Payload: $payload\n";

        my $data = eval { decode_json($payload) };
        if ($@) {
            print "JSON Decode Error: $@\n";
            return;
        }

        return $data;
    } else {
        print "Upgrade Failed:\n$response\n";
        return;
    }
}
