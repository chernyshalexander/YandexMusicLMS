#!/usr/bin/perl
# Purpose: Testing Yandex Rotor (Radio) API endpoints
# Usage: perl test/test_rotor.pl

use strict;
use warnings;
use JSON::PP;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };
my $url = "https://api.music.yandex.net/rotor/stations/dashboard";

my $req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $json = decode_json($req);

if ($json->{result} && $json->{result}->{dashboard} && $json->{result}->{dashboard}->{stations}) {
    print "Dashboard stations available:\n";
    foreach my $st (@{$json->{result}->{dashboard}->{stations}}) {
        print "Type/ID: " . ($st->{station}->{id} // "N/A") . " - Name: " . ($st->{station}->{name} // "N/A") . "\n";
    }
}

print "\nFull structure pumpkin tags:\n";
if ($json->{result} && $json->{result}->{pumpkin}) {
    foreach my $p (@{$json->{result}->{pumpkin}}) {
        print "- Pumpkin Category: " . ($p->{group} // "N/A") . "\n";
        foreach my $s (@{$p->{stations}}) {
            print "  -> Station ID: " . ($s->{station}->{id}->{type} // "N/A") . ":" . ($s->{station}->{id}->{tag} // "N/A") . " | Name: " . ($s->{station}->{name} // "N/A") . "\n" if $s->{station};
        }
    }
}
