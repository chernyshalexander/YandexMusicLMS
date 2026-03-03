use strict;
use warnings;
use LWP::UserAgent;
use Data::Dumper;

my $ua = LWP::UserAgent->new;

# Test rotor_session_new (POST) without language
my $res1 = $ua->post('https://api.music.yandex.net/rotor/session/new', { station => 'user:onyourwave' });
print "Session new (no lang): " . $res1->code . " " . $res1->status_line . "\n";
print $res1->decoded_content . "\n";

