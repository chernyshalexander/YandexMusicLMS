#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang4.pl

use strict;
use warnings;
use JSON::PP;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };
my $url = "https://api.music.yandex.net/rotor/stations/dashboard";

my $ru_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $ru_json = decode_json($ru_req);
# Dashboard structure: result -> dashboard -> stations -> [0] -> station -> name
print "RU: " . $ru_json->{result}->{dashboard}->{stations}->[0]->{station}->{name} . "\n";

my $en_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url"`;
my $en_json = decode_json($en_req);
print "EN: " . $en_json->{result}->{dashboard}->{stations}->[0]->{station}->{name} . "\n";

my $url2 = "https://api.music.yandex.net/landing3?blocks=main";
my $ru_req2 = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url2"`;
my $ru_json2 = decode_json($ru_req2);
print "RU Landing: " . $ru_json2->{result}->{blocks}->[0]->{entities}->[0]->{data}->{title} . "\n" if $ru_json2->{result}->{blocks}->[0]->{entities}->[0]->{data}->{title};

my $en_req2 = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url2"`;
my $en_json2 = decode_json($en_req2);
print "EN Landing: " . $en_json2->{result}->{blocks}->[0]->{entities}->[0]->{data}->{title} . "\n" if $en_json2->{result}->{blocks}->[0]->{entities}->[0]->{data}->{title};

