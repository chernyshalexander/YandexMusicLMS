#!/usr/bin/perl
# Purpose: Simple test for /non-music/catalogue endpoint without LMS dependencies
# Usage: perl test/test_audiobooks_simple.pl

use strict;
use warnings;
use File::Basename 'dirname';
use File::Spec;
use JSON::XS;
use LWP::UserAgent;
use HTTP::Request;

# Read token from test/token.txt
my $script_dir = dirname(__FILE__);
my $token_file = File::Spec->catfile($script_dir, 'token.txt');

if (! -e $token_file) {
    die "Token file not found at: $token_file\n";
}

open my $fh, '<', $token_file or die "Cannot read token file: $!\n";
my $token = do { local $/; <$fh> };
close $fh;
chomp($token);

die "Token file is empty\n" if !$token || $token =~ /^\s*$/;

print "Token: " . substr($token, 0, 10) . "...\n\n";

# Make HTTP request
my $ua = LWP::UserAgent->new();
$ua->timeout(10);

my $url = 'https://api.music.yandex.net/non-music/catalogue';
my $req = HTTP::Request->new(GET => $url);
$req->header('Authorization' => "OAuth $token");
$req->header('User-Agent' => 'Yandex-Music-API');
$req->header('Accept-Language' => 'ru');

print "Fetching: $url\n";
print "=" x 80 . "\n";

my $res = $ua->request($req);

if (!$res->is_success) {
    print "ERROR: " . $res->status_line . "\n";
    print $res->content . "\n";
    exit(1);
}

my $data = eval { decode_json($res->content) };
if ($@) {
    print "ERROR parsing JSON: $@\n";
    print "Response: " . $res->content . "\n";
    exit(1);
}

if (!$data->{result}) {
    print "ERROR: No result in response\n";
    print JSON::XS->new->pretty(1)->encode($data);
    exit(1);
}

my $result = $data->{result};

print "Response structure:\n";
print "=" x 80 . "\n";

foreach my $key (sort keys %$result) {
    my $value = $result->{$key};
    my $ref_type = ref($value);
    my $type = $ref_type ? $ref_type : 'scalar';

    if ($ref_type eq 'ARRAY') {
        printf "%-20s (ARRAY)  - %d items\n", $key, scalar(@$value);
        if (@$value && scalar(@$value) > 0) {
            my $first = $value->[0];
            if (ref($first) eq 'HASH') {
                my @keys = sort keys %$first;
                print "  └─ First item keys: " . join(", ", @keys) . "\n";
            } elsif (ref($first)) {
                print "  └─ First item type: " . ref($first) . "\n";
            } else {
                print "  └─ First item: $first\n";
            }
        }
    } elsif ($ref_type eq 'HASH') {
        my @keys = sort keys %$value;
        printf "%-20s (HASH)   - keys: %s\n", $key, join(", ", @keys);
    } else {
        my $val_str = defined $value ? substr($value, 0, 60) : 'undef';
        printf "%-20s (scalar) - %s\n", $key, $val_str;
    }
}

print "\n" . "=" x 80 . "\n";
print "Full JSON response (first 100 lines):\n";
print "=" x 80 . "\n";

my $json = JSON::XS->new->pretty(1)->canonical(1)->encode($data);
my @lines = split /\n/, $json;

foreach my $i (0 .. $#lines) {
    last if $i > 100;
    print $lines[$i] . "\n";
}

if (scalar(@lines) > 100) {
    print "... (" . (scalar(@lines) - 100) . " more lines)\n";
}

print "\n✅ Test complete\n";
