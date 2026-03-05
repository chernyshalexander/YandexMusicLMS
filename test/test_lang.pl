#!/usr/bin/perl
# Purpose: Testing language/localization settings in API requests
# Usage: perl test/test_lang.pl

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;

my $token = `jq -r '.["plugin.yandex"].token' /home/chernysh/.lms/prefs/plugin/yandex.prefs 2>/dev/null || cat /home/chernysh/.lms/prefs/plugin/yandex.prefs | grep token | cut -d"'" -f2`;
chomp $token;

# If token is still empty, let's just make a script that loads the prefs using Slim::Utils::Prefs
