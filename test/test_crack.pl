#!/usr/bin/perl
# Purpose: Testing AES decryption logic for Yandex Music (FLAC integration)
# Usage: perl test/test_crack.pl


use strict;
use warnings;
use lib '/usr/share/perl5';
use Slim::Utils::Misc;

my $url = 'https://strm-spbmiran-37.strm.yandex.net/music-v2/crypt/ysign1=4b787c495712369fecfe796cfe2bbe1d47333c4d47586b47388defdd30606f0b,kts=69b5a487,lid=166,pfx,secret_version=ver-1,sfx,source=mds,ts=69b5a487/0/371253/8b240de8.101948813.5.16580934/flac-mp4';

my ($server, $port, $path) = Slim::Utils::Misc::crackURL($url);

print "Server: " . ($server || 'undef') . "\n";
print "Port: " . ($port || 'undef') . "\n";
print "Path: " . ($path || 'undef') . "\n";
