#!/usr/bin/perl
# Purpose: Verify the fix for /landing3/new-playlists parsing
# Usage: perl test/test_new_playlists_fixed.pl

use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;

my $token = do {
    open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n";
    local $/;
    my $t = <$fh>;
    $t =~ s/\s+//g;
    $t
};

my $ua = LWP::UserAgent->new;
$ua->default_header("Authorization" => "OAuth $token");
$ua->default_header("X-Yandex-Music-Client" => "YandexMusicAndroid/24.13.1");

print "=== Testing /landing3/new-playlists with FIXED parsing ===\n\n";

my $url = 'https://api.music.yandex.net/landing3/new-playlists';
my $res = $ua->get($url);

die "HTTP Error: " . $res->status_line unless $res->is_success;

my $result = decode_json($res->decoded_content);

print "Testing parsing logic (as in fixed API/Async.pm):\n\n";

# This is the FIXED logic from API/Async.pm
if (exists $result->{result} && exists $result->{result}->{newPlaylists}) {
    print "✓ Successfully extracted newPlaylists from \$result->{result}->{newPlaylists}\n";
    my $playlists = $result->{result}->{newPlaylists};
    my @playlist_data = map { { uid => $_->{uid}, kind => $_->{kind} } } @$playlists;

    printf "✓ Parsed %d playlists\n\n", scalar(@playlist_data);

    print "First 5 playlists:\n";
    for my $i (0..4) {
        last unless $playlist_data[$i];
        printf "  [%d] uid=%s, kind=%s\n",
            $i + 1,
            $playlist_data[$i]->{uid},
            $playlist_data[$i]->{kind};
    }
    print "\n✓ Fix is WORKING correctly!\n";
} else {
    print "✗ Failed to extract newPlaylists\n";
    print "  Available paths:\n";
    print "    - result exists: " . (exists $result->{result} ? "yes" : "no") . "\n";
    if (exists $result->{result}) {
        print "    - result.newPlaylists exists: " . (exists $result->{result}->{newPlaylists} ? "yes" : "no") . "\n";
    }
}
