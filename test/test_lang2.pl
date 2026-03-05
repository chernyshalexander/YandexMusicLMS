#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang2.pl

use strict;
use warnings;
use JSON::PP; # Use JSON::PP instead of JSON::XS to avoid missing module errors

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };

my $url_landing = "https://api.music.yandex.net/landing3?blocks=main";
print "--- RU Landing ---\n";
my $ru_landing = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url_landing"`;
my $ru_json = eval { decode_json($ru_landing) };
if ($ru_json && $ru_json->{result} && $ru_json->{result}->{blocks}) {
    print "RU Landing First Title: " . $ru_json->{result}->{blocks}->[0]->{title} . "\n";
} else {
    print "Failed to parse JSON for RU landing. Response start: " . substr($ru_landing, 0, 100) . "\n";
}

print "--- EN Landing ---\n";
my $en_landing = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url_landing"`;
my $en_json = eval { decode_json($en_landing) };
if ($en_json && $en_json->{result} && $en_json->{result}->{blocks}) {
    print "EN Landing First Title: " . $en_json->{result}->{blocks}->[0]->{title} . "\n";
} else {
    print "Failed to parse JSON for EN landing. Response start: " . substr($en_landing, 0, 100) . "\n";
}

my $url_rotor = "https://api.music.yandex.net/rotor/stations/dashboard";
print "--- RU Rotor ---\n";
my $ru_rotor = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url_rotor"`;
my $rur_json = eval { decode_json($ru_rotor) };
if ($rur_json && $rur_json->{result} && $rur_json->{result}->{pumpkin}) {
    print "RU Rotor First Name: " . $rur_json->{result}->{pumpkin}->[0]->{stations}->[0]->{station}->{name} . "\n";
} else {
    print "Failed to parse JSON for RU rotor. Response start: " . substr($ru_rotor, 0, 100) . "\n";
}

print "--- EN Rotor ---\n";
my $en_rotor = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url_rotor"`;
my $enr_json = eval { decode_json($en_rotor) };
if ($enr_json && $enr_json->{result} && $enr_json->{result}->{pumpkin}) {
    print "EN Rotor First Name: " . $enr_json->{result}->{pumpkin}->[0]->{stations}->[0]->{station}->{name} . "\n";
} else {
    print "Failed to parse JSON for EN rotor. Response start: " . substr($en_rotor, 0, 100) . "\n";
}

