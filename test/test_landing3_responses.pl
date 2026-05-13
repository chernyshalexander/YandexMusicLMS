#!/usr/bin/perl
# Purpose: Test all landing3 endpoints to verify response structures
# Usage: perl test/test_landing3_responses.pl

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

my @endpoints = (
    { url => 'https://api.music.yandex.net/landing3', params => 'blocks=mixes', name => 'landing3 (mixes)' },
    { url => 'https://api.music.yandex.net/landing3', params => 'blocks=personal-playlists', name => 'landing3 (personal-playlists)' },
    { url => 'https://api.music.yandex.net/landing3/chart', params => '', name => 'landing3/chart' },
    { url => 'https://api.music.yandex.net/landing3/new-releases', params => '', name => 'landing3/new-releases' },
    { url => 'https://api.music.yandex.net/landing3/new-playlists', params => '', name => 'landing3/new-playlists' },
);

print "=== Testing API response structures ===\n\n";

foreach my $ep (@endpoints) {
    my $full_url = $ep->{url};
    $full_url .= '?' . $ep->{params} if $ep->{params};

    print "Testing: " . $ep->{name} . "\n";
    print "  URL: " . $full_url . "\n";

    my $res = $ua->get($full_url);
    if (!$res->is_success) {
        print "  ✗ HTTP Error: " . $res->status_line . "\n\n";
        next;
    }

    my $data = decode_json($res->decoded_content);

    # Check structure
    print "  Top-level keys: " . join(', ', keys %$data) . "\n";

    if (exists $data->{result}) {
        print "    result exists: yes\n";
        if (ref $data->{result} eq 'HASH') {
            print "    result keys: " . join(', ', keys %{$data->{result}}) . "\n";
        } else {
            print "    result type: " . ref($data->{result}) . "\n";
        }
    }

    # Test parsing based on code expectations
    print "  Code checking logic:\n";

    # Check what the code is actually looking for
    my $code_expectation = '';
    if ($ep->{name} eq 'landing3 (mixes)') {
        $code_expectation = 'landing_mixes: checks $result->{result}->{blocks}';
        print "    $code_expectation\n";
        if (exists $data->{result} && exists $data->{result}->{blocks}) {
            print "    ✓ Path exists\n";
        } else {
            print "    ✗ Path missing!\n";
        }
    } elsif ($ep->{name} eq 'landing3 (personal-playlists)') {
        $code_expectation = 'landing_personal_playlists: checks $result->{blocks}';
        print "    $code_expectation\n";
        if (exists $data->{blocks}) {
            print "    ✓ Path exists (top-level)\n";
        } elsif (exists $data->{result} && exists $data->{result}->{blocks}) {
            print "    ⚠ Path exists but nested in result!\n";
        } else {
            print "    ✗ Path missing!\n";
        }
    } elsif ($ep->{name} eq 'landing3/chart') {
        $code_expectation = 'get_chart: checks $result->{chart}';
        print "    $code_expectation\n";
        if (exists $data->{chart}) {
            print "    ✓ Path exists (top-level)\n";
        } elsif (exists $data->{result} && exists $data->{result}->{chart}) {
            print "    ⚠ Path exists but nested in result!\n";
        } else {
            print "    ✗ Path missing!\n";
        }
    } elsif ($ep->{name} eq 'landing3/new-releases') {
        $code_expectation = 'get_new_releases: checks $result->{newReleases}';
        print "    $code_expectation\n";
        if (exists $data->{newReleases}) {
            print "    ✓ Path exists (top-level)\n";
        } elsif (exists $data->{result} && exists $data->{result}->{newReleases}) {
            print "    ⚠ Path exists but nested in result!\n";
        } else {
            print "    ✗ Path missing!\n";
        }
    } elsif ($ep->{name} eq 'landing3/new-playlists') {
        $code_expectation = 'get_new_playlists: checks $result->{result}->{newPlaylists} (FIXED)';
        print "    $code_expectation\n";
        if (exists $data->{result} && exists $data->{result}->{newPlaylists}) {
            print "    ✓ Path exists (fixed)\n";
        } else {
            print "    ✗ Path missing!\n";
        }
    }

    print "\n";
}

print "=== Summary ===\n";
print "Check which endpoints need fixing based on the results above.\n";
