#!/usr/bin/perl
# Purpose: Test /landing3/new-playlists API endpoint
# Usage: perl test/test_new_playlists.pl

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

print "Testing /landing3/new-playlists endpoint...\n\n";

my $url = 'https://api.music.yandex.net/landing3/new-playlists';
my $res = $ua->get($url);

if (!$res->is_success) {
    print "HTTP Error: " . $res->status_line . "\n";
    print "Response: " . $res->decoded_content . "\n";
    exit 1;
}

my $data = decode_json($res->decoded_content);

print "=== Response Structure ===\n";
print "Top-level keys: " . join(', ', keys %$data) . "\n\n";

print "=== Checking for newPlaylists field ===\n";
if (exists $data->{newPlaylists}) {
    print "✓ newPlaylists field exists\n";
    my $playlists = $data->{newPlaylists};
    printf "  Count: %d\n\n", scalar(@$playlists);

    if (scalar(@$playlists) > 0) {
        print "First 3 playlists:\n";
        for my $i (0..2) {
            last unless $playlists->[$i];
            my $p = $playlists->[$i];
            printf "  [%d] uid=%s, kind=%s, title=%s\n",
                $i + 1,
                $p->{uid} // 'N/A',
                $p->{kind} // 'N/A',
                $p->{title} // 'N/A';
        }
    } else {
        print "  ✗ Array is empty!\n";
    }
} else {
    print "✗ newPlaylists field NOT found\n";
    print "  Available fields in response: " . join(', ', keys %$data) . "\n";
}

print "\n=== Full Response (first 2000 chars) ===\n";
my $json = JSON::PP->new->pretty(1);
my $pretty = $json->encode($data);
print substr($pretty, 0, 2000) . (length($pretty) > 2000 ? "..." : "") . "\n";
