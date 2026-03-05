#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_lang_slim.pl

use strict;
use warnings;
use JSON::PP;
use Data::Dumper;

my $prefs_file = '/var/lib/squeezeboxserver/prefs/plugin/yandex.prefs';
$prefs_file = '/home/chernysh/.lms/prefs/plugin/yandex.prefs' unless -e $prefs_file;
$prefs_file = '/home/chernysh/snap/lms/common/prefs/plugin/yandex.prefs' unless -e $prefs_file;

# fallback to reading it directly
my $token;
if (open my $fh, '<', $prefs_file) {
    while (<$fh>) {
        if (/token\s*:\s*'?([^'\s]+)'?/) {
            $token = $1;
            last;
        }
    }
    close $fh;
}

if (!$token) {
    print "Error finding token in $prefs_file\n";
    exit(1);
}

my $url = "https://api.music.yandex.net/landing3?blocks=main";
print "Testing RU...\n";
my $res_ru = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: ru" "$url"`;
my $json_ru = decode_json($res_ru);
if ($json_ru->{result} && $json_ru->{result}->{blocks}) {
    print "First block RU: " . $json_ru->{result}->{blocks}->[0]->{title} . "\n";
}

print "Testing EN...\n";
my $res_en = `curl -s -H "Authorization: OAuth $token" -H "Accept-Language: en" "$url"`;
my $json_en = decode_json($res_en);
if ($json_en->{result} && $json_en->{result}->{blocks}) {
    print "First block EN: " . $json_en->{result}->{blocks}->[0]->{title} . "\n";
}
