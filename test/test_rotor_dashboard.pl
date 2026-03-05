#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_rotor_dashboard.pl

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
    print "Fetching dashboard...\n";
    $client->{request}->get("https://api.music.yandex.net/rotor/stations/dashboard", undef, sub {
        my $res = shift;
        print "DASHBOARD RESPONSE:\n";
        print Dumper($res);
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
