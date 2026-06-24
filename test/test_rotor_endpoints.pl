#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Data::Dumper;
use JSON::PP;
use LWP::UserAgent;

my $token_file = 'test/token.txt';
my $token;
if (-f $token_file) {
    open my $fh, '<', $token_file or die "Cannot open $token_file: $!";
    $token = <$fh>;
    chomp $token;
    close $fh;
} else {
    die "Token file not found\n";
}

my $ua = LWP::UserAgent->new(timeout => 10);
my $base_url = 'https://api.music.yandex.net';

# Test 1: rotor/stations/list - to check if stations include waves
print "=" x 80 . "\n";
print "TEST 1: /rotor/stations/list\n";
print "=" x 80 . "\n";

my $url = "$base_url/rotor/stations/list";
my $req = HTTP::Request->new(GET => $url);
$req->header('Authorization' => "OAuth $token");

my $res = $ua->request($req);
if ($res->is_success) {
    my $data = decode_json($res->content);
    print "Response keys: " . join(', ', keys %$data) . "\n";

    if (exists $data->{stations}) {
        print "Number of stations: " . scalar(@{$data->{stations}}) . "\n\n";

        # Check station types
        my %types;
        foreach my $station (@{$data->{stations}}) {
            my $type = $station->{type} || 'unknown';
            $types{$type}++;

            # Show first few of each type
            if ($types{$type} <= 2) {
                printf "Station type=%s, id=%s, title=%s\n",
                    $type,
                    $station->{id} || 'N/A',
                    $station->{title} || 'N/A';
            }
        }
        print "\nStation types found: " . join(', ', sort keys %types) . "\n";
        foreach my $type (sort keys %types) {
            print "  $type: $types{$type}\n";
        }
    }
} else {
    print "ERROR: " . $res->status_line . "\n";
}

# Test 2: Search in a specific station (test if we can search within rotor)
print "\n" . "=" x 80 . "\n";
print "TEST 2: /search with different type parameters\n";
print "=" x 80 . "\n";

my @types_to_test = (qw(wave vibe mix video clip));

foreach my $type (@types_to_test) {
    my $search_url = "$base_url/search?text=rock&type=$type&page=0";
    print "\nTesting type=$type... ";

    $req = HTTP::Request->new(GET => $search_url);
    $req->header('Authorization' => "OAuth $token");
    $res = $ua->request($req);

    if ($res->is_success) {
        my $data = decode_json($res->content);
        my @keys = keys %{$data->{result} || {}};
        print "✓ Success. Result keys: " . join(', ', @keys) . "\n";
    } elsif ($res->code == 500) {
        print "✗ 500 error (type not supported)\n";
    } elsif ($res->code == 400) {
        print "✗ 400 error (bad request)\n";
    } else {
        print "✗ " . $res->status_line . "\n";
    }
}

print "\n" . "=" x 80 . "\n";
print "CONCLUSION\n";
print "=" x 80 . "\n";
print "Check results to find the correct way to search for waves/vibes\n";
