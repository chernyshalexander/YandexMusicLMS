use strict;
use warnings;
use lib '/home/chernysh/Projects/yandex';
use lib '/home/chernysh/Projects/yandex/lib';
use Data::Dumper;
my $token = `grep -oP '"token":"\\K[^"]+' /home/chernysh/.squeezebox/prefs/plugin/yandex.prefs 2>/dev/null` || "";
chomp $token;
my $cmd = "curl -s -H 'Authorization: OAuth $token' 'https://api.music.yandex.net/search?text=deep%20purple&type=artist&page=0&page-size=50'";
print `$cmd | cut -c 1-200`;
