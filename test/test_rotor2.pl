#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_rotor2.pl

use strict;
use warnings;
use JSON::PP;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };
my $url = "https://api.music.yandex.net/rotor/stations/dashboard";

my $req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $json = decode_json($req);

if ($json->{result}) {
    print "Dashboard top-level keys: " . join(", ", keys %{$json->{result}}) . "\n";
    if ($json->{result}->{dashboard}) {
        print "Dashboard->dashboard keys: " . join(", ", keys %{$json->{result}->{dashboard}}) . "\n";
    }
    
    if ($json->{result}->{pumpkin}) {
        print "Found pumpkin!\n";
    } else {
        print "No pumpkin key.\n";
    }
}
