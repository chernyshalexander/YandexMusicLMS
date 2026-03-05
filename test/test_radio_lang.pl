#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_radio_lang.pl

use strict;
use warnings;
use lib "/home/chernysh/Projects/lib";
use lib "/usr/libexec/logitechmediaserver/CPAN";
unshift @INC, "/home/chernysh/Projects";
require Plugins::yandex::ClientAsync;
use Data::Dumper;

my $token = do {
    open my $fh, "<", "/var/lib/squeezeboxserver/prefs/plugin/yandex.prefs" or die "cant open prefs: $!";
    my $content = do { local $/; <$fh> };
    my ($t) = $content =~ /token: (.*?)$/m;
    $t;
};

my $client = Plugins::yandex::ClientAsync->new($token);
$client->init(sub {
    print "Fetching tracks for genre:pop with language=not-russian...\n";
    $client->{request}->get("https://api.music.yandex.net/rotor/station/genre:pop/tracks", { language => 'not-russian' }, sub {
        my $res = shift;
        foreach my $item (@{$res->{result}->{sequence}}) {
            my $track = $item->{track};
            my $artists = join(", ", map { $_->{name} } @{$track->{artists}});
            print " - $artists - $track->{title}\n";
        }
    }, sub { 
        my $err = shift;
        print "ERROR: $err\n"; 
    });
}, sub { 
    my $err = shift;
    print "init err: $err\n"; 
});

use Slim::Networking::Async;
Slim::Networking::Async::spin_loop();
