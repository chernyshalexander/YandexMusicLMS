#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang_yandex.pl

use strict;
use warnings;
use JSON::XS;
use Data::Dumper;
use lib '/home/chernysh/Projects/yandex';
use Settings;

# A very simple script using curl to test the API with different Accept-Language headers
my $token = Plugins::yandex::Settings->get('token');
unless ($token) {
    die "No token in settings. Please configure token in Settings.pm or run with a valid token.";
}

my $url = "https://api.music.yandex.net/landing3?blocks=main";
my $cmd_ru = "curl -s -H 'Authorization: OAuth $token' -H 'Accept-Language: ru' '$url'";
my $cmd_en = "curl -s -H 'Authorization: OAuth $token' -H 'Accept-Language: en' '$url'";

print "Testing with RU...\n";
my $res_ru = `$cmd_ru`;
my $json_ru = decode_json($res_ru);
my $blocks_ru = $json_ru->{result}->{blocks};
if ($blocks_ru && @$blocks_ru > 0) {
    print "First block RU title: " . ($blocks_ru->[0]->{title} // 'N/A') . "\n";
}

print "Testing with EN...\n";
my $res_en = `$cmd_en`;
my $json_en = decode_json($res_en);
my $blocks_en = $json_en->{result}->{blocks};
if ($blocks_en && @$blocks_en > 0) {
    print "First block EN title: " . ($blocks_en->[0]->{title} // 'N/A') . "\n";
}
