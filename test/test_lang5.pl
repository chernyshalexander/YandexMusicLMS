#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang5.pl

use strict;
use warnings;
use JSON::PP;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };

my $url_landing = "https://api.music.yandex.net/landing3?blocks=main";
my $ru_req2 = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url_landing"`;
my $ru_json2 = decode_json($ru_req2);

print "RU Landing block titles:\n";
foreach my $block (@{$ru_json2->{result}->{blocks}}) {
    print "- " . $block->{title} . "\n" if $block->{title};
}

my $en_req2 = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url_landing"`;
my $en_json2 = decode_json($en_req2);
print "\nEN Landing block titles:\n";
foreach my $block (@{$en_json2->{result}->{blocks}}) {
    print "- " . $block->{title} . "\n" if $block->{title};
}

# test dashboard rotor
my $url = "https://api.music.yandex.net/rotor/stations/dashboard";
my $ru_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $ru_json = decode_json($ru_req);
print "\nRU Rotor stations:\n";
if ($ru_json->{result} && $ru_json->{result}->{dashboard} && $ru_json->{result}->{dashboard}->{stations}) {
    foreach my $st (@{$ru_json->{result}->{dashboard}->{stations}}) {
        print "- " . $st->{station}->{name} . "\n" if $st->{station} && $st->{station}->{name};
    }
}

my $en_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url"`;
my $en_json = decode_json($en_req);
print "\nEN Rotor stations:\n";
if ($en_json->{result} && $en_json->{result}->{dashboard} && $en_json->{result}->{dashboard}->{stations}) {
    foreach my $st (@{$en_json->{result}->{dashboard}->{stations}}) {
        print "- " . $st->{station}->{name} . "\n" if $st->{station} && $st->{station}->{name};
    }
}

