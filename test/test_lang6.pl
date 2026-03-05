#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang6.pl

use strict;
use warnings;
use JSON::PP;
use Data::Dumper;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };

# Test a simple endpoint that should always return data
my $url = "https://api.music.yandex.net/account/status";

my $ru_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $ru_json = decode_json($ru_req);
print "Account status (RU):\n";
print Dumper($ru_json->{result}->{account});

my $url2 = "https://api.music.yandex.net/landing3?blocks=main";
my $en_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url2"`;
my $en_json = decode_json($en_req);
print "\nLanding blocks (EN) keys:\n";
if ($en_json->{result} && $en_json->{result}->{blocks}) {
    foreach my $b (@{$en_json->{result}->{blocks}}) {
        print "Block ID/type: " . ($b->{id} // 'undef') . " / " . ($b->{type} // 'undef') . " - Title: " . ($b->{title} // 'undef') . "\n";
    }
} else {
    print "No blocks found. Raw result: " . substr($en_req, 0, 200) . "\n";
}

