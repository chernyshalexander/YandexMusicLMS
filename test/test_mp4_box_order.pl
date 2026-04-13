#!/usr/bin/perl
# Test: verify moov/mdat box order in Yandex FLAC-in-MP4 streams.
# Downloads the first ~128KB of an encrypted FLAC-in-MP4 track,
# decrypts it with AES128, then scans and reports all top-level box order.
#
# Usage: perl test_mp4_box_order.pl [track_id [track_id ...]]
# Token is read from test/token.txt

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/";
use HTTP::Tiny;
use JSON::PP;
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64);
use Time::HiRes qw(time);

# --- Config ---
my $SIGN_KEY   = 'p93jhgh689SBReK6ghtw62';
my $CODECS     = 'flac-mp4,flac,aac-mp4,aac,he-aac,mp3,he-aac-mp4';
my $TRANSPORT  = 'encraw';
my $FETCH_BYTES = 256 * 1024;   # 256KB — enough to find moov in any reasonable file

my @TRACK_IDS = @ARGV ? @ARGV : qw(16580941 47742192 103295791);

# --- Read token ---
my $token_file = "$FindBin::Bin/token.txt";
open my $fh, '<', $token_file or die "Cannot open $token_file: $!\n";
my $TOKEN = do { local $/; <$fh> };
close $fh;
$TOKEN =~ s/\s+//g;
die "Empty token in $token_file\n" unless length $TOKEN > 10;

# --- Load AES128 ---
require "$FindBin::Bin/AES128.pm";

my $http = HTTP::Tiny->new(
    default_headers => {
        'Authorization'         => "OAuth $TOKEN",
        'X-Yandex-Music-Client' => 'YandexMusicDesktopAppWindows/5.13.2',
    },
    timeout => 30,
);

for my $track_id (@TRACK_IDS) {
    print "\n" . "=" x 60 . "\n";
    print "Track: $track_id\n";
    print "=" x 60 . "\n";

    # --- 1. Get FLAC stream URL + AES key ---
    my $ts          = int(time());
    my $codecs_sign = $CODECS;
    $codecs_sign =~ s/,//g;
    my $param = "${ts}${track_id}lossless${codecs_sign}${TRANSPORT}";
    my $sign  = substr(encode_base64(hmac_sha256($param, $SIGN_KEY), ''), 0, 43);
    (my $codecs_esc = $CODECS) =~ s/([^a-zA-Z0-9._~-])/sprintf("%%%02X",ord($1))/eg;
    $sign =~ s/([^a-zA-Z0-9._~-])/sprintf("%%%02X",ord($1))/eg;

    my $api_url = "https://api.music.yandex.net/get-file-info"
        . "?ts=$ts&trackId=$track_id&quality=lossless"
        . "&codecs=$codecs_esc&transports=$TRANSPORT&sign=$sign";

    my $resp = $http->get($api_url);
    unless ($resp->{success}) {
        print "API request failed: $resp->{status} $resp->{content}\n";
        next;
    }

    my $data = eval { decode_json($resp->{content}) };
    if ($@) { print "JSON parse error: $@\n"; next; }

    my $di = $data->{result}{downloadInfo} // {};
    my $url    = $di->{url}    or do { print "No URL in response\n"; next };
    my $codec  = $di->{codec}  // '?';
    my $key_hex= $di->{key}    // '';

    printf "codec=%-12s  encrypted=%s\n", $codec, ($key_hex ? 'YES' : 'no');

    unless ($codec =~ /mp4/) {
        print "Not an MP4 container (codec=$codec) — skip box scan\n";
        next;
    }
    unless ($key_hex) {
        print "No AES key — cannot decrypt, skip\n";
        next;
    }

    # --- 2. Fetch first N bytes ---
    print "Fetching first " . int($FETCH_BYTES/1024) . "KB from CDN...\n";
    my $range_resp = $http->request('GET', $url, {
        headers => { Range => "bytes=0-" . ($FETCH_BYTES - 1) }
    });

    my $raw;
    if ($range_resp->{success} || $range_resp->{status} == 206) {
        $raw = $range_resp->{content};
        printf "Downloaded %d bytes (status %s)\n", length($raw), $range_resp->{status};
    } else {
        # Range not supported — try full download with a timeout trick
        print "Range not supported ($range_resp->{status}), fetching full URL (first $FETCH_BYTES bytes only)...\n";
        $range_resp = $http->get($url);
        $raw = substr($range_resp->{content} // '', 0, $FETCH_BYTES);
        printf "Got %d bytes\n", length($raw);
    }

    unless (length($raw) >= 16) {
        print "Not enough data\n"; next;
    }

    # --- 3. Decrypt AES-128-CTR ---
    my $key_bytes = pack('H*', $key_hex);
    my $cipher    = Plugins::yandex::AES128->new($key_bytes);
    my $decrypted = _aes_ctr_decrypt($cipher, $raw);

    # --- 4. Scan top-level boxes ---
    print "Box scan (top-level):\n";
    my $found_moov = -1;
    my $found_mdat = -1;
    my $pos        = 0;
    my $total      = length($decrypted);
    my @box_order;

    while ($pos + 8 <= $total) {
        my ($size, $type) = unpack('Na4', substr($decrypted, $pos, 8));
        my $hdr = 8;

        if ($size == 1) {
            last if $pos + 16 > $total;
            my ($hi, $lo) = unpack('NN', substr($decrypted, $pos + 8, 8));
            $size = $hi * 4294967296 + $lo;
            $hdr = 16;
        } elsif ($size == 0) {
            $size = $total - $pos;
        }

        last if $size < $hdr;

        # Clean up type for display (may contain non-printable bytes if not yet visible)
        my $type_display = $type;
        $type_display =~ s/[^\x20-\x7e]/./g;

        my $fits = ($pos + $size <= $total) ? 'complete' : 'truncated(partial in window)';
        printf "  offset=%-8d  size=%-10d  type='%s'  [%s]\n",
            $pos, $size, $type_display, $fits;

        push @box_order, $type;
        $found_moov = scalar(@box_order) - 1 if $type eq 'moov';
        $found_mdat = scalar(@box_order) - 1 if $type eq 'mdat';

        # Don't advance into truncated box — stop scan
        last if $pos + $size > $total;
        $pos += $size;
    }

    print "\nBox order: " . join(' → ', @box_order) . "\n";
    if ($found_moov >= 0 && $found_mdat >= 0) {
        if ($found_moov < $found_mdat) {
            print "RESULT: moov BEFORE mdat ✓\n";
        } else {
            print "RESULT: mdat BEFORE moov ✗  (streaming demux needs buffering!)\n";
        }
    } elsif ($found_moov < 0) {
        print "RESULT: moov NOT found in first $FETCH_BYTES bytes — either very large or format issue\n";
    } elsif ($found_mdat < 0) {
        print "RESULT: mdat not yet reached in first $FETCH_BYTES bytes (moov larger than window?)\n";
    }
}

print "\nDone.\n";

# --- AES-128-CTR decryption (identical to ProtocolHandler._aes_ctr_xor) ---
sub _aes_ctr_decrypt {
    use bytes;
    my ($cipher, $data) = @_;
    my $len = length($data);
    my $out = '';
    my $i   = 0;
    while ($i < $len) {
        my $blk_num  = int($i / 16);
        my $blk_off  = $i % 16;
        my $counter  = "\x00" x 12 . pack('N', $blk_num);
        my $keystream = $cipher->encrypt($counter);
        my $take = 16 - $blk_off;
        $take = $len - $i if $len - $i < $take;
        $out .= substr($data, $i, $take) ^ substr($keystream, $blk_off, $take);
        $i += $take;
    }
    return $out;
}
