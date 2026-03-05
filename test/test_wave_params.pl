#!/usr/bin/perl
# Purpose: Testing Wave (Radio) parameters and playback flow
# Usage: perl test/test_wave_params.pl

use strict;
use warnings;
use LWP::UserAgent;
use Data::Dumper;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };
my $ua = LWP::UserAgent->new;
$ua->default_header("Authorization" => "OAuth $token");

# Test My Wave with Calm mode
print "Testing My Wave (Calm mode)...\n";
# Try different ways to pass settings: query params, POST body, etc.
# Based on some research, settings2 params are diversity, energy, mood, language.
# Or in settings2 format: moodEnergy, diversity, language.

my $res = $ua->get('https://api.music.yandex.net/rotor/station/user:onyourwave/tracks?settings2=true&moodEnergy=calm');
print "Response Code: " . $res->code . "\n";
# print "Tracks titles: " . join(", ", map { $_->{track}->{title} } @{$result->{sequence}} ) . "\n";

if ($res->is_success) {
    my $data = eval { require JSON; JSON::decode_json($res->decoded_content) };
    if ($data && $data->{result} && $data->{result}->{sequence}) {
        print "First 3 tracks:\n";
        for my $i (0..2) {
            my $item = $data->{result}->{sequence}->[$i];
            last unless $item;
            printf "  - %s by %s\n", $item->{track}->{title}, $item->{track}->{artists}->[0]->{name};
        }
    }
} else {
    print "Error: " . $res->status_line . "\n";
}
