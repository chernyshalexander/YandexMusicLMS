#!/usr/bin/perl
# test_flac_header.pl — Download encrypted flac-mp4, decrypt, demux via ffmpeg,
# parse FLAC STREAMINFO to get samplerate/bps/channels/duration/bitrate.
#
# Usage: perl test_flac_header.pl [track_id]
# Requires: Crypt::Rijndael (via LMS perl), curl, ffmpeg

use strict;
use warnings;
use File::Spec;
use File::Basename 'dirname';
use lib dirname(__FILE__);
use TokenHelper;
use JSON::PP;
use Digest::SHA qw(hmac_sha256);
use MIME::Base64;
use Time::HiRes qw(time);

eval { require Crypt::Rijndael };
die "Crypt::Rijndael not available\n" if $@;

my $TRACK_ID = $ARGV[0] // '16580934';
my $TOKEN    = TokenHelper::get_token() or die "No token in test/token.txt\n";
my $CURL     = _find_bin('curl') or die "curl not found\n";
my $FFMPEG   = _find_bin('ffmpeg') or die "ffmpeg not found\n";
print "curl:   $CURL\n";
print "ffmpeg: $FFMPEG\n\n";

# -----------------------------------------------------------------------
# Step 1: get-file-info
# -----------------------------------------------------------------------
print "==> Step 1: get-file-info for track $TRACK_ID\n";

my $sign_key    = 'p93jhgh689SBReK6ghtw62';
my $codecs      = 'flac,flac-mp4,aac-mp4,aac,he-aac,mp3,he-aac-mp4';
my $transport   = 'encraw';
my $ts          = int(time());
(my $codecs_sign = $codecs) =~ s/,//g;
my $param_string = "${ts}${TRACK_ID}lossless${codecs_sign}${transport}";
my $sign         = substr(encode_base64(hmac_sha256($param_string, $sign_key), ''), 0, 43);

sub uri_escape { my $s = shift; $s =~ s/([^a-zA-Z0-9_.\-~])/sprintf('%%%02X',ord($1))/eg; $s }

my $info_url = 'https://api.music.yandex.net/get-file-info'
    . "?ts=$ts&trackId=$TRACK_ID&quality=lossless"
    . '&codecs=' . uri_escape($codecs)
    . "&transports=$transport"
    . '&sign=' . uri_escape($sign);

my $json_text = curl_get($info_url, {
    'Authorization'         => "OAuth $TOKEN",
    'X-Yandex-Music-Client' => 'YandexMusicAndroid/24023621',
});
die "get-file-info request failed\n" unless defined $json_text;

my $di = decode_json($json_text)->{result}{downloadInfo};
printf "  codec=%-10s  bitrate=%s kbps  has_key=%s\n",
    $di->{codec} // '?',
    $di->{bitrate} || '0 (absent)',
    ($di->{key} ? "YES ($di->{key})" : 'NO');

die "No AES key in response\n"           unless $di->{key};
die "Codec '$di->{codec}' is not FLAC\n" unless ($di->{codec} // '') =~ /flac/i;

my $stream_url  = $di->{url};
my $hex_key     = $di->{key};
my $api_bitrate = $di->{bitrate} || 0;

# -----------------------------------------------------------------------
# Step 2: Download first 5 MB of encrypted stream
# -----------------------------------------------------------------------
print "\n==> Step 2: Downloading first 5 MB (Range: bytes=0-5242879)\n";

my $tmpdir   = File::Spec->tmpdir();
my $tmp_mp4  = File::Spec->catfile($tmpdir, "yandex_test_$$.mp4");
my $tmp_flac = File::Spec->catfile($tmpdir, "yandex_test_$$.flac");

my $dl_cmd = "\"$CURL\" -s -k --range 0-5242879 -o \"$tmp_mp4\" \"$stream_url\"";
system($dl_cmd) == 0 or die "curl download failed\n";
printf "  Downloaded %d bytes -> %s\n", -s $tmp_mp4, $tmp_mp4;

# -----------------------------------------------------------------------
# Step 3: AES-128-CTR decrypt in-place
# -----------------------------------------------------------------------
print "\n==> Step 3: AES-128-CTR decryption\n";

open my $fh_in, '<', $tmp_mp4 or die "Cannot read $tmp_mp4: $!\n";
binmode $fh_in;
my $encrypted = do { local $/; <$fh_in> };
close $fh_in;

my $key_bytes = pack('H*', $hex_key);
my $cipher    = Crypt::Rijndael->new($key_bytes, Crypt::Rijndael::MODE_ECB());
my $decrypted = aes_ctr_xor($cipher, $encrypted, 0);

# Verify MP4 signature (box size + 'ftyp')
my $box_type = substr($decrypted, 4, 4);
printf "  Box type at offset 4: '%s'  (expect 'ftyp' for valid MP4)\n", $box_type;

open my $fh_out, '>', $tmp_mp4 or die "Cannot write $tmp_mp4: $!\n";
binmode $fh_out;
print $fh_out $decrypted;
close $fh_out;
printf "  Decrypted MP4 written: %d bytes\n", length($decrypted);

# -----------------------------------------------------------------------
# Step 4: ffmpeg demux: decrypted MP4 -> FLAC
# -----------------------------------------------------------------------
print "\n==> Step 4: ffmpeg demux (MP4 -> FLAC)\n";

my $ff_cmd = "\"$FFMPEG\" -y -loglevel error -i \"$tmp_mp4\" -vn -c:a copy -f flac \"$tmp_flac\"";
print "  cmd: $ff_cmd\n";
my $ret = system($ff_cmd);

unless ($ret == 0 && -e $tmp_flac && -s $tmp_flac) {
    unlink $tmp_mp4, $tmp_flac;
    die "ffmpeg failed (exit " . ($ret >> 8) . ")\n";
}
printf "  FLAC output: %d bytes\n", -s $tmp_flac;

# -----------------------------------------------------------------------
# Step 5: Parse FLAC STREAMINFO
# -----------------------------------------------------------------------
print "\n==> Step 5: Parsing FLAC STREAMINFO\n";

open my $fh_flac, '<', $tmp_flac or die "Cannot open $tmp_flac: $!\n";
binmode $fh_flac;
my $header = '';
read($fh_flac, $header, 64);
close $fh_flac;

unlink $tmp_mp4, $tmp_flac;

die "Too few bytes from ffmpeg output\n" unless length($header) >= 26;

my $magic = substr($header, 0, 4);
printf "  Magic: '%s' (hex %s)\n", $magic, unpack('H8', $magic);
die "Not a FLAC stream! Got: " . unpack('H8', substr($header, 0, 4)) . "\n"
    unless $magic eq 'fLaC';

my $block_type = unpack('C', substr($header, 4, 1)) & 0x7F;
printf "  First metadata block type: %d (0 = STREAMINFO)\n", $block_type;
die "First block is not STREAMINFO (got $block_type)\n" unless $block_type == 0;

# Packed 64 bits at stream bytes 18-25:
#   bits 63-44 (20 bits): sample_rate
#   bits 43-41  (3 bits): channels - 1
#   bits 40-36  (5 bits): bits_per_sample - 1
#   bits 35-0  (36 bits): total_samples
my ($hi, $lo) = unpack('NN', substr($header, 18, 8));

my $sample_rate     = ($hi >> 12) & 0xFFFFF;
my $channels        = (($hi >>  9) & 0x7) + 1;
my $bits_per_sample = (($hi >>  4) & 0x1F) + 1;
my $total_samples   = ($hi & 0xF) * 4_294_967_296 + $lo;

die "Invalid sample_rate=0 in STREAMINFO\n" unless $sample_rate > 0;

my $duration    = $total_samples / $sample_rate;
my $avg_bitrate = int($sample_rate * $bits_per_sample * $channels * 0.6);

my $sep = '=' x 50;
print "\n$sep\n";
print "FLAC STREAMINFO results:\n";
print "$sep\n";
printf "  Sample rate:     %6d Hz\n",     $sample_rate;
printf "  Bits per sample: %6d bit\n",    $bits_per_sample;
printf "  Channels:        %6d\n",        $channels;
printf "  Total samples:   %6d\n",        $total_samples;
printf "  Duration:        %8.2f sec\n",  $duration;
printf "  Est. bitrate:    %6d kbps  (sr * bps * ch * 0.6)\n", $avg_bitrate / 1000;
printf "  API bitrate:     %6s kbps  (from get-file-info)\n",
    $api_bitrate ? $api_bitrate : '0 (absent)';
print "$sep\n";

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------
sub aes_ctr_xor {
    use bytes;
    my ($cipher, $data, $stream_pos) = @_;
    my $len = length($data);
    my $out = '';
    my $i   = 0;
    while ($i < $len) {
        my $abs       = $stream_pos + $i;
        my $blk_num   = int($abs / 16);
        my $blk_off   = $abs % 16;
        my $counter   = "\x00" x 12 . pack('N', $blk_num);
        my $keystream = $cipher->encrypt($counter);
        my $take      = 16 - $blk_off;
        $take = $len - $i if $len - $i < $take;
        $out .= substr($data, $i, $take) ^ substr($keystream, $blk_off, $take);
        $i   += $take;
    }
    return $out;
}

sub curl_get {
    my ($url, $headers) = @_;
    my $header_args = join(' ', map { "-H \"$_: $headers->{$_}\"" } keys %$headers);
    my $cmd = "\"$CURL\" -s -k $header_args \"$url\"";
    my $out = `$cmd`;
    return $? == 0 ? $out : undef;
}

sub _find_bin {
    my $name = shift;
    my @win_paths = (
        "C:\\ffmpeg\\bin\\$name.exe", "C:\\ffmpeg\\$name.exe",
        "C:\\Program Files\\ffmpeg\\bin\\$name.exe",
    );
    for my $p (@win_paths) { return $p if -e $p }
    for my $dir (split /;|:/, $ENV{PATH} || '') {
        for my $n ("$name.exe", $name) {
            my $p = File::Spec->catfile($dir, $n);
            return $p if -e $p;
        }
    }
    return undef;
}
