#!/usr/bin/perl
# Purpose: Test wheel/new API endpoint — verify CONTROL_ACCENT (Reshuffle) item exists
# Usage: perl test/test_wheel_new.pl

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
$ua->default_header("Content-Type" => "application/json");

print "Testing wheel/new endpoint...\n\n";

my $res = $ua->post('https://api.music.yandex.net/wheel/new',
    Content => '{"context":{"type":"WAVE"}}');

die "HTTP error: " . $res->status_line unless $res->is_success;

my $data = decode_json($res->decoded_content);
my $items = $data->{items} // [];

printf "Total items: %d\n\n", scalar(@$items);

my ($reshuffle_found, $reshuffle_seeds);
my $wave_count = 0;

foreach my $item (@$items) {
    next unless ($item->{type} // "") eq "WAVE";
    $wave_count++;

    my $type   = $item->{type}  // "?";
    my $style  = $item->{style} // "-";
    my $id     = $item->{id}    // "?";
    my $name   = $item->{data}{wave}{name} // "-";
    my $seeds  = $item->{data}{wave}{seeds} // [];

    if (($style // "") eq "CONTROL_ACCENT") {
        $reshuffle_found = 1;
        $reshuffle_seeds = $seeds;
        print "[✓ RESHUFFLE] ";
    } else {
        print "[WAVE] ";
    }

    printf "style=%-20s  %s\n", $style, $name;
    printf "      seeds: %s\n\n", join(", ", @$seeds);
}

print "=== Summary ===\n";
printf "Waves found: %d\n", $wave_count;
if ($reshuffle_found) {
    print "Reshuffle found: YES ✓\n";
    printf "Reshuffle seeds: %s\n", join(", ", @$reshuffle_seeds) if @$reshuffle_seeds;
    exit 0;
} else {
    print "Reshuffle found: NO ✗\n";
    exit 1;
}
