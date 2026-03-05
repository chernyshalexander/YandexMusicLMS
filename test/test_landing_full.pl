#!/usr/bin/perl
# Purpose: General Yandex Music plugin functional test
# Usage: perl test/test_landing_full.pl

use strict;
use warnings;
use lib "/usr/libexec/logitechmediaserver/CPAN";
use lib "/home/chernysh/Projects/yandex";
unshift @INC, "/home/chernysh/Projects/yandex";
require Plugins::yandex::ClientAsync;
use Data::Dumper;
use JSON;

my $token = do {
    open my $fh, "<", "/var/lib/squeezeboxserver/prefs/plugin/yandex.prefs" or die "cant open prefs: $!";
    my $content = do { local $/; <$fh> };
    my ($t) = $content =~ /token: (.*?)$/m;
    $t;
};

my $client = Plugins::yandex::ClientAsync->new($token);
$client->init(sub {
    print "Fetching landing3 (all blocks)...\n";
    $client->{request}->get("https://api.music.yandex.net/landing3", { blocks => 'mixed-for-you,personal-mixes,recomms,mixes' }, sub {
        my $res = shift;
        print "LANDING3 RESPONSE:\n";
        if ($res->{result} && $res->{result}->{blocks}) {
            foreach my $block (@{$res->{result}->{blocks}}) {
                print "Block: " . ($block->{type} || 'unknown') . " (Title: " . ($block->{title} || 'none') . ")\n";
                if ($block->{entities}) {
                    foreach my $entity (@{$block->{entities}}) {
                        print "  Entity Type: " . $entity->{type} . "\n";
                        if ($entity->{data}) {
                            my $d = $entity->{data};
                            if ($d->{title}) { print "    Title: " . $d->{title} . "\n"; }
                            if ($d->{uid} && $d->{kind}) { print "    Playlist: " . $d->{uid} . ":" . $d->{kind} . "\n"; }
                        }
                    }
                }
            }
        }
    }, sub { 
        print "ERROR LANDING3: $_[0]\n"; 
    });

    $client->{request}->get("https://api.music.yandex.net/rotor/stations/dashboard", undef, sub {
        my $res = shift;
        print "\nROTOR DASHBOARD RESPONSE:\n";
        if ($res->{result} && $res->{result}->{stations}) {
            foreach my $st (@{$res->{result}->{stations}}) {
                my $stat = $st->{station};
                if ($stat) {
                    print "  Station: " . ($stat->{name} || 'none') . " (ID: " . $stat->{id}->{type} . ":" . $stat->{id}->{tag} . ")\n";
                }
            }
        }
    }, sub {
        print "ERROR ROTOR DASHBOARD: $_[0]\n";
    });

}, sub { 
    print "init err: $_[0]\n"; 
});

use Slim::Networking::Async;
Slim::Networking::Async::spin_loop();
