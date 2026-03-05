#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang3.pl

use strict;
use warnings;
use JSON::PP;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };

# Testing rotor dashboard
my $url = "https://api.music.yandex.net/rotor/stations/dashboard";

my $ru_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $ru_json = decode_json($ru_req);
print "RU: " . $ru_json->{result}->{pumpkin}->[0]->{stations}->[0]->{station}->{name} . "\n";

my $en_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url"`;
my $en_json = decode_json($en_req);
print "EN: " . $en_json->{result}->{pumpkin}->[0]->{stations}->[0]->{station}->{name} . "\n";
