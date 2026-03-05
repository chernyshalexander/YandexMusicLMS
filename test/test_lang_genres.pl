#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang_genres.pl

use strict;
use warnings;
use JSON::PP;

my $token = do { open my $fh, "<", "test/token.txt" or die "Please create test/token.txt with your Yandex Music token\n"; local $/; my $t = <$fh>; $t =~ s/\s+//g; $t };

my $url = "https://api.music.yandex.net/genres";

my $ru_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $ru_json = decode_json($ru_req);
print "RU First genre: " . $ru_json->{result}->[0]->{title} . "\n";

my $en_req = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url"`;
my $en_json = decode_json($en_req);
print "EN First genre: " . $en_json->{result}->[0]->{title} . "\n";
