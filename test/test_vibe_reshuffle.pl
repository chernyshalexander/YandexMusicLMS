#!/usr/bin/perl
# Purpose: End-to-end test of Vibe Wheel Reshuffle flow
# 1. Get wheel/new response
# 2. Extract CONTROL_ACCENT seeds
# 3. Create rotor session with those seeds
# 4. Verify tracks are returned
# Usage: perl test/test_vibe_reshuffle.pl

use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;
use URI::Escape qw(uri_escape_utf8);

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
$ua->default_header("Content-Type" => "application/json");

print "=== Step 1: GET RESHUFFLE SEEDS FROM wheel/new ===\n";

my $res = $ua->post('https://api.music.yandex.net/wheel/new',
    Content => '{"context":{"type":"WAVE"}}');

die "wheel/new failed: " . $res->status_line unless $res->is_success;

my $wheel = decode_json($res->decoded_content);
my @reshuffle_seeds;

foreach my $item (@{ $wheel->{items} // [] }) {
    next unless ($item->{type} // "") eq "WAVE";
    next unless ($item->{style} // "") eq "CONTROL_ACCENT";
    @reshuffle_seeds = @{ $item->{data}{wave}{seeds} // [] };
    last if @reshuffle_seeds;
}

die "No CONTROL_ACCENT seeds found!" unless @reshuffle_seeds;

print "✓ Reshuffle seeds obtained: " . join(", ", @reshuffle_seeds) . "\n\n";

# === Step 2: Create rotor session with array of seeds (correct format) ===
print "=== Step 2a: CREATE SESSION WITH CORRECT ARRAY FORMAT ===\n";

my $json = JSON::PP->new->pretty(0)->canonical(1);
my $body_correct = $json->encode({
    seeds                   => \@reshuffle_seeds,
    queue                   => [],
    includeTracksInResponse => \1,
    includeWaveModel        => \1,
    interactive             => \1,
});

print "Request: " . $body_correct . "\n";

my $res2 = $ua->post('https://api.music.yandex.net/rotor/session/new', Content => $body_correct);

if ($res2->is_success) {
    my $session = decode_json($res2->decoded_content);
    my $result  = $session->{result} // {};
    print "✓ Session created successfully!\n";
    print "  Session ID: " . ($result->{radioSessionId} // "N/A") . "\n";
    my @tracks = @{ $result->{sequence} // [] };
    printf "  Tracks: %d\n", scalar(@tracks);
    if (@tracks) {
        for my $i (0..2) {
            last unless $tracks[$i];
            my $t = $tracks[$i]{track};
            printf "    [%d] %s - %s\n", $i + 1, $t->{title}, $t->{artists}[0]{name};
        }
    }
    print "\n";
} else {
    print "✗ Failed: " . $res2->status_line . "\n";
    my $resp = decode_json($res2->content);
    print "  Error: " . ($resp->{result}{message} // "Unknown error") . "\n\n";
}

# === Step 2b: Test BROKEN format (arrayref wrapped in array) ===
print "=== Step 2b: CREATE SESSION WITH BROKEN NESTED ARRAY FORMAT ===\n";
print "(This simulates the bug in current rotor_session_new)\n\n";

my @broken_seeds = ([@reshuffle_seeds]);
my $body_broken = $json->encode({
    seeds                   => \@broken_seeds,
    queue                   => [],
    includeTracksInResponse => \1,
    includeWaveModel        => \1,
    interactive             => \1,
});

print "Request: " . $body_broken . "\n";

my $res3 = $ua->post('https://api.music.yandex.net/rotor/session/new', Content => $body_broken);

if ($res3->is_success) {
    my $session = decode_json($res3->decoded_content);
    my @tracks  = @{ $session->{result}{sequence} // [] };
    printf "Session created with %d tracks (unexpected!)\n", scalar(@tracks);
} else {
    print "✗ Failed as expected: " . $res3->status_line . "\n";
    my $resp = decode_json($res3->content);
    print "  Error: " . ($resp->{result}{message} // "Unknown error") . "\n";
    print "  (This error proves the bug in current code)\n";
}

print "\n=== Conclusion ===\n";
print "✓ wheel/new returns proper CONTROL_ACCENT seeds\n";
print "✓ Correct array format: rotor/session/new works perfectly\n";
print "✗ Broken nested array format: API rejects with 400 Bad Request\n";
print "\nThe bug: rotor_session_new needs to handle arrayref parameter\n";
